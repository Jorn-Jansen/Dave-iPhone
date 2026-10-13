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
        /// Your last message they've read, and when ("Seen 21:46").
        var seenId: String?
        var seenAt: String?
    }

    /// A message you scheduled ("send it tomorrow at 8"): sent then, when Dave is open (or the next time he is).
    struct Scheduled: Codable, Identifiable {
        var id = UUID().uuidString
        let code: String
        let text: String
        var reply: String?
        let at: Date
    }

    /// A link's page: title, text and picture.
    struct Preview: Codable {
        let url: String
        var title = ""
        var text = ""
        var image = ""
    }

    struct Line: Codable, Identifiable {
        var id = UUID()
        let mine: Bool
        var text: String
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
        /// The id of the message this one replies to.
        var replyTo: String?
        /// When it was sent (for searching by date).
        var date: Date? = Date()
        var edited: Bool?
        /// What's said in a voice message ("…" while it's being worked out).
        var transcript: String?
        /// A friend's message in your language ("…" while working on it, "=" when it already was).
        var translation: String?
        /// The first link's page (url "-" when there's nothing to show).
        var preview: Preview?
        /// A poll (kind "poll", the question in text): its answers, and which one you and your friend picked (nil = none yet).
        var options: [String]?
        var myVote: Int?
        var theirVote: Int?
    }

    @Published private(set) var code = ""
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var chats: [String: [Line]] = [:]
    /// When each friend last said they're typing (shown for a few seconds).
    @Published private(set) var typing: [String: Date] = [:]
    @Published private(set) var scheduled: [Scheduled] = []
    private var name = ""
    private var secret = "" // your private key (the raw 32 bytes, base64), the same as the PC's
    private var since = ""  // the last message seen in your channel
    private var seen = Set<String>()
    private var typingSent: [String: Date] = [:]
    private var seenSent: [String: String] = [:]

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
        var scheduled: [Scheduled]?
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
        scheduled = saved.scheduled ?? []
    }

    private func save() {
        let saved = Saved(code: code, name: name, secret: secret, since: since, friends: friends, chats: chats, scheduled: scheduled)
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
            let known = friends.first { $0.code == code }
            return Friend(code: code, name: f["name"] as? String ?? "?", status: f["status"] as? String ?? "", key: f["key"] as? String ?? "",
                          unread: known?.unread ?? 0, seenId: known?.seenId, seenAt: known?.seenAt)
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
            // A copy of what you did on the PC: sent, changed or deleted a message
            guard let me = privateKey, let inner = open(m, from: code, key: me.publicKey),
                  inner["by"] as? String != "iphone", let to = inner["to"] as? String, fresh(inner) else { return }
            let target = inner["target"] as? String ?? ""
            switch inner["type"] as? String {
            case "sent":
                let line = Line(mine: true, text: inner["text"] as? String ?? "", at: Self.now(), msgId: inner["msgid"] as? String, replyTo: Self.reply(inner))
                add(to, line)
                if let id = line.msgId { Task { await preview(id, of: to, mine: true) } }
            case "sentfile": // a photo, video, voice message or file you sent from the PC: fetched here too
                guard let id = inner["msgid"] as? String, !id.isEmpty, id.count <= 64 else { return }
                let kind = ["voice", "photo", "video"].contains(inner["kind"] as? String ?? "") ? inner["kind"] as! String : "file"
                let fileName = Self.safeName(inner["filename"] as? String ?? "file")
                add(to, Line(mine: true, text: Self.label(kind, fileName), at: Self.now(), msgId: id, kind: kind, name: fileName, replyTo: Self.reply(inner)))
                Task { await download(inner, from: to, id: id, name: fileName) }
            case "sentpoll": // a poll you sent from the PC
                guard let question = Self.question(inner), let answers = Self.answers(inner) else { return }
                add(to, Line(mine: true, text: question, at: Self.now(), msgId: inner["msgid"] as? String, kind: "poll", replyTo: Self.reply(inner), options: answers))
            case "vote": // what you picked on the PC
                change(to, target, mine: nil) { line in if let choice = Self.choice(inner, line) { line.myVote = choice } }
            case "edit":
                change(to, target, mine: true) { $0.text = String((inner["text"] as? String ?? "").prefix(1000)); $0.edited = true; $0.preview = nil }
                Task { await preview(target, of: to, mine: true) }
            case "unsend":
                remove(to, target, mine: true)
            default:
                break
            }
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
            add(from, Line(mine: false, text: String(text.prefix(1000)), at: Self.now(), msgId: id, replyTo: Self.reply(inner)))
            friends[index].unread += 1
            if let id {
                Task { await preview(id, of: from, mine: false) }
                let settings = Settings.shared
                if settings.translate && settings.translateAutomatically { Task { await translate(id, of: from, settings: settings) } }
            }
        case "file":
            typing[from] = nil
            let kind = ["voice", "photo", "video"].contains(inner["kind"] as? String ?? "") ? inner["kind"] as! String : "file"
            let fileName = Self.safeName(inner["filename"] as? String ?? "file")
            add(from, Line(mine: false, text: Self.label(kind, fileName), at: Self.now(), msgId: id, kind: kind, name: fileName, replyTo: Self.reply(inner)))
            friends[index].unread += 1
            Task { await download(inner, from: from, id: id ?? UUID().uuidString, name: fileName) }
        case "react":
            guard let target = inner["target"] as? String, var lines = chats[from], let at = lines.lastIndex(where: { $0.msgId == target }) else { return }
            let emoji = String((inner["emoji"] as? String ?? "").prefix(8))
            lines[at].theirReaction = emoji.isEmpty ? nil : emoji
            chats[from] = lines
        case "poll": // a question with answers to pick from
            guard let question = Self.question(inner), let answers = Self.answers(inner) else { return }
            typing[from] = nil
            add(from, Line(mine: false, text: question, at: Self.now(), msgId: id, kind: "poll", replyTo: Self.reply(inner), options: answers))
            friends[index].unread += 1
        case "vote": // they picked an answer in a poll (-1: took it back)
            change(from, inner["target"] as? String ?? "", mine: nil) { line in if let choice = Self.choice(inner, line) { line.theirVote = choice } }
        case "edit": // they changed a message they sent
            let target = inner["target"] as? String ?? ""
            change(from, target, mine: false) { $0.text = String((inner["text"] as? String ?? "").prefix(1000)); $0.edited = true; $0.translation = nil; $0.preview = nil }
            Task { await preview(target, of: from, mine: false) }
            let settings = Settings.shared
            if settings.translate && settings.translateAutomatically { Task { await translate(target, of: from, settings: settings) } }
        case "unsend": // they deleted a message they sent
            remove(from, inner["target"] as? String ?? "", mine: false)
        case "seen": // they've read your messages up to this one
            guard Settings.shared.readReceipts, let target = inner["target"] as? String, !target.isEmpty else { return }
            friends[index].seenId = target
            friends[index].seenAt = Self.now()
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
        // and tells them you've seen their messages (unless read receipts are off)
        guard Settings.shared.readReceipts, let last = chats[friend]?.last(where: { !$0.mine && $0.msgId != nil })?.msgId,
              seenSent[friend] != last, let theirs = friendKey(friend) else { return }
        seenSent[friend] = last
        Task { if let sealed = sealWithId(["type": "seen", "target": last], to: friend, key: theirs) { _ = await post(sealed.message, to: friend) } }
    }

    /// Changes the line with message id [id] (yours or theirs) in a chat.
    private func change(_ friend: String, _ id: String, mine: Bool?, _ edit: (inout Line) -> Void) {
        guard !id.isEmpty, var lines = chats[friend], let at = lines.lastIndex(where: { $0.msgId == id && (mine == nil || $0.mine == mine) }) else { return }
        edit(&lines[at])
        chats[friend] = lines
        save()
    }

    private func remove(_ friend: String, _ id: String, mine: Bool) {
        guard !id.isEmpty, var lines = chats[friend], let at = lines.lastIndex(where: { $0.msgId == id && $0.mine == mine }) else { return }
        if let file = Self.url(of: lines[at]) { try? FileManager.default.removeItem(at: file) }
        lines.remove(at: at)
        chats[friend] = lines
        save()
    }

    /// Whether [friend] is typing right now.
    func isTyping(_ friend: String) -> Bool { typing[friend].map { Date().timeIntervalSince($0) < 10 } ?? false }

    // MARK: Sending

    /// Sends [text] to a friend, encrypted; nil when it went, otherwise why not.
    func send(_ text: String, to friendCode: String, reply: String? = nil, settings: Settings) async -> String? {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !text.isEmpty, let me = privateKey else { return settings.say("Connect me to your PC once (⚙) to chat.", "Koppel me één keer aan je pc (⚙) om te chatten.") }
        guard let theirs = friendKey(friendCode) else { return needsUpdate(settings) }
        guard let sealed = sealWithId(["type": "msg", "text": text, "reply": reply ?? ""], to: friendCode, key: theirs),
              await post(sealed.message, to: friendCode) else { return didntGo(settings) }
        add(friendCode, Line(mine: true, text: text, at: Self.now(), msgId: sealed.id, replyTo: reply))
        typingSent[friendCode] = nil // the next "typing…" goes right away
        save()
        if let id = sealed.id { Task { await preview(id, of: friendCode, mine: true) } }
        // A copy for your PC (sealed with your own key), so it's in the chat there too
        if let copy = sealWithId(["type": "sent", "to": friendCode, "text": text, "by": "iphone", "msgid": sealed.id ?? "", "reply": reply ?? ""], to: code, key: me.publicKey) {
            if let id = copy.id { seen.insert(id) }
            _ = await post(copy.message, to: code)
        }
        return nil
    }

    /// Sends a voice message, photo, video or file: locked with its own key, put on the file host, and the end-to-end
    /// encrypted message says where it is and how to unlock it. Nil when it went, otherwise why not.
    func sendFile(_ data: Data, name: String, kind: String? = nil, to friendCode: String, reply: String? = nil, settings: Settings) async -> String? {
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
            "reply": reply ?? "",
        ]
        guard let sealed = sealWithId(inner, to: friendCode, key: theirs), await post(sealed.message, to: friendCode) else { return didntGo(settings) }
        let kept = id + "." + (name as NSString).pathExtension
        try? data.write(to: Self.filesFolder.appendingPathComponent(kept))
        add(friendCode, Line(mine: true, text: Self.label(kind, name), at: Self.now(), msgId: id, kind: kind, name: name, file: kept, replyTo: reply))
        save()
        // A copy for your PC (sealed with your own key): where the file is and how to unlock it, so it's in the chat there too
        var copy = inner
        copy["type"] = "sentfile"
        copy["to"] = friendCode
        copy["by"] = "iphone"
        copy["msgid"] = id
        copy["id"] = nil // (the copy gets its own)
        if let me = privateKey, let sealedCopy = sealWithId(copy, to: code, key: me.publicKey) {
            if let copyId = sealedCopy.id { seen.insert(copyId) }
            _ = await post(sealedCopy.message, to: code)
        }
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

    // MARK: Polls

    private static func question(_ inner: [String: Any]) -> String? {
        let q = (inner["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : String(q.prefix(200))
    }

    /// A poll's answers: 2 to 6 short ones (nil when it isn't a proper poll).
    private static func answers(_ inner: [String: Any]) -> [String]? {
        let list = (inner["options"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { String($0.prefix(80)) }
        return (2...6).contains(list.count) ? list : nil
    }

    /// The answer a vote picked (nil when it's not a valid one; -1 = took the vote back).
    private static func choice(_ inner: [String: Any], _ poll: Line) -> Int?? {
        guard poll.kind == "poll", let choice = (inner["choice"] as? NSNumber)?.intValue, choice >= -1, choice < (poll.options?.count ?? 0) else { return nil }
        return .some(choice < 0 ? nil : choice)
    }

    /// "Ask Alex: Roblox or Minecraft tonight?": a question with 2 to 6 answers. Nil when it went, otherwise why not.
    func sendPoll(_ question: String, options: [String], to friendCode: String, reply: String? = nil, settings: Settings) async -> String? {
        let q = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        var answers: [String] = []
        for o in options.map({ String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }) where !o.isEmpty && !answers.contains(o) && answers.count < 6 { answers.append(o) }
        guard !q.isEmpty, answers.count >= 2 else { return settings.say("A poll needs a question and at least two answers.", "Een poll heeft een vraag en minstens twee antwoorden nodig.") }
        guard let me = privateKey else { return settings.say("Connect me to your PC once (⚙) to chat.", "Koppel me één keer aan je pc (⚙) om te chatten.") }
        guard let theirs = friendKey(friendCode) else { return needsUpdate(settings) }
        guard let sealed = sealWithId(["type": "poll", "text": q, "options": answers, "reply": reply ?? ""], to: friendCode, key: theirs),
              await post(sealed.message, to: friendCode) else { return didntGo(settings) }
        add(friendCode, Line(mine: true, text: q, at: Self.now(), msgId: sealed.id, kind: "poll", replyTo: reply, options: answers))
        save()
        if let copy = sealWithId(["type": "sentpoll", "to": friendCode, "text": q, "options": answers, "by": "iphone", "msgid": sealed.id ?? "", "reply": reply ?? ""], to: code, key: me.publicKey) {
            if let id = copy.id { seen.insert(id) }
            _ = await post(copy.message, to: code)
        }
        return nil
    }

    /// Pick an answer in a poll (the same one again takes your vote back).
    func vote(_ choice: Int, in poll: Line, of friendCode: String) async {
        guard let target = poll.msgId, poll.kind == "poll", choice >= 0, choice < (poll.options?.count ?? 0), let theirs = friendKey(friendCode) else { return }
        let new = poll.myVote == choice ? nil : choice
        change(friendCode, target, mine: poll.mine) { $0.myVote = new }
        if let sealed = sealWithId(["type": "vote", "target": target, "choice": new ?? -1], to: friendCode, key: theirs) { _ = await post(sealed.message, to: friendCode) }
        if let me = privateKey, let copy = sealWithId(["type": "vote", "to": friendCode, "target": target, "choice": new ?? -1, "by": "iphone"], to: code, key: me.publicKey) {
            if let id = copy.id { seen.insert(id) }
            _ = await post(copy.message, to: code)
        }
    }

    // MARK: Edit, delete, schedule

    /// Changes a message you sent, for them too (and on your PC). Nil when it went, otherwise why not.
    func edit(_ line: Line, to newText: String, of friendCode: String, settings: Settings) async -> String? {
        let text = String(newText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard let target = line.msgId, line.mine, line.kind == nil, !text.isEmpty, text != line.text else { return nil }
        guard let me = privateKey, let theirs = friendKey(friendCode) else { return needsUpdate(settings) }
        guard let sealed = sealWithId(["type": "edit", "target": target, "text": text], to: friendCode, key: theirs),
              await post(sealed.message, to: friendCode) else { return didntGo(settings) }
        change(friendCode, target, mine: true) { $0.text = text; $0.edited = true; $0.preview = nil }
        Task { await preview(target, of: friendCode, mine: true) }
        if let copy = sealWithId(["type": "edit", "to": friendCode, "target": target, "text": text, "by": "iphone"], to: code, key: me.publicKey) {
            if let id = copy.id { seen.insert(id) }
            _ = await post(copy.message, to: code)
        }
        return nil
    }

    /// Deletes a message you sent, for them too (and on your PC).
    func unsend(_ line: Line, of friendCode: String, settings: Settings) async -> String? {
        guard let target = line.msgId, line.mine else { return nil }
        guard let me = privateKey, let theirs = friendKey(friendCode) else { return needsUpdate(settings) }
        guard let sealed = sealWithId(["type": "unsend", "target": target], to: friendCode, key: theirs),
              await post(sealed.message, to: friendCode) else { return didntGo(settings) }
        remove(friendCode, target, mine: true)
        if let copy = sealWithId(["type": "unsend", "to": friendCode, "target": target, "by": "iphone"], to: code, key: me.publicKey) {
            if let id = copy.id { seen.insert(id) }
            _ = await post(copy.message, to: code)
        }
        return nil
    }

    /// Keeps a message to send at [at] (by the phone, so Dave has to be open then, or it goes the next time he is).
    func schedule(_ text: String, to friendCode: String, at: Date, reply: String? = nil) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !text.isEmpty else { return }
        scheduled.append(Scheduled(code: friendCode, text: text, reply: reply, at: at))
        scheduled.sort { $0.at < $1.at }
        save()
    }

    func unschedule(_ id: String) {
        scheduled.removeAll { $0.id == id }
        save()
    }

    /// Sends the scheduled messages whose time has come.
    func sendDue(settings: Settings) async {
        let due = scheduled.filter { $0.at <= Date() }
        guard !due.isEmpty else { return }
        scheduled.removeAll { m in due.contains { $0.id == m.id } }
        save()
        for m in due {
            guard await send(m.text, to: m.code, reply: m.reply, settings: settings) != nil else { continue }
            scheduled.append(Scheduled(code: m.code, text: m.text, reply: m.reply, at: Date().addingTimeInterval(60))) // try again in a minute
            save()
        }
    }

    // MARK: Voice message text, translations and link previews (worked out when needed, then kept)

    /// The words said in a voice message (Groq's speech-to-text).
    func transcribe(_ id: String, of friendCode: String, settings: Settings) async {
        guard let line = chats[friendCode]?.last(where: { $0.msgId == id && $0.kind == "voice" }), line.transcript == nil,
              let file = Self.url(of: line) else { return }
        change(friendCode, id, mine: line.mine) { $0.transcript = "…" }
        let heard = try? await Groq.transcribe(file, settings: settings, remember: false)
        let words = heard.map { $0.text.isEmpty ? settings.say("(nothing I could make out)", "(niets wat ik kon verstaan)") : $0.text }
        change(friendCode, id, mine: line.mine) { $0.transcript = words } // (nil when it failed: tap Aa again to retry)
    }

    /// A friend's message in your language; "=" when it already was.
    func translate(_ id: String, of friendCode: String, settings: Settings) async {
        guard settings.translate, let line = chats[friendCode]?.last(where: { $0.msgId == id && !$0.mine && $0.kind == nil }), line.translation == nil else { return }
        change(friendCode, id, mine: false) { $0.translation = "…" }
        let language = Locale(identifier: "en").localizedString(forLanguageCode: settings.language) ?? "English"
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Translate the user's chat message into \(language), keeping its tone, slang and emojis. "
                + "If it's already in \(language) (or has no words to translate), reply with exactly =. Reply with only the translation."],
            ["role": "user", "content": line.text],
        ]
        let reply = ((try? await Groq.chat(messages: messages, tools: [], settings: settings, search: false))?["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = reply.map { $0.isEmpty || $0 == "=" || $0.caseInsensitiveCompare(line.text) == .orderedSame ? "=" : $0 } // (nil: it failed)
        change(friendCode, id, mine: false) { $0.translation = translation }
    }

    /// The first link in a message: its page's title, text and picture (YouTube through its oEmbed, others from their og: tags).
    private func preview(_ id: String, of friendCode: String, mine: Bool) async {
        guard let line = chats[friendCode]?.last(where: { $0.msgId == id && $0.mine == mine }), line.kind == nil, line.preview == nil,
              let link = Self.firstLink(in: line.text) else { return }
        change(friendCode, id, mine: mine) { $0.preview = Preview(url: "-") }
        var found = Preview(url: link.absoluteString)
        let host = link.host?.lowercased() ?? ""
        if host.hasSuffix("youtube.com") || host == "youtu.be",
           let api = URL(string: "https://www.youtube.com/oembed?format=json&url=" + (link.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")),
           let (data, _) = try? await URLSession.shared.data(from: api), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            found.title = info["title"] as? String ?? ""
            found.text = info["author_name"] as? String ?? ""
            found.image = info["thumbnail_url"] as? String ?? ""
        } else {
            var request = URLRequest(url: link, timeoutInterval: 8)
            request.setValue("Mozilla/5.0 (compatible; Dave)", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.mimeType?.contains("html") == true,
               let html = String(data: data.prefix(400_000), encoding: .utf8) ?? String(data: data.prefix(400_000), encoding: .isoLatin1) {
                func meta(_ key: String) -> String {
                    for pattern in ["<meta[^>]+(?:property|name)=[\"']\(key)[\"'][^>]+content=[\"']([^\"']*)", "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(key)[\"']"] {
                        guard let r = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
                        let tag = String(html[r])
                        if let value = tag.range(of: "content=[\"']([^\"']*)", options: .regularExpression) {
                            return Self.decode(String(tag[value].dropFirst(9)))
                        }
                    }
                    return ""
                }
                found.title = meta("og:title")
                if found.title.isEmpty, let r = html.range(of: "<title[^>]*>[^<]*", options: [.regularExpression, .caseInsensitive]) {
                    found.title = Self.decode(String(html[r].drop { $0 != ">" }.dropFirst())).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                found.text = meta("og:description").isEmpty ? meta("description") : meta("og:description")
                found.image = meta("og:image")
                if !found.image.isEmpty, let full = URL(string: found.image, relativeTo: link) { found.image = full.absoluteString }
            }
        }
        if !found.image.hasPrefix("https://") { found.image = "" }
        let result = found.title.isEmpty ? Preview(url: "-") : Preview(url: found.url, title: String(found.title.prefix(200)), text: String(found.text.prefix(300)), image: found.image)
        change(friendCode, id, mine: mine) { $0.preview = result }
    }

    static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .first { $0.scheme == "https" || $0.scheme == "http" }
    }

    private static func decode(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return html }
        return text.string
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

    /// The id of the message a sealed one replies to (nil for none).
    private static func reply(_ inner: [String: Any]) -> String? {
        guard let reply = inner["reply"] as? String, !reply.isEmpty, reply.count <= 64 else { return nil }
        return reply
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
