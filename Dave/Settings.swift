import Foundation

/// Dave's settings on the phone. Kept on the phone only (the Groq key never leaves it, except to Groq itself).
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var groqKey: String { didSet { defaults.set(groqKey, forKey: "groqKey") } }
    @Published var name: String { didSet { defaults.set(name, forKey: "name") } }
    /// "nl-NL" or "en-US": the language Dave answers typed questions in (spoken ones: the language you spoke).
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var country: String { didSet { defaults.set(country, forKey: "country") } }
    /// The PC's address on the network (e.g. 192.168.1.20) and the code from Dave's settings on the PC.
    @Published var pcAddress: String { didSet { defaults.set(pcAddress, forKey: "pcAddress"); if pcAddress != oldValue { pcLinked = false } } }
    @Published var pcCode: String { didSet { defaults.set(pcCode, forKey: "pcCode"); if pcCode != oldValue { pcLinked = false } } }
    /// The PC answered the last time it was tried (connecting or a question): only then it says "linked".
    @Published var pcLinked: Bool { didSet { defaults.set(pcLinked, forKey: "pcLinked") } }
    /// Things the user asked Dave to remember (copied from the PC when connecting).
    @Published var memories: [String] { didSet { defaults.set(memories, forKey: "memories") } }
    /// Spotify: the Client ID of the user's Spotify developer app (copied from the PC), and the phone's own login.
    @Published var spotifyClientId: String { didSet { defaults.set(spotifyClientId, forKey: "spotifyClientId") } }
    @Published var spotifyRefreshToken: String { didSet { defaults.set(spotifyRefreshToken, forKey: "spotifyRefreshToken") } }
    var spotifyAccessToken: String { didSet { defaults.set(spotifyAccessToken, forKey: "spotifyAccessToken") } }
    var spotifyTokenExpires: Double { didSet { defaults.set(spotifyTokenExpires, forKey: "spotifyTokenExpires") } }
    /// The colour theme (see Theme.all), like on the PC.
    @Published var theme: String { didSet { defaults.set(theme, forKey: "theme") } }
    /// 0.4 (slow) … 0.6 (fast); 0.5 is iOS' normal speed.
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }

    private init() {
        groqKey = defaults.string(forKey: "groqKey") ?? ""
        name = defaults.string(forKey: "name") ?? "Dave"
        language = defaults.string(forKey: "language") ?? "nl-NL"
        country = defaults.string(forKey: "country") ?? "the Netherlands"
        pcAddress = defaults.string(forKey: "pcAddress") ?? ""
        pcCode = defaults.string(forKey: "pcCode") ?? ""
        pcLinked = defaults.bool(forKey: "pcLinked")
        memories = defaults.stringArray(forKey: "memories") ?? []
        theme = defaults.string(forKey: "theme") ?? "aurora"
        spotifyClientId = defaults.string(forKey: "spotifyClientId") ?? ""
        spotifyRefreshToken = defaults.string(forKey: "spotifyRefreshToken") ?? ""
        spotifyAccessToken = defaults.string(forKey: "spotifyAccessToken") ?? ""
        spotifyTokenExpires = defaults.double(forKey: "spotifyTokenExpires")
        speechRate = defaults.object(forKey: "speechRate") as? Double ?? 0.5
    }

    var hasPC: Bool { !pcAddress.trimmingCharacters(in: .whitespaces).isEmpty && !pcCode.isEmpty }
    var isDutch: Bool { language.hasPrefix("nl") }
    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Dave" : name }

    /// English or Dutch version of one of Dave's own messages.
    func say(_ english: String, _ dutch: String) -> String { isDutch ? dutch : english }
}
