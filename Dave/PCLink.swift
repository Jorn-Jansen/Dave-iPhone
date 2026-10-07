import Foundation

/// Talking to Dave on the Windows PC (Dave's settings there → "iPhone app": address and code).
enum PCLink {
    static let port = 47800

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Ask the PC Dave something ("pause the music", "lock my PC"); returns his answer.
    /// First a quick check that the PC answers at all, so an unreachable PC doesn't keep you waiting.
    static func ask(_ request: String, settings: Settings) async throws -> String {
        try await hello(settings: settings)
        let reply = try await post("/ask", body: ["text": request], settings: settings, timeout: 60)
        return reply["answer"] as? String ?? settings.say("Done.", "Klaar.")
    }

    /// A command the phone's AI already chose ("media_control" with action "pause", "lock_pc"…): the PC carries it out
    /// right away, without asking its own AI. Returns the outcome ("⏸ Paused").
    static func command(_ name: String, args: [String: Any], settings: Settings) async throws -> String {
        try await hello(settings: settings)
        let reply = try await post("/command", body: ["name": name, "args": args], settings: settings, timeout: 30)
        return reply["answer"] as? String ?? settings.say("Done.", "Klaar.")
    }

    /// What Dave's window on the PC shows: reminders, memories, what he's watching for, music, screen time.
    static func state(settings: Settings) async throws -> [String: Any] {
        try await hello(settings: settings)
        return try await post("/state", body: [:], settings: settings, timeout: 15)
    }

    /// A change from the app's tabs ("deleteReminder", "addMemory"…); returns the new state.
    static func change(_ change: [String: Any], settings: Settings) async throws -> [String: Any] {
        try await post("/action", body: change, settings: settings, timeout: 15)
    }

    /// The PC Dave's version ("1.4.0"), or nil when he can't be reached.
    static func version(settings: Settings) async -> String? {
        guard let url = try? url("/hello", settings: settings) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    /// Connect: checks the code and gets the PC Dave's name, languages, Groq key and memories.
    static func pair(settings: Settings) async throws -> [String: Any] {
        try await hello(settings: settings)
        return try await post("/pair", body: [:], settings: settings, timeout: 10)
    }

    /// Does Dave on the PC answer (within a few seconds)? Tried twice: after the phone was idle, the first message to the
    /// PC can take a few seconds to find its way (seen with mesh Wi-Fi), the second one is then quick.
    private static func hello(settings: Settings) async throws {
        var request = URLRequest(url: try url("/hello", settings: settings), timeoutInterval: 4)
        request.httpMethod = "GET"
        for attempt in 0..<2 {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: notDave(settings)) }
                return
            } catch let error as Failure { throw error }
            catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if attempt == 1 || (error as? URLError)?.code != .timedOut { throw explain(error, settings: settings) }
            }
        }
    }

    private static func url(_ path: String, settings: Settings) throws -> URL {
        var address = settings.pcAddress.trimmingCharacters(in: .whitespaces)
        if address.hasPrefix("http://") { address.removeFirst(7) }
        if !address.contains(":") { address += ":\(port)" }
        guard let url = URL(string: "http://\(address)\(path)") else {
            throw Failure(message: settings.say("That PC address doesn't look right. It's like 192.168.1.20.", "Dat pc-adres klopt niet. Het lijkt op 192.168.1.20."))
        }
        return url
    }

    private static func post(_ path: String, body: [String: Any], settings: Settings, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: try url(path, settings: settings), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.pcCode.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "X-Dave-Code")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw explain(error, settings: settings) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw Failure(message: settings.say("Dave on your PC is too old for this: update him to the newest version (right-click his tray icon → Check for updates).",
                                                "Dave op je pc is hier te oud voor: update hem naar de nieuwste versie (rechtsklik zijn icoon bij de klok → Controleren op updates)."))
        }
        if status == 401 { throw Failure(message: settings.say("The code is wrong. Check it in Dave's settings on the PC, under iPhone app.", "De code klopt niet. Kijk in de instellingen van Dave op de pc, bij iPhone-app.")) }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: settings.say("Your PC gave an odd answer (\(status)).", "Je pc gaf een vreemd antwoord (\(status))."))
        }
        return json
    }

    private static func notDave(_ settings: Settings) -> String {
        settings.say("Something answers at that address, but it isn't Dave. Check the address in Dave's settings on the PC.",
                     "Er antwoordt iets op dat adres, maar het is Dave niet. Kijk naar het adres in de instellingen van Dave op de pc.")
    }

    /// Why the PC couldn't be reached, in words that say what to do about it.
    private static func explain(_ error: Error, settings: Settings) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        guard let code = (error as? URLError)?.code else { return Failure(message: error.localizedDescription) }
        switch code {
        case .timedOut:
            return Failure(message: settings.say(
                "Your PC doesn't answer. Usually Windows' firewall blocks Dave: on the PC, allow Dave for private and public networks (Start → \"Allow an app through Windows Firewall\"). Also check the address, and that you're on the same Wi-Fi, not a guest network.",
                "Je pc antwoordt niet. Meestal blokkeert de firewall van Windows Dave: sta Dave op de pc toe voor privé- en openbare netwerken (Start → \"Een app toestaan via Windows Firewall\"). Check ook het adres, en of je op dezelfde wifi zit, geen gastnetwerk."))
        case .cannotConnectToHost:
            return Failure(message: settings.say(
                "The PC is there, but Dave isn't listening. Is Dave running, with iPhone app turned on in his settings?",
                "De pc is er wel, maar Dave luistert niet. Draait Dave, met iPhone-app aan in zijn instellingen?"))
        case .notConnectedToInternet, .networkConnectionLost:
            return Failure(message: settings.say(
                "iOS doesn't let me on your local network. Turn it on: iPhone Settings → Privacy & Security → Local Network → Dave. Then try again.",
                "iOS laat me niet op je lokale netwerk. Zet het aan: iPhone-instellingen → Privacy en beveiliging → Lokaal netwerk → Dave. Probeer het dan opnieuw."))
        case .cannotFindHost, .dnsLookupFailed, .badURL, .unsupportedURL:
            return Failure(message: settings.say("That PC address doesn't work. Check it in Dave's settings on the PC, under iPhone app.",
                                                 "Dat pc-adres werkt niet. Kijk in de instellingen van Dave op de pc, bij iPhone-app."))
        default:
            return Failure(message: settings.say("I can't reach your PC (\(error.localizedDescription)).", "Ik kan je pc niet bereiken (\(error.localizedDescription))."))
        }
    }
}
