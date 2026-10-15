import AVFoundation

/// The microphone (recording what you say, and how loud) and Dave's voice (iOS' own voices, the best one installed).
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    private var recorder: AVAudioRecorder?
    private let synthesizer = AVSpeechSynthesizer()
    private var finishedSpeaking: CheckedContinuation<Void, Never>?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("speech.m4a")

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func allowMicrophone() async -> Bool {
        await withCheckedContinuation { done in
            AVAudioSession.sharedInstance().requestRecordPermission { done.resume(returning: $0) }
        }
    }

    private func prepareAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    func startRecording() throws {
        try prepareAudio()
        let format: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        try? FileManager.default.removeItem(at: file)
        let recorder = try AVAudioRecorder(url: file, settings: format)
        recorder.isMeteringEnabled = true
        recorder.record()
        self.recorder = recorder
    }

    /// How loud it is right now, 0 (silence) … 1 (shouting).
    var level: Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0) // -160 … 0 dB
        return max(0, min(1, (power + 50) / 45))
    }

    /// Stop; returns the recording, or nil if there was none.
    func stopRecording() -> URL? {
        guard let recorder else { return nil }
        let length = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        return length > 0.3 ? file : nil
    }

    /// Say [text] in [language] ("nl-NL", "en-US"…), at [rate] with [pitch] (1 = the voice's own) and [volume] (the
    /// personality and mood); returns when done (or stopped).
    func speak(_ text: String, language: String, rate: Double, pitch: Double = 1, volume: Double = 1) async {
        stopSpeaking()
        try? prepareAudio()
        let spoken = String(String.UnicodeScalarView(Self.withoutLinks(text).unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) && $0.value != 0xFE0F && $0.value != 0x200D }))
        let utterance = AVSpeechUtterance(string: spoken) // no web addresses (their short name instead) and no emoji ("🚀" would be said as "rocket")
        utterance.voice = bestVoice(for: language)
        utterance.rate = Float(min(Double(AVSpeechUtteranceMaximumSpeechRate), max(Double(AVSpeechUtteranceMinimumSpeechRate), rate)))
        utterance.pitchMultiplier = Float(pitch)
        utterance.volume = Float(volume)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            finishedSpeaking = done
            synthesizer.speak(utterance)
        }
    }

    /// Web addresses replaced by what they are, said short: a page's own name when the address has one
    /// (roblox.com/games/107778070777162/Steal-An-Egg → "Steal An Egg"), otherwise the site ("Roblox").
    static func withoutLinks(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        var result = text
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let url = match.url, url.scheme?.hasPrefix("http") == true, let range = Range(match.range, in: result) else { continue }
            let name = url.pathComponents.compactMap { $0.removingPercentEncoding }.last { part in
                part.count > 3 && part.count < 80 && part.range(of: #"^[\p{L}\d]+([-_+][\p{L}\d]+)+$"#, options: .regularExpression) != nil && part.contains { $0.isLetter }
            }
            var spoken: String
            if let name { spoken = name.replacingOccurrences(of: #"[-_+]"#, with: " ", options: .regularExpression) }
            else {
                var host = url.host ?? ""
                if host.hasPrefix("www.") { host.removeFirst(4) }
                let parts = host.split(separator: ".")
                spoken = parts.count >= 2 ? String(parts[parts.count - 2]) : host
                spoken = spoken.prefix(1).uppercased() + spoken.dropFirst()
            }
            result.replaceSubrange(range, with: spoken)
        }
        return result
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish()
    }

    /// The most natural installed voice for the language (Premium or Enhanced ones when you've downloaded them in iOS' settings).
    private func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        var voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        // A female or male personality (the dominant one): a voice of that gender, if there is one
        if let gender = Personality.gender {
            let matching = voices.filter { $0.gender == (gender == "female" ? .female : .male) }
            if !matching.isEmpty { voices = matching }
        }
        return voices.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            return (a.language == language ? 1 : 0) < (b.language == language ? 1 : 0)
        } ?? AVSpeechSynthesisVoice(language: language)
    }

    private func finish() {
        let done = finishedSpeaking
        finishedSpeaking = nil
        done?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }
}
