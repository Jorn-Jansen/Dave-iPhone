import Foundation
import UIKit

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
        var images: [UIImage] = [] // photos Dave found or looked at
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
            let tools = PhoneTools.definitions + (settings.hasPC ? [pcControlTool, pcTool] : [])
            let message = try await Groq.chat(messages: messages, tools: tools, settings: settings)
            if let calls = message["tool_calls"] as? [[String: Any]], let call = calls.first,
               let function = call["function"] as? [String: Any], let name = function["name"] as? String {
                let argumentText = function["arguments"] as? String ?? "{}"
                let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentText.utf8)) as? [String: Any]) ?? [:]
                let id = call["id"] as? String ?? UUID().uuidString
                let (reply, images) = try await run(name, arguments, question: text, language: language)
                if Task.isCancelled { stopped(); return }
                remember(text, toolCall: (id, name, argumentText), result: reply.isEmpty ? "Done." : reply)
                if reply.isEmpty { // an app opened: nothing to say
                    add(Line(fromUser: false, text: "↗ " + (arguments["app"] as? String ?? arguments["name"] as? String ?? "")))
                    state = .idle
                } else {
                    await answer(reply, language: language, viaPC: name == "pc", images: images)
                }
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

    /// Carry out one of Dave's commands; returns what to say (empty: nothing, e.g. an app opened) and pictures to show.
    private func run(_ name: String, _ args: [String: Any], question: String, language: String) async throws -> (String, [UIImage]) {
        switch name {
        case "pc":
            do {
                let reply = try await PCLink.ask(args["request"] as? String ?? question, settings: settings)
                settings.pcLinked = true
                return (reply, [])
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                settings.pcLinked = false
                return (error.localizedDescription, [])
            }

        case "pc_control":
            // The command is chosen here: the PC carries it out without asking its own AI (faster, half the AI use)
            var pcArgs = args
            let command = pcArgs.removeValue(forKey: "command") as? String ?? ""
            do {
                let reply = try await PCLink.command(command, args: pcArgs, settings: settings)
                settings.pcLinked = true
                return (reply, [])
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                settings.pcLinked = false
                return (error.localizedDescription, [])
            }

        case "music": return (try await PhoneTools.music(args, settings: settings), [])
        case "open_app": return (await PhoneTools.openApp(args, settings: settings), [])
        case "run_shortcut": return (await PhoneTools.runShortcut(args, settings: settings), [])

        case "use_clipboard":
            let task = args["task"] as? String ?? question
            let copied = PhoneTools.clipboard()
            if let image = copied.image {
                return (try await Groq.look(at: [image], question: task, what: "a picture the user copied", language: language, settings: settings), [image])
            }
            if let text = copied.text {
                return (try await Groq.work(on: text, task: task, what: "text the user copied", language: language, settings: settings), [])
            }
            return (settings.say("Nothing is copied right now. (If iOS asked to allow pasting: tap Allow, or set Dave to always allow it in iOS' settings.)",
                                 "Er is nu niets gekopieerd. (Vroeg iOS om plakken toe te staan: tik Sta toe, of zet het voor Dave altijd aan in de iOS-instellingen.)"), [])

        case "photos":
            let look = (args["action"] as? String) == "look"
            let count = max(1, min(look ? 4 : 12, args["count"] as? Int ?? (look ? 1 : 12)))
            guard let found = await PhoneTools.findPhotos(args, count: count, size: look ? 1600 : 400) else {
                return (settings.say("I'm not allowed to see your photos. Turn it on in iOS' settings → Dave → Photos.",
                                     "Ik mag je foto's niet zien. Zet het aan in de iOS-instellingen → Dave → Foto's."), [])
            }
            if found.images.isEmpty { return (settings.say("I didn't find any photos like that.", "Ik vond geen foto's zoals dat."), []) }
            if look {
                let what = found.images.count == 1 ? "a photo from the user's library, taken \(when(found.dates[0]))"
                                                   : "the user's \(found.images.count) newest matching photos, newest first"
                return (try await Groq.look(at: found.images, question: args["question"] as? String ?? question, what: what, language: language, settings: settings),
                        found.images)
            }
            let newest = when(found.dates[0])
            return (settings.say("I found \(found.total) \(found.total == 1 ? "photo" : "photos"); the newest is from \(newest).",
                                 "Ik vond \(found.total) \(found.total == 1 ? "foto" : "foto's"); de nieuwste is van \(newest)."), found.images)

        case "read_file":
            guard let url = await pickFile() else { return (settings.say("Okay, no file then.", "Oké, dan geen bestand."), []) }
            let content = PhoneTools.read(url)
            let task = args["question"] as? String ?? question
            if let image = content.image {
                return (try await Groq.look(at: [image], question: task, what: "the picture \(url.lastPathComponent)", language: language, settings: settings), [image])
            }
            if let text = content.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (try await Groq.work(on: text, task: task, what: "the file \(url.lastPathComponent)" + (content.cut ? " (only the first part: it's long)" : ""),
                                            language: language, settings: settings), [])
            }
            return (settings.say("I can't read \(url.lastPathComponent).", "Ik kan \(url.lastPathComponent) niet lezen."), [])

        default:
            return (settings.say("I can't do that here.", "Dat kan ik hier niet."), [])
        }
    }

    /// "today at 14:05", "yesterday at 9:12", "3 October"
    private func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: settings.isDutch ? "nl_NL" : "en_GB")
        f.dateFormat = "HH:mm"
        if Calendar.current.isDateInToday(date) { return settings.say("today at ", "vandaag om ") + f.string(from: date) }
        if Calendar.current.isDateInYesterday(date) { return settings.say("yesterday at ", "gisteren om ") + f.string(from: date) }
        f.dateFormat = "d MMMM"
        return f.string(from: date)
    }

    // MARK: Picking a file

    /// Shows the file picker (ContentView watches this); the pick (or nil for cancel) comes back through filePicked.
    @Published var pickingFile = false
    private var pickedFile: CheckedContinuation<URL?, Never>?

    private func pickFile() async -> URL? {
        await withCheckedContinuation { done in
            pickedFile = done
            pickingFile = true
        }
    }

    func filePicked(_ url: URL?) {
        let done = pickedFile
        pickedFile = nil
        done?.resume(returning: url)
    }

    private func answer(_ text: String, language: String, viaPC: Bool = false, images: [UIImage] = []) async {
        add(Line(fromUser: false, text: text, viaPC: viaPC, images: images))
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

    /// PC commands the phone chooses itself (the PC then doesn't need its own AI): the names and arguments Dave on the PC uses.
    private var pcControlTool: [String: Any] {
        let bool: [String: Any] = ["type": "boolean"]
        return [
            "type": "function",
            "function": [
                "name": "pc_control",
                "description": "Control the user's Windows PC directly (fast): its music like the media keys, its volume (the whole PC or one app), "
                    + "shuffle or repeat, locking it, opening or closing a program, opening a website, quiet mode. "
                    + "For anything else on the PC (questions, its screen, files, reminders, notifications), use pc.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "enum": ["media_control", "set_volume", "music_settings", "lock_pc", "open_app", "close_app", "open_website", "quiet_mode"]],
                        "action": ["type": "string", "enum": ["play", "pause", "next", "previous"], "description": "media_control"],
                        "app": ["type": "string", "description": "set_volume: one app, e.g. 'Discord'; empty for the whole PC"],
                        "change": ["type": "string", "enum": ["up", "down"], "description": "set_volume: louder or quieter"],
                        "level": ["type": "integer", "description": "set_volume: 0-100"],
                        "mute": bool,
                        "name": ["type": "string", "description": "open_app / close_app: the program, e.g. 'Roblox'"],
                        "url": ["type": "string", "description": "open_website: the address"],
                        "search": ["type": "string", "description": "open_website: search words"],
                        "on": bool,
                        "minutes": ["type": "integer", "description": "quiet_mode: how long; 0 = until turned off"],
                        "shuffle": bool,
                        "repeat": ["type": "string", "enum": ["track", "context", "off"]],
                    ],
                    "required": ["command"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

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
        prompt += "\nOn this iPhone you can open apps (and search in them), run the user's Shortcuts, work with what they copied, look at their photos, "
            + "and read a file they pick. Use the matching command instead of saying you can't."
        if settings.hasPC {
            prompt += "\nYou also run on the user's Windows PC. For things on that PC (\"on my PC\", \"on my computer\"): pc_control for its music buttons, "
                + "volume, locking it, opening or closing programs and websites; the pc tool for everything else there (questions, its screen, files, reminders). "
                + "Apps and photos without \"PC\" mean this iPhone. Music without \"PC\": the music command."
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

    private func remember(_ question: String, toolCall: (id: String, name: String, arguments: String), result: String) {
        history.append(["role": "user", "content": question])
        history.append(["role": "assistant", "tool_calls": [["id": toolCall.id, "type": "function", "function": ["name": toolCall.name, "arguments": toolCall.arguments]]]])
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
