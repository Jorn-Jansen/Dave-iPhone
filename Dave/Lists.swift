import CryptoKit
import Foundation

/// Lists (shopping, chores, a packing list…) in the Lists tab. Each list is either the whole house's (shared with Dave on the
/// Pi and every phone with the house code, from `sudo dave lijst koppel`) or just yours (only your own devices, with your own
/// code). Both go through ntfy.sh, end-to-end encrypted with a key that comes from the code, on a channel that comes from the
/// code: without the code nobody finds or reads them.
///
/// Staying the same everywhere: every change goes out as the lists / items that changed, each with the moment it changed;
/// everyone keeps the newest version of each list and item (two people adding something at once: both stay). When the app
/// opens it asks for everything ("hello"); the Pi (always on) answers with all the house's lists, your other devices with
/// yours. The Pi does exactly the same (Dave Pi's lists.py): change both together.
@MainActor
final class Lists: ObservableObject {
    static let shared = Lists()

    struct Item: Codable, Identifiable, Equatable {
        var id: String
        var t: String          // the text
        var d: Bool = false    // ticked off
        var x: Bool = false    // deleted
        var u: Int64           // changed at (ms)
        var o: Int64           // order (made at, ms)

        init(id: String, t: String, d: Bool = false, x: Bool = false, u: Int64, o: Int64) {
            (self.id, self.t, self.d, self.x, self.u, self.o) = (id, t, d, x, u, o)
        }

        init(from decoder: Decoder) throws { // (lenient: what the Pi or another device leaves out gets its default)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            t = try c.decodeIfPresent(String.self, forKey: .t) ?? ""
            d = try c.decodeIfPresent(Bool.self, forKey: .d) ?? false
            x = try c.decodeIfPresent(Bool.self, forKey: .x) ?? false
            u = try c.decodeIfPresent(Int64.self, forKey: .u) ?? 0
            o = try c.decodeIfPresent(Int64.self, forKey: .o) ?? u
        }
    }

    struct List: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var nu: Int64          // name changed at
        var del: Bool = false
        var du: Int64          // deleted / made at
        var items: [Item] = []
        var space: String? = nil  // "house" or "me" (only on this phone: not sent)

        init(id: String, name: String, nu: Int64, del: Bool = false, du: Int64, items: [Item] = [], space: String? = nil) {
            (self.id, self.name, self.nu, self.del, self.du, self.items, self.space) = (id, name, nu, del, du, items, space)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "?"
            nu = try c.decodeIfPresent(Int64.self, forKey: .nu) ?? 0
            del = try c.decodeIfPresent(Bool.self, forKey: .del) ?? false
            du = try c.decodeIfPresent(Int64.self, forKey: .du) ?? 0
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
            space = try c.decodeIfPresent(String.self, forKey: .space)
        }

        var open: [Item] { items.filter { !$0.x && !$0.d }.sorted { $0.o < $1.o } }
        var done: [Item] { items.filter { !$0.x && $0.d }.sorted { $0.o < $1.o } }
        func wire() -> List { var l = self; l.space = nil; return l }
    }

    @Published private(set) var lists: [List] = []
    /// The house code (from the Pi) and your own code (made here; type it into your other devices).
    @Published private(set) var houseCode = ""
    @Published private(set) var myCode = ""
    @Published var problem: String?

    private var since: [String: String] = [:]
    private var outbox: [String: [String]] = [:]   // per space: messages that didn't go out yet (no internet)
    private let device = "phone-" + String(UUID().uuidString.prefix(8)).lowercased()
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let version = "lists1"
    private static let keepDeleted: Int64 = 30 * 86_400_000
    private static let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("lists.json")

    private struct Saved: Codable {
        var lists: [List]
        var houseCode: String
        var myCode: String
        var since: [String: String]
        var outbox: [String: [String]]?
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            (lists, houseCode, myCode, since) = (saved.lists, saved.houseCode, saved.myCode, saved.since)
            outbox = saved.outbox ?? [:]
        }
        if myCode.isEmpty { myCode = Self.newCode("MIJN"); save() }
    }

    private func save() {
        let saved = Saved(lists: lists, houseCode: houseCode, myCode: myCode, since: since, outbox: outbox)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.file, options: [.atomic, .completeFileProtection]) }
    }

    var visible: [List] { lists.filter { !$0.del }.sorted { $0.du < $1.du } }
    func list(_ id: String) -> List? { lists.first { $0.id == id && !$0.del } }

    // MARK: Codes

    static func newCode(_ prefix: String) -> String {
        prefix + "-" + (0..<4).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
    }

    /// "huis k7qx m2pa…" → "HUIS-K7QX-M2PA-9TRB-W4NE" (nil when it isn't one).
    static func normal(_ code: String) -> String? {
        let s = Array(code.uppercased().filter { $0.isLetter || $0.isNumber })
        guard s.count == 20, s[4...].allSatisfy({ alphabet.contains($0) }) else { return nil }
        return ([String(s[0..<4])] + stride(from: 4, to: 20, by: 4).map { String(s[$0..<$0 + 4]) }).joined(separator: "-")
    }

    /// Joins the house (the code from `sudo dave lijst koppel`, or its QR code). Returns a problem, or nil.
    func joinHouse(_ code: String) -> String? {
        guard let c = Self.normal(code), c.hasPrefix("HUIS") else {
            return Settings.shared.say("That's not a house code (it starts with HUIS-).", "Dat is geen huiscode (die begint met HUIS-).")
        }
        if c != houseCode {
            lists.removeAll { $0.space == "house" } // (another house: its lists come from its Pi)
            houseCode = c
            since["house"] = nil
            save()
            Task { await hello("house") }
        }
        return nil
    }

    func leaveHouse() {
        lists.removeAll { $0.space == "house" }
        houseCode = ""
        save()
    }

    /// Your own code from another of your devices: their personal lists and these come together.
    func useMyCode(_ code: String) -> String? {
        guard let c = Self.normal(code), c.hasPrefix("MIJN") else {
            return Settings.shared.say("That's not a personal code (it starts with MIJN-).", "Dat is geen eigen code (die begint met MIJN-).")
        }
        if c != myCode {
            let mine = lists.filter { $0.space == "me" }
            myCode = c
            since["me"] = nil
            save()
            Task { await send(mine, in: "me"); await hello("me") } // what was here goes to the others too
        }
        return nil
    }

    private func code(_ space: String) -> String { space == "house" ? houseCode : myCode }
    private static func topic(_ code: String) -> String {
        "dave-lists-" + SHA256.hash(data: Data("dave-lists-topic \(code)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
    }
    private static func key(_ code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data("dave-lists-v1".utf8),
                               info: Data("key".utf8), outputByteCount: 32)
    }

    private func seal(_ inner: [String: Any], _ code: String) -> String? {
        guard let plain = try? JSONSerialization.data(withJSONObject: inner),
              let box = try? AES.GCM.seal(plain, using: Self.key(code), nonce: AES.GCM.Nonce(), authenticating: Data(Self.version.utf8)) else { return nil }
        let message: [String: Any] = ["dave": Self.version, "from": device, "n": box.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
                                      "c": box.ciphertext.base64EncodedString(), "t": box.tag.base64EncodedString()]
        return (try? JSONSerialization.data(withJSONObject: message)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func unseal(_ body: String, _ code: String) -> (inner: [String: Any], from: String)? {
        guard let m = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any], m["dave"] as? String == Self.version,
              let n = Data(base64Encoded: m["n"] as? String ?? ""), let c = Data(base64Encoded: m["c"] as? String ?? ""),
              let t = Data(base64Encoded: m["t"] as? String ?? ""),
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: n), ciphertext: c, tag: t),
              let plain = try? AES.GCM.open(box, using: Self.key(code), authenticating: Data(Self.version.utf8)),
              let inner = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return nil }
        return (inner, m["from"] as? String ?? "")
    }

    // MARK: Changing

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func newId() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased() }

    func create(_ name: String, space: String) {
        let name = String(name.trimmingCharacters(in: .whitespaces).prefix(60))
        guard !name.isEmpty else { return }
        let now = Self.now()
        let l = List(id: Self.newId(), name: name, nu: now, du: now, space: space)
        lists.append(l)
        save()
        Task { await send([l], in: space) }
    }

    /// One list changed (by [edit], which returns the items it changed); saved and sent.
    private func change(_ id: String, _ edit: (inout List, Int64) -> [Item]) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        var l = lists[index]
        let touched = edit(&l, Self.now())
        lists[index] = l
        save()
        var out = l
        out.items = touched
        Task { await send([out], in: l.space ?? "me") }
    }

    func rename(_ id: String, to name: String) {
        let name = String(name.trimmingCharacters(in: .whitespaces).prefix(60))
        guard !name.isEmpty else { return }
        change(id) { l, now in l.name = name; l.nu = now; return [] }
    }

    func delete(_ id: String) { change(id) { l, now in l.del = true; l.du = now; return [] } }

    /// Things on a list; what's on it already isn't added twice (something ticked off comes back). Returns (added, already).
    @discardableResult
    func add(_ things: [String], to id: String) -> (added: [String], already: [String]) {
        var added: [String] = [], already: [String] = []
        change(id) { l, now in
            var touched: [Item] = []
            for (n, raw) in things.enumerated() {
                let text = String(raw.trimmingCharacters(in: .whitespaces).prefix(80))
                guard !text.isEmpty else { continue }
                if let i = l.items.firstIndex(where: { !$0.x && Self.simple($0.t) == Self.simple(text) }) {
                    if !l.items[i].d { already.append(text); continue }
                    l.items[i].d = false; l.items[i].u = now + Int64(n)
                    touched.append(l.items[i]); added.append(text)
                } else {
                    let item = Item(id: Self.newId(), t: text, u: now + Int64(n), o: now + Int64(n))
                    l.items.append(item); touched.append(item); added.append(text)
                }
            }
            return touched
        }
        return (added, already)
    }

    func toggle(_ itemId: String, in id: String) {
        change(id) { l, now in
            guard let i = l.items.firstIndex(where: { $0.id == itemId }) else { return [] }
            l.items[i].d.toggle(); l.items[i].u = now
            return [l.items[i]]
        }
    }

    func edit(_ itemId: String, in id: String, to text: String) {
        let text = String(text.trimmingCharacters(in: .whitespaces).prefix(80))
        guard !text.isEmpty else { return }
        change(id) { l, now in
            guard let i = l.items.firstIndex(where: { $0.id == itemId }) else { return [] }
            l.items[i].t = text; l.items[i].u = now
            return [l.items[i]]
        }
    }

    func remove(_ itemIds: [String], from id: String) {
        change(id) { l, now in
            var touched: [Item] = []
            for i in l.items.indices where itemIds.contains(l.items[i].id) && !l.items[i].x {
                l.items[i].x = true; l.items[i].u = now; touched.append(l.items[i])
            }
            return touched
        }
    }

    func clearDone(_ id: String) { remove(list(id)?.done.map(\.id) ?? [], from: id) }

    // MARK: Merging what comes in

    private func merge(_ incoming: [[String: Any]], space: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: incoming),
              let news = try? JSONDecoder().decode([List].self, from: data) else { return }
        var changed = false
        for new in news {
            var old = lists.first { $0.id == new.id } ?? List(id: new.id, name: new.name, nu: 0, du: 0, space: space)
            let before = old
            if new.nu > old.nu { old.name = new.name; old.nu = new.nu }
            if new.du > old.du { old.del = new.del; old.du = new.du }
            for item in new.items {
                if let i = old.items.firstIndex(where: { $0.id == item.id }) {
                    if item.u > old.items[i].u { old.items[i] = item }
                } else {
                    old.items.append(item)
                }
            }
            old.space = old.space ?? space
            if old != before {
                if let i = lists.firstIndex(where: { $0.id == old.id }) { lists[i] = old } else { lists.append(old) }
                changed = true
            }
        }
        if changed { prune(); save() }
    }

    private func prune() {
        let cutoff = Self.now() - Self.keepDeleted
        lists.removeAll { $0.del && $0.du < cutoff }
        for i in lists.indices { lists[i].items.removeAll { $0.x && $0.u < cutoff } }
    }

    // MARK: Sending and listening

    private var spaces: [String] { (houseCode.isEmpty ? [] : ["house"]) + ["me"] }

    /// The lists as messages small enough for ntfy (4 KB): a big list goes in parts (the same list, part of its items).
    private func parts(_ lists: [List]) -> [[[String: Any]]] {
        func json(_ l: [List]) -> [[String: Any]] {
            (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(l))) as? [[String: Any]] ?? []
        }
        func size(_ l: [List]) -> Int { (try? JSONEncoder().encode(l).count) ?? 0 }
        var out: [[List]] = [], current: [List] = []
        for l in lists.map({ $0.wire() }) {
            var chunk = l
            chunk.items = []
            for item in l.items {
                chunk.items.append(item)
                if size(current + [chunk]) > 2300 && chunk.items.count > 1 {
                    chunk.items.removeLast()
                    out.append(current + [chunk])
                    current = []
                    chunk.items = [item]
                }
            }
            if !current.isEmpty && size(current + [chunk]) > 2300 { out.append(current); current = [] }
            current.append(chunk)
        }
        if !current.isEmpty { out.append(current) }
        return out.map(json)
    }

    private func send(_ lists: [List], in space: String) async {
        let c = code(space)
        guard !c.isEmpty else { return }
        for part in parts(lists) {
            if let body = seal(["type": "lists", "lists": part], c) { outbox[space, default: []].append(body) }
        }
        save()
        await flush()
    }

    /// Asks for everything (the Pi answers with the house's lists, your other devices with yours).
    func hello(_ space: String) async {
        guard let body = seal(["type": "hello"], code(space)) else { return }
        _ = await post(body, to: code(space))
    }

    /// What didn't go out yet (no internet in the shop): sent now, in order.
    func flush() async {
        for space in spaces {
            while let body = outbox[space]?.first {
                guard await post(body, to: code(space)) else { problem = Settings.shared.say("Not sent yet: no internet.", "Nog niet verstuurd: geen internet."); return }
                outbox[space]?.removeFirst()
                save()
            }
        }
        problem = nil
    }

    private func post(_ body: String, to code: String) async -> Bool {
        guard !code.isEmpty, let url = URL(string: "https://ntfy.sh/\(Self.topic(code))") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Pull to refresh: what's waiting goes out, and everyone is asked for everything again.
    func listenOnce() async {
        await flush()
        for space in spaces { await hello(space) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// While Dave is open: asks for everything once, then listens to the house's channel and your own, as changes come.
    func listen() async {
        await flush()
        for space in spaces { await hello(space) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.listen(to: "house") }
            group.addTask { await self.listen(to: "me") }
        }
    }

    private func listen(to space: String) async {
        while !Task.isCancelled {
            let c = code(space)
            if !c.isEmpty, let url = URL(string: "https://ntfy.sh/\(Self.topic(c))/json?since=\(since[space] ?? "12h")") {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(from: url)
                    for try await line in bytes.lines {
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              event["event"] as? String == "message" else { continue }
                        if let message = event["message"] as? String { await handle(message, space: space, code: c) }
                        if let id = event["id"] as? String { since[space] = id; save() }
                        if code(space) != c { break } // (joined another house meanwhile)
                    }
                } catch {
                    if Task.isCancelled { return }
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func handle(_ body: String, space: String, code c: String) async {
        guard let opened = unseal(body, c), opened.from != device else { return }
        let inner = opened.inner
        switch inner["type"] as? String {
        case "lists": merge((inner["lists"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [], space: space)
        case "hello" where space == "me": await send(lists.filter { $0.space == "me" }, in: "me") // (the house's: the Pi answers)
        default: break
        }
    }

    // MARK: For Dave (the "lists" command)

    static func simple(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The list someone means, by (part of) its name; none said and just one list, or a shopping list: that one.
    func find(_ name: String) -> List? {
        var want = Self.simple(name)
        for word in ["lijstje", "lijst", "list"] where want.hasSuffix(word) && want.count > word.count { want = String(want.dropLast(word.count)) }
        let all = visible
        if !want.isEmpty {
            return all.first { [want, want + "lijst", want + "list"].contains(Self.simple($0.name)) }
                ?? all.first { Self.simple($0.name).contains(want) || want.contains(Self.simple($0.name)) }
        }
        if all.count == 1 { return all[0] }
        return all.first { Self.simple($0.name).contains("boodschap") || Self.simple($0.name).contains("shopping") }
    }

    func describe(_ l: List, _ settings: Settings) -> String {
        let open = l.open.map(\.t), done = l.done.map(\.t)
        if open.isEmpty && done.isEmpty { return settings.say("\(l.name) is empty.", "\(l.name) is leeg.") }
        return "\(l.name): " + (open.isEmpty ? settings.say("all done", "alles afgevinkt") : open.joined(separator: ", "))
            + (done.isEmpty ? "" : settings.say(" (done: ", " (afgevinkt: ") + done.joined(separator: ", ") + ")")
    }

    /// What Dave does with "zet melk op de boodschappenlijst", "wat staat er op de lijst?"…
    func run(_ args: [String: Any], settings: Settings) -> String {
        let action = args["action"] as? String ?? "show"
        let name = args["list"] as? String ?? ""
        let things = (args["items"] as? String ?? "").components(separatedBy: CharacterSet(charactersIn: ","))
            .flatMap { $0.components(separatedBy: " en ") }.flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let names = visible.map(\.name).joined(separator: ", ")
        if action == "create" {
            let space = (args["shared"] as? Bool ?? false) && !houseCode.isEmpty ? "house" : "me"
            create(name, space: space)
            return settings.say("List \(name) made", "Lijst \(name) gemaakt") + (space == "house" ? settings.say(" (for the whole house).", " (voor het hele huis).") : settings.say(" (just for you).", " (alleen voor jou)."))
        }
        if action == "show" && name.isEmpty && visible.count > 1 {
            return visible.map { describe($0, settings) }.joined(separator: "; ")
        }
        guard let l = find(name) else {
            return visible.isEmpty ? settings.say("There are no lists yet: make one in the Lists tab, or say \"make a shopping list\".",
                                                  "Er zijn nog geen lijsten: maak er een in het tabblad Lijsten, of zeg \"maak een boodschappenlijst\".")
                                   : settings.say("There's no list called \(name). The lists: \(names).", "Er is geen lijst die \(name) heet. De lijsten: \(names).")
        }
        switch action {
        case "add":
            let (added, already) = add(things, to: l.id)
            return (added.isEmpty ? "" : settings.say("On \(l.name): ", "Op \(l.name): ") + added.joined(separator: ", ") + ". ")
                + (already.isEmpty ? "" : settings.say("Already on it: ", "Stond er al op: ") + already.joined(separator: ", ") + ".")
        case "remove", "check", "uncheck":
            let live = l.items.filter { !$0.x }
            let hits = things.flatMap { thing -> [Item] in
                let exact = live.filter { Self.simple($0.t) == Self.simple(thing) }
                return exact.isEmpty ? live.filter { !Self.simple(thing).isEmpty && Self.simple($0.t).contains(Self.simple(thing)) } : exact
            }
            if hits.isEmpty { return settings.say("That's not on \(l.name).", "Dat staat niet op \(l.name).") }
            if action == "remove" { remove(hits.map(\.id), from: l.id); return settings.say("Off \(l.name): ", "Van \(l.name) af: ") + hits.map(\.t).joined(separator: ", ") + "." }
            for item in hits where item.d != (action == "check") { toggle(item.id, in: l.id) }
            return (action == "check" ? settings.say("Ticked off: ", "Afgevinkt: ") : settings.say("Not done anymore: ", "Weer open: ")) + hits.map(\.t).joined(separator: ", ") + "."
        case "clear_done":
            let count = l.done.count
            clearDone(l.id)
            return settings.say("Cleared \(count) from \(l.name).", "\(count) van \(l.name) gehaald.")
        case "delete":
            delete(l.id)
            return settings.say("List \(l.name) deleted.", "Lijst \(l.name) verwijderd.")
        default:
            return describe(l, settings)
        }
    }
}
