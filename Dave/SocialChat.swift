import CryptoKit
import Foundation

/// Chatting with friends right from the phone, also when the PC is off or far away. The phone uses the same friend code
/// and private key as Dave on the PC (handed over once, through the PC link), so friends see one of you. Messages go
/// straight through ntfy.sh, end-to-end encrypted exactly like on the PC (ECDH P-256 + HKDF + AES-GCM). A copy of what you
/// send, sealed with your own key, goes to your own channel, so the PC's chat shows it too (and the other way round).
/// Adding, accepting and removing friends still happens on the PC: it keeps the friends list.
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
    }

    @Published private(set) var code = ""
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var chats: [String: [Line]] = [:]
    private var name = ""
    private var secret = "" // your private key (the raw 32 bytes, base64), the same as the PC's
    private var since = ""  // the last message seen in your channel
    private var seen = Set<String>()
    private var fetching = false

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

    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("social.json")
    }

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

    /// Picks up what came in since last time (messages wait in the channel for up to 12 hours).
    func fetch() async {
        guard ready, !code.isEmpty, !fetching else { return }
        fetching = true
        defer { fetching = false }
        let after = since.isEmpty ? "12h" : since
        guard let url = URL(string: "https://ntfy.sh/\(Self.topic(code))/json?poll=1&since=\(after)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["event"] as? String == "message" else { continue }
            if let message = event["message"] as? String { handle(message) }
            if let id = event["id"] as? String { since = id }
        }
        save()
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
        switch inner["type"] as? String {
        case "msg":
            guard let text = inner["text"] as? String, !text.isEmpty else { return }
            add(from, Line(mine: false, text: String(text.prefix(1000)), at: Self.now()))
            friends[index].unread += 1
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

    // MARK: Sending

    /// Sends [text] to a friend, encrypted; nil when it went, otherwise why not.
    func send(_ text: String, to friendCode: String, settings: Settings) async -> String? {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !text.isEmpty, let me = privateKey else { return settings.say("Connect me to your PC once (⚙) to chat.", "Koppel me één keer aan je pc (⚙) om te chatten.") }
        guard let friend = friends.first(where: { $0.code == friendCode }), friend.status == "friend", let theirs = Self.publicKey(friend.key) else {
            return settings.say("Their Dave needs the latest update first, so your messages can be encrypted.",
                                "Hun Dave heeft eerst de nieuwste update nodig, zodat je berichten versleuteld kunnen worden.")
        }
        guard let sealed = seal(["type": "msg", "text": text], to: friendCode, key: theirs),
              await post(sealed, to: friendCode) else {
            return settings.say("The message didn't go through. Check your internet and try again.", "Het bericht kwam niet aan. Check je internet en probeer het opnieuw.")
        }
        add(friendCode, Line(mine: true, text: text, at: Self.now()))
        save()
        // A copy for your PC (sealed with your own key), so it's in the chat there too
        if let copy = sealWithId(["type": "sent", "to": friendCode, "text": text, "by": "iphone"], to: code, key: me.publicKey) {
            if let id = copy.id { seen.insert(id) }
            _ = await post(copy.message, to: code)
        }
        return nil
    }

    private func post(_ message: [String: Any], to friendCode: String) async -> Bool {
        guard let url = URL(string: "https://ntfy.sh/\(Self.topic(friendCode))"),
              let body = try? JSONSerialization.data(withJSONObject: message) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Encryption (the same as Dave on the PC)

    /// [inner] (with your name, the time and an id added) locked so only [friendCode] can open it; also returns the id.
    private func sealWithId(_ inner: [String: Any], to friendCode: String, key: P256.KeyAgreement.PublicKey) -> (message: [String: Any], id: String?)? {
        var inner = inner
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        inner["name"] = name
        inner["at"] = Int(Date().timeIntervalSince1970)
        inner["id"] = id
        guard let shared = sharedKey(with: key, friend: friendCode), let plain = try? JSONSerialization.data(withJSONObject: inner),
              let box = try? AES.GCM.seal(plain, using: shared, nonce: AES.GCM.Nonce(), authenticating: Self.direction(code, friendCode)) else { return nil }
        let nonce = box.nonce.withUnsafeBytes { Data($0) }
        return (["dave": 2, "from": code, "n": nonce.base64EncodedString(), "c": box.ciphertext.base64EncodedString(), "t": box.tag.base64EncodedString()], id)
    }

    private func seal(_ inner: [String: Any], to friendCode: String, key: P256.KeyAgreement.PublicKey) -> [String: Any]? {
        sealWithId(inner, to: friendCode, key: key)?.message
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
