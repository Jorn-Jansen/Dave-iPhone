import Foundation
import UIKit

/// The AI (chat, with web search) and speech recognition (Whisper), on Groq's free tier, like Dave on the PC.
enum Groq {
    static let api = "https://api.groq.com/openai/v1"
    static let model = "openai/gpt-oss-120b"
    /// Smaller model with its own daily allowance, for when the main one's is used up.
    static let fallbackModel = "openai/gpt-oss-20b"
    private static var useFallbackUntil = Date.distantPast
    private static var searchAvailable = true

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Send a chat; returns the first choice's message. Web search is added when the account allows it.
    static func chat(messages: [[String: Any]], tools: [[String: Any]], settings: Settings, search: Bool = true, model chosenModel: String? = nil) async throws -> [String: Any] {
        guard !settings.groqKey.isEmpty else {
            throw Failure(message: settings.say("I need a Groq key first: connect to your PC in the settings, or paste a key there.",
                                                "Ik heb eerst een Groq-sleutel nodig: koppel je pc in de instellingen, of plak daar een sleutel."))
        }
        var allTools = tools
        if searchAvailable && search { allTools.append(["type": "browser_search"]) }
        var hideThinking = true // (some picture models don't know this option: then without)
        for attempt in 0..<3 {
            var body: [String: Any] = [
                "model": chosenModel ?? (Date() < useFallbackUntil ? fallbackModel : model),
                "messages": messages,
            ]
            if chosenModel == nil { body["reasoning_effort"] = "low" } else if hideThinking { body["reasoning_format"] = "hidden" }
            if !allTools.isEmpty { body["tools"] = allTools }
            let (status, data) = try await send("/chat/completions", json: body, settings: settings)
            let text = String(data: data, encoding: .utf8) ?? ""
            if (200..<300).contains(status),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any] {
                return message
            }
            if status == 400 && hideThinking && text.contains("reasoning_format") {
                hideThinking = false
                continue
            }
            if (status == 400 || status == 403) && searchAvailable && text.contains("browser_search") {
                searchAvailable = false // web search isn't allowed on this account: carry on without it
                allTools.removeAll { ($0["type"] as? String) == "browser_search" }
                continue
            }
            if status == 429 && attempt < 2 {
                if text.contains("per day") && Date() >= useFallbackUntil {
                    useFallbackUntil = Date().addingTimeInterval(3600) // daily limit: the smaller model for an hour
                    continue
                }
                if let wait = waitTime(text), wait <= 20 {
                    try await Task.sleep(nanoseconds: UInt64((wait + 0.5) * 1_000_000_000))
                    continue
                }
            }
            throw failure(status: status, text: text, settings: settings)
        }
        throw failure(status: 429, text: "", settings: settings)
    }

    /// The model that can look at pictures (the same as Dave on the PC uses).
    static let visionModel = "qwen/qwen3.8-27b"

    /// Answer [question] about pictures (a photo, a screenshot, what was copied), as a short spoken answer.
    static func look(at images: [UIImage], question: String, what: String, language: String, settings: Settings) async throws -> String {
        let languageName = language.hasPrefix("nl") ? "Dutch" : "English"
        let system = """
        You are \(settings.displayName), a voice assistant. The image(s) are \(what). You CAN see them: they are attached to the message.
        Answer the user's question about them in \(languageName), in one to three short spoken sentences (more only if they ask to read something out).
        Plain speech only: no markdown, lists, emojis or symbols.
        """
        var content: [[String: Any]] = [["type": "text", "text": question]]
        for image in images.prefix(4) {
            guard let jpeg = scaled(image, maxSide: 1600).jpegData(compressionQuality: 0.7) else { continue }
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]])
        }
        let message = try await chat(messages: [["role": "system", "content": system], ["role": "user", "content": content]],
                                     tools: [], settings: settings, search: false, model: visionModel)
        let answer = (message["content"] as? String ?? "").replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Do [task] with [material] (what was copied, a file), as a short spoken answer.
    static func work(on material: String, task: String, what: String, language: String, settings: Settings) async throws -> String {
        let languageName = language.hasPrefix("nl") ? "Dutch" : "English"
        let system = "You are \(settings.displayName), a voice assistant on the user's iPhone. Below is \(what). Do what the user asks with it. "
            + "Answer in \(languageName), as speech: one to three short sentences (more only if they ask to read it out or explain it in detail). "
            + "When asked to read text out, read it as it is if it's short, otherwise summarise it. Plain speech only: no markdown, lists, emojis or symbols."
        let message = try await chat(messages: [["role": "system", "content": system], ["role": "user", "content": "\(task)\n\n---\n\(material)"]],
                                     tools: [], settings: settings, search: false)
        return (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let factor = maxSide / side
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// What was said in the recording (an .m4a), and the language Whisper heard ("dutch", "english", …).
    static func transcribe(_ audio: URL, settings: Settings) async throws -> (text: String, language: String) {
        guard !settings.groqKey.isEmpty else { throw Failure(message: settings.say("I need a Groq key first.", "Ik heb eerst een Groq-sleutel nodig.")) }
        let boundary = "Dave-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "whisper-large-v3-turbo")
        field("response_format", "verbose_json")
        field("prompt", "Hé \(settings.displayName), zet de muziek op pauze. Hey \(settings.displayName), what's the weather tomorrow?")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.m4a\"\r\nContent-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audio))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: api + "/audio/transcriptions")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.groqKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure(status: status, text: String(data: data, encoding: .utf8) ?? "", settings: settings)
        }
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (isHallucination(text) ? "" : text, json["language"] as? String ?? "")
    }

    private static func send(_ path: String, json: [String: Any], settings: Settings) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: api + path)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.groqKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw Failure(message: settings.say("I can't reach the internet right now.", "Ik kan nu niet bij het internet."))
        }
    }

    /// "Please try again in 7.5s" → 7.5
    private static func waitTime(_ text: String) -> Double? {
        guard let range = text.range(of: #"try again in ([0-9.]+)s"#, options: .regularExpression) else { return nil }
        let number = text[range].replacingOccurrences(of: "try again in ", with: "").replacingOccurrences(of: "s", with: "")
        return Double(number)
    }

    private static func failure(status: Int, text: String, settings: Settings) -> Failure {
        switch status {
        case 401: return Failure(message: settings.say("My Groq key doesn't work. Check it in the settings.", "Mijn Groq-sleutel werkt niet. Kijk in de instellingen."))
        case 429: return Failure(message: text.contains("per day")
            ? settings.say("I've used up today's free AI allowance. It frees up again over the next hours.", "Ik heb de gratis AI van vandaag opgemaakt. Over een paar uur kan het weer.")
            : settings.say("I've hit my usage limit. Try again in a moment.", "Ik zit even aan mijn limiet. Probeer het zo nog eens."))
        default: return Failure(message: settings.say("The AI had a problem (\(status)).", "De AI had een probleem (\(status))."))
        }
    }

    /// Whisper "hears" these in silence or noise.
    private static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["", "thank you", "thanks for watching", "bedankt voor het kijken", "you", "ondertiteling", "subtitles", "bye"].contains(t)
            || t.contains("amara.org") || t.contains("ondertiteld door")
    }
}
