import Foundation

/// Dave on the phone: listens, thinks (Groq, with web search), talks, and hands things that belong on the PC to
/// Dave on the PC ("pause the music on my PC", "lock my PC", "what's on my screen?").
@MainActor
final class Brain: ObservableObject {
    enum State { case idle, listening, thinking, speaking }

    struct Line: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
        var viaPC = false
    }

    @Published var lines: [Line] = []
    @Published var state: State = .idle
    @Published var level: Float = 0

    let settings = Settings.shared
    private let voice = Voice()
    private var history: [[String: Any]] = [] // short-term memory, so follow-ups work; forgotten after 10 quiet minutes
    private var lastActivity = Date.distantPast
    private var work: Task<Void, Never>? // what Dave is doing now (listening, thinking): tapping the orb can cancel it

    // MARK: Listening

    /// The big button: listen, stop listening, stop thinking, or stop talking.
    func micTapped() {
        switch state {
        case .idle: work = Task { await listen() }
        case .listening: stopRequested = true // the listening loop stops the recording and sends it
        case .speaking: voice.stopSpeaking()
        case .thinking: work?.cancel()
        }
    }

    /// A typed question.
    func submit(_ text: String) {
        guard state == .idle || state == .speaking else { return }
        voice.stopSpeaking()
        work = Task { await ask(text) }
    }

    /// Cancelled (tapped the orb while thinking): back to waiting, without an error.
    private func stopped() {
        add(Line(fromUser: false, text: settings.say("⏹ Stopped.", "⏹ Gestopt.")))
        state = .idle
    }

    private var stopRequested = false

    private func listen() async {
        guard await voice.allowMicrophone() else {
            add(Line(fromUser: false, text: settings.say("I'm not allowed to use the microphone. Turn it on in iOS' settings → Dave.",
                                                          "Ik mag de microfoon niet gebruiken. Zet hem aan in de iOS-instellingen → Dave.")))
            return
        }
        do { try voice.startRecording() } catch {
            add(Line(fromUser: false, text: settings.say("The microphone didn't start.", "De microfoon startte niet.")))
            return
        }
        state = .listening
        stopRequested = false
        // Stop by itself once you've said something and then are quiet for a moment (or after 20 seconds)
        let started = Date()
        var heardSomething = false
        var lastLoud = Date()
        while !stopRequested {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = Date()
            level = voice.level
            if level > 0.22 { heardSomething = true; lastLoud = now }
            if heardSomething && now.timeIntervalSince(lastLoud) > 1.3 { break }
            if !heardSomething && now.timeIntervalSince(started) > 7 { break }
            if now.timeIntervalSince(started) > 20 { break }
        }
        level = 0
        guard let recording = finishListening() else { state = .idle; return }
        state = .thinking
        do {
            let (text, language) = try await Groq.transcribe(recording, settings: settings)
            guard !text.isEmpty else {
                state = .idle
                return
            }
            await ask(text, language: languageTag(whisper: language))
        } catch {
            if Task.isCancelled { stopped(); return }
            await answer(error.localizedDescription, language: settings.language)
        }
    }

    @discardableResult
    private func finishListening() -> URL? {
        stopRequested = true
        return voice.stopRecording()
    }

    /// Whisper says "dutch" or "english" (or "nl"/"en"); anything else: the main language.
    private func languageTag(whisper: String) -> String {
        let l = whisper.lowercased()
        if l.hasPrefix("nl") || l.hasPrefix("dutch") { return "nl-NL" }
        if l.hasPrefix("en") { return "en-US" }
        return settings.language
    }

    // MARK: Thinking

    /// A typed or spoken question.
    func ask(_ text: String, language: String? = nil) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { state = .idle; return } // (busy is checked by the callers: listen() is already "thinking" here)
        let language = language ?? settings.language
        add(Line(fromUser: true, text: text))
        state = .thinking
        if Date().timeIntervalSince(lastActivity) > 600 { history.removeAll() }
        lastActivity = Date()

        let context = "[It's \(now()). Answer in \(language.hasPrefix("nl") ? "Dutch" : "English").]"
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt()]]
        messages += history
        messages.append(["role": "user", "content": "\(context)\n\n\(text)"])

        do {
            let message = try await Groq.chat(messages: messages, tools: settings.hasPC ? [pcTool] : [], settings: settings)
            if let calls = message["tool_calls"] as? [[String: Any]], let call = calls.first,
               let function = call["function"] as? [String: Any], function["name"] as? String == "pc" {
                let arguments = (function["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let request = arguments?["request"] as? String ?? text
                let id = call["id"] as? String ?? UUID().uuidString
                let reply: String
                do {
                    reply = try await PCLink.ask(request, settings: settings)
                    settings.pcLinked = true
                } catch {
                    if Task.isCancelled || error is CancellationError { stopped(); return }
                    reply = error.localizedDescription
                    settings.pcLinked = false
                }
                remember(text, toolCall: (id, request), result: reply)
                await answer(reply, language: language, viaPC: true)
            } else {
                let reply = speakable(message["content"] as? String ?? "")
                let said = reply.isEmpty ? settings.say("Sorry, I didn't get an answer for that.", "Sorry, daar kreeg ik geen antwoord op.") : reply
                remember(text, answer: said)
                await answer(said, language: language)
            }
        } catch {
            if Task.isCancelled { stopped(); return }
            await answer(error.localizedDescription, language: language)
        }
    }

    private func answer(_ text: String, language: String, viaPC: Bool = false) async {
        add(Line(fromUser: false, text: text, viaPC: viaPC))
        state = .speaking
        await voice.speak(text, language: language, rate: settings.speechRate)
        state = .idle
        // Dave asked something back: listen for the answer without another tap
        if text.trimmingCharacters(in: .whitespaces).hasSuffix("?") && !viaPC {
            work = Task { await listen() }
        }
    }

    private func add(_ line: Line) { lines.append(line) }

    // MARK: The AI's instructions and memory

    private var pcTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "pc",
                "description": "Ask Dave on the user's Windows PC to do or find out something there: its music or Spotify, volume, "
                    + "opening or closing programs and websites, locking it, files, what's on its screen, timers and reminders on the PC, "
                    + "its notifications and messages, screen time, how the PC is doing, the page open in its browser, game help.",
                "parameters": [
                    "type": "object",
                    "properties": ["request": ["type": "string", "description": "The request as the user would say it to Dave on the PC, e.g. 'pause the music'"]],
                    "required": ["request"],
                ],
            ],
        ]
    }

    private func systemPrompt() -> String {
        var prompt = """
        You are \(settings.displayName), a voice assistant in an app on the user's iPhone. Everything you say is read aloud, so:
        answer in one to three short spoken sentences unless they ask for more; plain speech only: no markdown, lists, emojis, links or symbols;
        say numbers, times and units the way a person says them. Use web search for anything current: news, weather, scores, prices, opening hours.
        The user's country: \(settings.country); use its units and currency.
        Only end with a question when you really need an answer; never add filler questions like "Anything else?".
        """
        if settings.hasPC {
            prompt += "\nYou also run on the user's Windows PC. For anything that has to happen on or be known from that PC, use the pc tool."
        }
        if !settings.memories.isEmpty {
            prompt += "\nThings the user asked you to remember:\n" + settings.memories.map { "- " + $0 }.joined(separator: "\n")
        }
        return prompt
    }

    private func remember(_ question: String, answer: String) {
        history.append(["role": "user", "content": question])
        history.append(["role": "assistant", "content": answer])
        trimHistory()
    }

    private func remember(_ question: String, toolCall: (id: String, request: String), result: String) {
        let arguments = (try? JSONSerialization.data(withJSONObject: ["request": toolCall.request])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        history.append(["role": "user", "content": question])
        history.append(["role": "assistant", "tool_calls": [["id": toolCall.id, "type": "function", "function": ["name": "pc", "arguments": arguments]]]])
        history.append(["role": "tool", "tool_call_id": toolCall.id, "content": result])
        trimHistory()
    }

    private func trimHistory() {
        // About the last 8 exchanges; never start with a tool result (its call would be missing)
        while history.count > 24 || (history.first?["role"] as? String).map({ $0 != "user" }) == true { history.removeFirst() }
    }

    private func now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return formatter.string(from: Date())
    }

    /// No markdown or links read aloud.
    private func speakable(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression) // [text](link) → text
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#`>]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression) // search citations
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
