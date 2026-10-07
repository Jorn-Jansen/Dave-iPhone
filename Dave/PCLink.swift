import Foundation

/// Talking to Dave on the Windows PC (Dave's settings there → "iPhone app": address and code).
enum PCLink {
    static let port = 47800

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Ask the PC Dave something ("pause the music", "lock my PC"); returns his answer.
    static func ask(_ request: String, settings: Settings) async throws -> String {
        let reply = try await post("/ask", body: ["text": request], settings: settings, timeout: 120)
        return reply["answer"] as? String ?? settings.say("Done.", "Klaar.")
    }

    /// Connect: checks the code and gets the PC Dave's name, languages, Groq key and memories.
    static func pair(settings: Settings) async throws -> [String: Any] {
        try await post("/pair", body: [:], settings: settings, timeout: 15)
    }

    private static func url(_ path: String, settings: Settings) throws -> URL {
        var address = settings.pcAddress.trimmingCharacters(in: .whitespaces)
        if address.hasPrefix("http://") { address.removeFirst(7) }
        if !address.contains(":") { address += ":\(port)" }
        guard let url = URL(string: "http://\(address)\(path)") else {
            throw Failure(message: settings.say("That PC address doesn't look right.", "Dat pc-adres klopt niet."))
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
        catch {
            throw Failure(message: settings.say(
                "I can't reach your PC. Is it on, with Dave running and the iPhone link turned on, and are you on the same Wi-Fi?",
                "Ik kan je pc niet bereiken. Staat hij aan, draait Dave met de iPhone-koppeling aan, en zit je op dezelfde wifi?"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure(message: settings.say("The PC code is wrong. Check it in Dave's settings on the PC.", "De pc-code klopt niet. Kijk in de instellingen van Dave op de pc.")) }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: settings.say("Your PC gave an odd answer (\(status)).", "Je pc gaf een vreemd antwoord (\(status))."))
        }
        return json
    }
}
