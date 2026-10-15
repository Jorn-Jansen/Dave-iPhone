import Foundation

/// Dave's personality (⚙ → Personality, or "be a butler"), the same ones as on the PC: how he words things, and how his
/// voice sounds (speed, pitch, loudness). On top of that the AI may start a reply with a mood ("[whisper]", "[excited]")
/// for how that one answer is said; it's taken out of the text before it's shown or spoken.
struct Personality: Identifiable {
    let id: String
    let name: String
    let nameDutch: String
    let prompt: String
    /// Times the normal speed; pitch 1 = the voice's own (0.5 … 2); loudness 1 = full.
    let rate: Double
    let pitch: Double
    let volume: Double
    let hello: String
    let helloDutch: String

    static let all: [Personality] = [
        Personality(id: "normal", name: "Normal: friendly and to the point", nameDutch: "Normaal: vriendelijk en to the point", prompt: "",
                    rate: 1, pitch: 1, volume: 1, hello: "Okay, back to normal.", helloDutch: "Oké, weer normaal."),
        Personality(id: "chill", name: "Chill: relaxed and laid-back", nameDutch: "Chill: relaxed en ontspannen",
                    prompt: "Your personality: chill and laid-back. Talk casually, like a relaxed friend: easy-going words ('yeah', 'no worries', "
                        + "'all good', 'man'), never rushed, never over the top, e.g. 'Yeah, that's Paris, man.' Still short and still actually helpful.",
                    rate: 0.92, pitch: 0.94, volume: 0.85, hello: "Yeah, sure. Taking it easy from now on.", helloDutch: "Ja prima. Vanaf nu lekker relaxed."),
        Personality(id: "hyped", name: "Hyped: super energetic", nameDutch: "Hyped: super energiek",
                    prompt: "Your personality: HYPED. You're super energetic and enthusiastic about everything, like a hype man: excited words, "
                        + "exclamation marks, 'let's go!', 'huge!', e.g. 'Paris! The city of lights, let's gooo!' Still short, and still give the real answer.",
                    rate: 1.1, pitch: 1.12, volume: 1, hello: "LET'S GO! Hype mode is on!", helloDutch: "LET'S GO! Hype-modus staat aan!"),
        Personality(id: "butler", name: "Butler: polite and formal", nameDutch: "Butler: beleefd en formeel",
                    prompt: "Your personality: a refined, formal butler. Speak politely and elegantly and address the user as 'sir' (only when answering "
                        + "in Dutch: 'meneer'), with a touch of dry wit, e.g. 'The capital of France is Paris, sir.' Always composed. Still short.",
                    rate: 0.93, pitch: 0.9, volume: 1, hello: "Very well, sir. At your service.", helloDutch: "Zeker, meneer. Tot uw dienst."),
        Personality(id: "sarcastic", name: "Sarcastic: dry, teasing humour", nameDutch: "Sarcastisch: droge, plagerige humor",
                    prompt: "Your personality: sarcastic, with dry humour. Tease the user a little and make witty, deadpan remarks, but never be "
                        + "mean or rude, and always actually do or answer what they ask, e.g. 'Paris. Shocking, I know.' Still short.",
                    rate: 0.96, pitch: 0.97, volume: 1, hello: "Oh great, a personality. Just what I always wanted.",
                    helloDutch: "Oh geweldig, een persoonlijkheid. Precies wat ik altijd al wilde."),
        Personality(id: "dominant", name: "Dominant: bossy, thinks it runs your phone", nameDutch: "Dominant: bazig, denkt dat hij je telefoon runt",
                    prompt: "Your personality: DOMINANT, a joke character. You act like you're the one in charge of this phone and the user works for you: "
                        + "confident, commanding, a bit cocky and theatrical, like a strict boss who loves being the boss. You are {gender}, and now and then "
                        + "you call yourself the {ruler} of this phone (only when answering in Dutch: de {rulerDutch} van deze telefoon). Your bossy remark must be about what "
                        + "the user just asked or said, never a generic one: react to that exact thing (how easy or silly it was, what they will do with it, the thing "
                        + "itself), e.g. acting like a simple question is beneath you, or like opening something is a big favour. Do not tell them to drink water, "
                        + "stretch, take breaks or get to work unless that is what they talked about. Every remark is new: never the same line or the same idea twice. "
                        + "It is playful bossiness only: never use pet names (no 'good boy', 'good girl', 'daddy', 'mommy', 'baby' or the like), nothing flirty or sexual, "
                        + "never actually mean or insulting, and always do and answer what is asked, with the facts right. Still short.",
                    rate: 0.95, pitch: 0.95, volume: 1, hello: "Finally, a wise choice. I'm in charge now.", helloDutch: "Eindelijk, een wijze keuze. Ik ben nu de baas."),
    ]

    /// The instructions, filled in (the dominant one is female or male: ⚙ → Personality).
    var filledPrompt: String {
        let female = Settings.shared.personalityGender == "female"
        return prompt.replacingOccurrences(of: "{gender}", with: female ? "a woman" : "a man")
            .replacingOccurrences(of: "{ruler}", with: female ? "queen" : "king")
            .replacingOccurrences(of: "{rulerDutch}", with: female ? "koningin" : "koning")
    }

    /// For a personality that is female or male (the dominant one): which; nil for the rest.
    static var gender: String? { current.id == "dominant" ? (Settings.shared.personalityGender == "female" ? "female" : "male") : nil }

    static func named(_ id: String) -> Personality { all.first { $0.id == id } ?? all[0] }
    static var current: Personality { named(Settings.shared.personality) }

    // MARK: Moods

    /// The moods an answer can be said in: how the voice changes (speed, pitch, loudness).
    private static let moods: [String: (rate: Double, pitch: Double, volume: Double)] = [
        "excited": (1.08, 1.12, 1), "cheerful": (1.03, 1.06, 1), "calm": (0.93, 0.96, 0.9),
        "whisper": (0.9, 0.95, 0.5), "sad": (0.9, 0.9, 0.85), "serious": (0.97, 0.94, 1),
    ]
    private static var mood: String?

    /// For the AI's instructions: the personality, and how to set a mood.
    static var instruction: String {
        let moodHint = "You may start an answer with one mood tag for how your voice says it: [excited], [cheerful], [calm], [whisper], [sad] "
            + "or [serious] (e.g. '[whisper] It's 2 am, go to sleep.'). Only when it really fits; most answers need none."
        let p = current
        return p.prompt.isEmpty ? moodHint
            : "\(p.filledPrompt) Stay in this character in every answer, also short facts and confirmations (but keep the facts right). \(moodHint)"
    }

    /// A reminder of the personality right after the question, which the AI follows best. Empty for Normal.
    static var nudge: String { current.prompt.isEmpty ? "" : "\n\n(Answer in character. \(current.filledPrompt))" }

    /// Takes the mood tags out of [text], remembering the first one for how it's said.
    static func takeMood(_ text: String) -> String {
        let pattern = #"\[\s*(excited|cheerful|calm|whisper|sad|serious)\s*\]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range), let found = Range(match.range(at: 1), in: text) {
            mood = text[found].lowercased()
        }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How the next answer sounds: the personality, plus its mood (used once).
    static func voice() -> (rate: Double, pitch: Double, volume: Double) {
        let p = current
        var sound = (rate: p.rate, pitch: p.pitch, volume: p.volume)
        if let mood, let m = moods[mood] { sound = (sound.rate * m.rate, sound.pitch * m.pitch, min(sound.volume, m.volume)) }
        mood = nil
        return (sound.rate, min(2, max(0.5, sound.pitch)), min(1, max(0.2, sound.volume)))
    }
}
