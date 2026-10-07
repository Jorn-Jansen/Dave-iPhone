import Foundation

/// "A new Dave is out": checks the Dave-iPhone releases on GitHub once a day. Once a newer version is found, the
/// notice shows every time the app starts until it's installed ("Later" only hides it until the next start).
/// A sideloaded app can't update itself: the new Dave.ipa is installed from the PC with Sideloadly, so the notice
/// can open the download page there.
@MainActor
final class Updater: ObservableObject {
    struct Release {
        let version: String
        let page: URL
    }

    /// The newer release, while the notice should show.
    @Published var available: Release?

    private let defaults = UserDefaults.standard
    private var hiddenUntilRestart = false

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    init() {
        // An update found earlier (and not installed yet): remind right away, no need to ask GitHub first
        if let version = defaults.string(forKey: "updateFound"), Self.isNewer(version, than: Self.currentVersion),
           let page = defaults.string(forKey: "updatePage").flatMap(URL.init(string:)) {
            available = Release(version: version, page: page)
        }
    }

    /// Ask GitHub, at most once a day.
    func check() async {
        guard Date().timeIntervalSince1970 - defaults.double(forKey: "updateChecked") > 20 * 3600 else { return }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Jorn-Jansen/Dave-iPhone/releases/latest")!, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: "updateChecked")
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        if Self.isNewer(version, than: Self.currentVersion) {
            defaults.set(version, forKey: "updateFound")
            defaults.set(page.absoluteString, forKey: "updatePage")
            if !hiddenUntilRestart { available = Release(version: version, page: page) }
        } else {
            defaults.removeObject(forKey: "updateFound") // up to date (or updated): no more reminders
            available = nil
        }
    }

    /// "Later": gone until the app starts again.
    func later() {
        hiddenUntilRestart = true
        available = nil
    }

    /// "1.10.0" is newer than "1.9.2": compares the numbers, not the text.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
