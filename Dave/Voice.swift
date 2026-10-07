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

    /// Say [text] in [language] ("nl-NL", "en-US"…); returns when done (or stopped).
    func speak(_ text: String, language: String, rate: Double) async {
        stopSpeaking()
        try? prepareAudio()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(for: language)
        utterance.rate = Float(rate)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            finishedSpeaking = done
            synthesizer.speak(utterance)
        }
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish()
    }

    /// The most natural installed voice for the language (Premium or Enhanced ones when you've downloaded them in iOS' settings).
    private func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
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
