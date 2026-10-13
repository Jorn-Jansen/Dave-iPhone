import AVFoundation
import CryptoKit
import Foundation

/// Chatting with friends right from the phone, also when the PC is off or far away. The phone uses the same friend code
/// and private key as Dave on the PC (handed over once, through the PC link), so friends see one of you. Messages go
/// straight through ntfy.sh, end-to-end encrypted exactly like on the PC (ECDH P-256 + HKDF + AES-GCM). A copy of what you
/// send, sealed with your own key, goes to your own channel, so the PC's chat shows it too (and the other way round).
/// Voice messages, photos, videos and files are locked with their own key and parked on litterbox.catbox.moe (3 days),
/// like on the PC. Adding, accepting and removing friends still happens on the PC: it keeps the friends list.
@MainActor
final class SocialChat: ObservableObject {
    static let shared = SocialChat()

    struct Friend: Codable, Identifiable {
        var id: String { code }
        let code: String
        var name: String
        var status: String
        var key: String
        var unread = 0
    }

    struct Line: Codable, Identifiable {
        var id = UUID()
        let mine: Bool
        let text: String
        let at: String
        // (optional, so chats saved before these existed still load)
        /// The message's id, for reactions.
        var msgId: String?
        /// nil (text), "voice", "photo", "video" or "file"; its name, and the file kept on the phone (nil while it's coming in).
        var kind: String?
        var name: String?
        var file: String?
        var failed: Bool?
        var myReaction: String?
        var theirReaction: String?
    }

    @Published private(set) var code = ""
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var chats: [String: [Line]] = [:]
    /// When each friend last said they're typing (shown for a few seconds).
    @Published private(set) var typing: [String: Date] = [:]
    private var name = ""
    private var secret = "" // your private key (the raw 32 bytes, base64), the same as the PC's
    private var since = ""  // the last message seen in your channel
    private var seen = Set<String>()
    private var typingSent: [String: Date] = [:]

    var ready: Bool { privateKey != nil }
    var unread: Int { friends.reduce(0) { $0 + $1.unread } }

    private var privateKey: P256.KeyAgreement.PrivateKey? {
        guard let raw = Data(base64Encoded: secret) else { return nil }
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    private struct Saved: Codable {
        var code, name, secret, since: String
        var friends: [Friend]
        var chats: [String: [Line]]
    }

    private static var folder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var file: URL { folder.appendingPathComponent("social.json") }

    /// Where files from and to friends are kept on the phone.
    static var filesFolder: URL {
        let files = folder.appendingPathComponent("social-files")
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        return files
    }

    /// A file in a chat, on the phone (nil while it's still coming in).
    static func url(of line: Line) -> URL? { line.file.map { filesFolder.appendingPathComponent($0) } }

    private init() {
        guard let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        (code, name, secret, since, friends, chats) = (saved.code, saved.name, saved.secret, saved.since, saved.friends, saved.chats)
    }

    private func save() {
        let saved = Saved(code: code, name: name, secret: secret, since: since, friends: friends, chats: chats)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.file, options: [.atomic, .completeFileProtection]) }
    }

    // MARK: From the PC

    /// Your code, key and friends from Dave on the PC (when it can be reached); the chats you had there fill in empty ones here.
    func sync(settings: Settings, pcFriends: [PCData.Friend]) async {
        guard settings.hasPC, let identity = try? await PCLink.socialIdentity(settings: settings) else { return }
        code = identity["code"] as? String ?? code
        name = identity["name"] as? String ?? name
        secret = identity["d"] as? String ?? secret
        let list = (identity["friends"] as? [[String: Any]]) ?? []
        friends = list.map { f in
            let code = f["code"] as? String ?? ""
            return Friend(code: code, name: f["name"] as? String ?? "?", status: f["status"] as? String ?? "", key: f["key"] as? String ?? "",
                          unread: friends.first { $0.code == code }?.unread ?? 0)
        }
        for f in pcFriends where (chats[f.code] ?? []).isEmpty && !f.lines.isEmpty {
            chats[f.code] = f.lines.map { Line(mine: $0.mine, text: $0.text, at: $0.at) }
        }
        save()
    }

    // MARK: Receiving

    /// Listens to your channel while the Social tab is open: first what came in since last time (messages wait for up to
    /// 12 hours), then new ones as they come, also "typing…". Reconnects when the connection drops.
    func listen() async {
        while !Task.isCancelled {
            if ready, !code.isEmpty, let url = URL(string: "https://ntfy.sh/\(Self.topic(code))/json?since=\(since.isEmpty ? "12h" : since)") {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(from: url)
                    for try await line in bytes.lines {
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              event["event"] as? String == "message" else { continue }
                        if let message = event["message"] as? String { handle(message) }
                        if let id = event["id"] as? String { since = id }
                        save()
                    }
                } catch {
                    if Task.isCancelled { return }
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func handle(_ raw: String) {
        guard let m = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], m["c"] != nil,
              let from = m["from"] as? String else { return } // (requests and accepts: the PC takes care of those)
        if from == code {
            // A copy of what you sent from the PC
            guard let me = privateKey, let inner = open(m, from: code, key: me.publicKey), inner["type"] as? String == "sent",
                  inner["by"] as? String != "iphone", let to = inner["to"] as? String, fresh(inner) else { return }
            add(to, Line(mine: true, text: inner["text"] as? String ?? "", at: Self.now()))
            return
        }
        guard let index = friends.firstIndex(where: { $0.code == from && $0.status == "friend" && !$0.key.isEmpty }),
              let theirs = Self.publicKey(friends[index].key), let inner = open(m, from: from, key: theirs), fresh(inner) else { return }
        if let newName = inner["name"] as? String, !newName.isEmpty { friends[index].name = newName }
        let id = inner["id"] as? String
        switch inner["type"] as? String {
        case "msg":
            guard let text = inner["text"] as? String, !text.isEmpty else { return }
            typing[from] = nil
            add(from, Line(mine: false, text: String(text.prefix(1000)), at: Self.now(), msgId: id))
            friends[index].unread += 1
        case "file":
            typing[from] = nil
            let kind = ["voice", "photo", "video"].contains(inner["kind"] as? String ?? "") ? inner["kind"] as! String : "file"
            let fileName = Self.safeName(inner["filename"] as? String ?? "file")
            add(from, Line(mine: false, text: Self.label(kind, fileName), at: Self.now(), msgId: id, kind: kind, name: fileName))
            friends[index].unread += 1
            Task { await download(inner, from: from, id: id ?? UUID().uuidString, name: fileName) }
        case "react":
            guard let target = inner["target"] as? String, var lines = chats[from], let at = lines.lastIndex(where: { $0.msgId == target }) else { return }
            let emoji = String((inner["emoji"] as? String ?? "").prefix(8))
            lines[at].theirReaction = emoji.isEmpty ? nil : emoji
            chats[from] = lines
        case "typing":
            typing[from] = Date()
        case "bye":
            friends.remove(at: index)
        default:
            break
        }
    }

    /// Not too old, and not seen before (so a message sent again isn't shown twice).
    private func fresh(_ inner: [String: Any]) -> Bool {
        let at = (inner["at"] as? NSNumber)?.doubleValue ?? 0
        guard let id = inner["id"] as? String, !id.isEmpty, Date().timeIntervalSince1970 - at < 13 * 3600 else { return false }
        return seen.insert(id).inserted
    }

    private func add(_ friend: String, _ line: Line) {
        guard !line.text.isEmpty else { return }
        var lines = chats[friend] ?? []
        lines.append(line)
        chats[friend] = Array(lines.suffix(300))
    }

    func markRead(_ friend: String) {
        if let index = friends.firstIndex(where: { $0.code == friend }), friends[index].unread > 0 { friends[index].unread = 0; save() }
    }

    /// Whether [friend] is typing right now.
    func isTyping(_ friend: String) -> Bool { typing[friend].map { Date().timeIntervalSince($0) < 10 } ?? false }

    // MARK: Sending

    /// Sends [text] to a friend, encrypted; nil when it went, otherwise why not.
    func send(_ text: String, to friendCode: String, settings: Settings) async -> String? {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !text.isEmpty, let me = privateKey else { return settings.say("Connect me to your PC once (⚙) to chat.", "Koppel me één keer aan je pc (⚙) om te chatten.") }
        guard let theirs = friendKey(friendCode) else { return needsUpdate(settings) }
        guard let sealed = sealWithId(["type": "msg", "text": text], to: friendCode, key: theirs),
              await post(sealed.message, to: friendCode) else { return didntGo(settings) }
        add(friendCode, Line(mine: true, text: text, at: Self.now(), msgId: sealed.id))
        typingSent[friendCode] = nil // the next "typing…" goes right away
        save()
        // A copy for your PC (sealed with your own key), so it's in the chat there too
        if let copy = sealWithId(["type": "sent", "to": friendCode, "text": text, "by": "iphone"], to: code, key: me.publicKey) {
            if let id = copy.id { seen.insert(id) }
            _ = await post(copy.message, to: code)
        }
        return nil
    }

    /// Sends a voice message, photo, video or file: locked with its own key, put on the file host, and the end-to-end
    /// encrypted message says where it is and how to unlock it. Nil when it went, otherwise why not.
    func sendFile(_ data: Data, name: String, kind: String? = nil, to friendCode: String, settings: Settings) async -> String? {
        guard ready else { return settings.say("Connect me to your PC once (⚙) to chat.", "Koppel me één keer aan je pc (⚙) om te chatten.") }
        guard let theirs = friendKey(friendCode) else { return needsUpdate(settings) }
        guard !data.isEmpty, data.count <= 200_000_000 else { return settings.say("That's too big to send (200 MB at most).", "Dat is te groot om te versturen (hooguit 200 MB).") }
        let name = Self.safeName(name)
        let kind = kind ?? Self.kind(of: name)
        let key = SymmetricKey(size: .bits256)
        guard let box = try? AES.GCM.seal(data, using: key),
              let url = await upload(box.ciphertext + box.tag) else {
            return settings.say("The file didn't upload. Check your internet and try again.", "Het bestand kon niet worden geüpload. Check je internet en probeer het opnieuw.")
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let inner: [String: Any] = [
            "type": "file", "kind": kind, "filename": name, "size": data.count, "url": url, "id": id,
            "k": key.withUnsafeBytes { Data($0) }.base64EncodedString(), "fn": box.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
        ]
        guard let sealed = sealWithId(inner, to: friendCode, key: theirs), await post(sealed.message, to: friendCode) else { return didntGo(settings) }
        let kept = id + "." + (name as NSString).pathExtension
        try? data.write(to: Self.filesFolder.appendingPathComponent(kept))
        add(friendCode, Line(mine: true, text: Self.label(kind, name), at: Self.now(), msgId: id, kind: kind, name: name, file: kept))
        save()
        return nil
    }

    /// React to a message with an emoji (the same one again takes it away).
    func react(_ emoji: String, to line: Line, of friendCode: String) async {
        guard let target = line.msgId, var lines = chats[friendCode], let at = lines.firstIndex(where: { $0.id == line.id }),
              let theirs = friendKey(friendCode) else { return }
        let new = lines[at].myReaction == emoji ? "" : emoji
        lines[at].myReaction = new.isEmpty ? nil : new
        chats[friendCode] = lines
        save()
        if let sealed = sealWithId(["type": "react", "target": target, "emoji": new], to: friendCode, key: theirs) { _ = await post(sealed.message, to: friendCode) }
    }

    /// "You're typing": at most every 8 seconds, and not kept on the server.
    func sendTyping(to friendCode: String) async {
        if let last = typingSent[friendCode], Date().timeIntervalSince(last) < 8 { return }
        guard let theirs = friendKey(friendCode), let sealed = sealWithId(["type": "typing"], to: friendCode, key: theirs) else { return }
        typingSent[friendCode] = Date()
        _ = await post(sealed.message, to: friendCode, keep: false)
    }

    private func friendKey(_ friendCode: String) -> P256.KeyAgreement.PublicKey? {
        guard let friend = friends.first(where: { $0.code == friendCode }), friend.status == "friend" else { return nil }
        return Self.publicKey(friend.key)
    }

    private func needsUpdate(_ settings: Settings) -> String {
        settings.say("Their Dave needs the latest update first, so your messages can be encrypted.",
                     "Hun Dave heeft eerst de nieuwste update nodig, zodat je berichten versleuteld kunnen worden.")
    }

    private func didntGo(_ settings: Settings) -> String {
        settings.say("The message didn't go through. Check your internet and try again.", "Het bericht kwam niet aan. Check je internet en probeer het opnieuw.")
    }

    private func post(_ message: [String: Any], to friendCode: String, keep: Bool = true) async -> Bool {
        guard let url = URL(string: "https://ntfy.sh/\(Self.topic(friendCode))"),
              let body = try? JSONSerialization.data(withJSONObject: message) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        if !keep { request.setValue("no", forHTTPHeaderField: "Cache") } // only matters right now
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Files

    /// Puts the locked file on litterbox.catbox.moe for 3 days; returns where it is.
    private func upload(_ locked: Data) async -> String? {
        let boundary = "Dave-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) { body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!) }
        field("reqtype", "fileupload")
        field("time", "72h")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"dave.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(locked)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let url = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), url.hasPrefix("https://") else { return nil }
        return url
    }

    /// Fetches and unlocks a file a friend sent; then it shows in the chat.
    private func download(_ inner: [String: Any], from friendCode: String, id: String, name: String) async {
        var kept: String?
        if let url = inner["url"] as? String, url.hasPrefix("https://litter.catbox.moe/"), let link = URL(string: url),
           let key = Data(base64Encoded: inner["k"] as? String ?? ""), let nonce = Data(base64Encoded: inner["fn"] as? String ?? ""),
           let (locked, _) = try? await URLSession.shared.data(from: link), locked.count > 16,
           let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: locked.prefix(locked.count - 16), tag: locked.suffix(16)),
           let data = try? AES.GCM.open(box, using: SymmetricKey(data: key)) {
            let file = id + "." + (name as NSString).pathExtension
            if (try? data.write(to: Self.filesFolder.appendingPathComponent(file))) != nil { kept = file }
        }
        guard var lines = chats[friendCode], let at = lines.lastIndex(where: { $0.msgId == id }) else { return }
        if let kept { lines[at].file = kept } else { lines[at].failed = true }
        chats[friendCode] = lines
        save()
    }

    static func kind(of name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp": return "photo"
        case "mp4", "mov", "webm", "m4v", "mkv", "avi": return "video"
        default: return "file"
        }
    }

    private static func label(_ kind: String, _ name: String) -> String {
        switch kind {
        case "voice": return "🎤 Voice message"
        case "photo": return "📷 Photo"
        case "video": return "🎬 Video"
        default: return "📎 " + name
        }
    }

    private static func safeName(_ name: String) -> String {
        let clean = (name as NSString).lastPathComponent.filter { !"/\\:*?\"<>|".contains($0) }.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty || clean.count > 120 ? "file" : clean
    }

    // MARK: Encryption (the same as Dave on the PC)

    /// [inner] (with your name, the time and an id added, unless it has one) locked so only [friendCode] can open it; also returns the id.
    private func sealWithId(_ inner: [String: Any], to friendCode: String, key: P256.KeyAgreement.PublicKey) -> (message: [String: Any], id: String?)? {
        var inner = inner
        let id = inner["id"] as? String ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        inner["name"] = name
        inner["at"] = Int(Date().timeIntervalSince1970)
        inner["id"] = id
        guard let shared = sharedKey(with: key, friend: friendCode), let plain = try? JSONSerialization.data(withJSONObject: inner),
              let box = try? AES.GCM.seal(plain, using: shared, nonce: AES.GCM.Nonce(), authenticating: Self.direction(code, friendCode)) else { return nil }
        let nonce = box.nonce.withUnsafeBytes { Data($0) }
        return (["dave": 2, "from": code, "n": nonce.base64EncodedString(), "c": box.ciphertext.base64EncodedString(), "t": box.tag.base64EncodedString()], id)
    }

    private func open(_ m: [String: Any], from friendCode: String, key: P256.KeyAgreement.PublicKey) -> [String: Any]? {
        guard let shared = sharedKey(with: key, friend: friendCode),
              let nonceData = Data(base64Encoded: m["n"] as? String ?? ""), let cipher = Data(base64Encoded: m["c"] as? String ?? ""),
              let tag = Data(base64Encoded: m["t"] as? String ?? ""),
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: cipher, tag: tag),
              let plain = try? AES.GCM.open(box, using: shared, authenticating: Self.direction(friendCode, code)) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    /// The key you and a friend share: ECDH, then SHA-256 of the result (like .NET's DeriveKeyFromHash), then HKDF.
    private func sharedKey(with theirs: P256.KeyAgreement.PublicKey, friend: String) -> SymmetricKey? {
        guard let me = privateKey, let agreed = try? me.sharedSecretFromKeyAgreement(with: theirs) else { return nil }
        let z = agreed.withUnsafeBytes { Data($0) }
        let hashed = Data(SHA256.hash(data: z))
        let codes = code < friend ? code + friend : friend + code
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: hashed), salt: Data("dave-social-v2".utf8),
                                      info: Data(codes.utf8), outputByteCount: 32)
    }

    private static func publicKey(_ base64: String) -> P256.KeyAgreement.PublicKey? {
        guard let der = Data(base64Encoded: base64) else { return nil }
        return try? P256.KeyAgreement.PublicKey(derRepresentation: der)
    }

    private static func direction(_ from: String, _ to: String) -> Data { Data("dave-chat \(from) -> \(to)".utf8) }

    private static func topic(_ code: String) -> String { "dave-chat-" + code.dropFirst(5).replacingOccurrences(of: "-", with: "").lowercased() }

    private static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}
