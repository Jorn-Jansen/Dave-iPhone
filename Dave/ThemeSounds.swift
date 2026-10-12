import AVFoundation
import Foundation

/// Short, soft sounds in the theme's style, the same as on the PC: when Dave starts listening, when he heard you, and when
/// he's done. A shimmering chime (Aurora), a crackle of fire (Ember), bubbles popping (Toxic), water drops (Ocean),
/// plucked strings (Sakura), crystal bells (Midnight). Made from scratch the first time they're needed (no sound files).
/// Off in the settings, and in the Legacy theme.
enum ThemeSounds {
    enum Cue { case listen, heard, done }

    private static let rate = 44100.0
    private static var made: [String: Data] = [:]
    private static var player: AVAudioPlayer?
    private static var noise = SystemRandomNumberGenerator()

    /// Plays the sound for [cue]; returns how long it takes (so listening can start once it's over).
    @discardableResult
    static func play(_ cue: Cue) -> TimeInterval {
        let theme = Theme.current.id
        guard Settings.shared.themeSounds, theme != "legacy" else { return 0 }
        let key = "\(theme)-\(cue)"
        let wav = made[key] ?? {
            let data = Self.wav(make(theme, cue))
            made[key] = data
            return data
        }()
        player = try? AVAudioPlayer(data: wav)
        player?.volume = 0.8
        player?.play()
        return player?.duration ?? 0
    }

    // MARK: Making the sounds

    private static func make(_ theme: String, _ cue: Cue) -> [Float] {
        var mix = [Float](repeating: 0, count: Int(rate * 0.9))
        let up = cue != .heard // rising when he starts, falling when he's heard you
        switch theme {
        case "ember":
            crackle(&mix, at: 0, length: cue == .done ? 0.12 : 0.2, pops: 9)
            if cue != .done { glide(&mix, at: 0.01, from: up ? 300 : 420, to: up ? 420 : 300, length: 0.2, volume: 0.16, harmonics: 0.35) }
        case "toxic":
            let pops: [(Double, Double, Double)] = cue == .listen ? [(0, 220, 620), (0.08, 300, 820)] : cue == .heard ? [(0, 760, 260)] : [(0, 280, 760)]
            for (at, from, to) in pops { glide(&mix, at: at, from: from, to: to, length: 0.07, volume: 0.3, harmonics: 0.25, curve: 3) }
        case "ocean":
            let drops: [(Double, Double)] = cue == .listen ? [(0, 1), (0.09, 1.35)] : cue == .heard ? [(0, 1.3), (0.09, 0.95)] : [(0, 1.2)]
            for (at, scale) in drops {
                glide(&mix, at: at, from: (up ? 420 : 1250) * scale, to: (up ? 1250 : 420) * scale, length: 0.09, volume: 0.32, curve: 2.2)
            }
        case "sakura":
            for (at, note) in notes(cue, [587.3, 740.0, 880.0], gap: 0.07) { pluck(&mix, at: at, f: note, volume: 0.32, length: cue == .listen ? 0.24 : 0.45) }
        case "midnight":
            for (at, note) in notes(cue, [1568.0, 2093.0, 2637.0], gap: 0.07) { bell(&mix, at: at, f: note, length: cue == .listen ? 0.22 : 0.55, volume: 0.17) }
        default: // Aurora
            for (at, note) in notes(cue, [659.3, 987.8, 1318.5], gap: 0.06) { chime(&mix, at: at, f: note, length: cue == .listen ? 0.2 : 0.45, volume: 0.2) }
        }
        return trim(mix)
    }

    /// Which notes when: two rising (listen), two falling (heard), one (done).
    private static func notes(_ cue: Cue, _ scale: [Double], gap: Double) -> [(Double, Double)] {
        switch cue {
        case .listen: return [(0, scale[0]), (gap, scale[1])]
        case .heard: return [(0, scale[1]), (gap, scale[0])]
        case .done: return [(0, scale[1])]
        }
    }

    private static func glide(_ mix: inout [Float], at: Double, from: Double, to: Double, length: Double, volume: Double, harmonics: Double = 0, curve: Double = 1) {
        let start = Int(at * rate), n = Int(length * rate)
        var phase = 0.0
        for i in 0..<n where start + i < mix.count {
            let x = Double(i) / Double(n), f = from + (to - from) * (1 - pow(1 - x, curve))
            phase += 2 * .pi * f / rate
            let envelope = min(1, Double(i) / (0.004 * rate)) * pow(1 - x, 2)
            mix[start + i] += Float(volume * envelope * (sin(phase) + harmonics * sin(3 * phase)))
        }
    }

    private static func chime(_ mix: inout [Float], at: Double, f: Double, length: Double, volume: Double) {
        let start = Int(at * rate), n = Int(length * rate)
        for i in 0..<n where start + i < mix.count {
            let t = Double(i) / rate, shimmer = 1 + 0.004 * sin(2 * .pi * 5 * t)
            let envelope = min(1, Double(i) / (0.006 * rate)) * exp(-t * 5.5 / length)
            mix[start + i] += Float(volume * envelope * (sin(2 * .pi * f * shimmer * t) + 0.3 * sin(2 * .pi * 2 * f * t)))
        }
    }

    private static func bell(_ mix: inout [Float], at: Double, f: Double, length: Double, volume: Double) {
        let start = Int(at * rate), n = Int(length * rate)
        let partials: [(Double, Double, Double)] = [(1, 1, 1), (2.76, 0.45, 1.8), (5.4, 0.22, 3.2)]
        for i in 0..<n where start + i < mix.count {
            let t = Double(i) / rate
            var value = 0.0
            for (ratio, gain, speed) in partials { value += gain * exp(-t * 4 * speed / length) * sin(2 * .pi * f * ratio * t) }
            mix[start + i] += Float(volume * min(1, Double(i) / (0.002 * rate)) * value)
        }
    }

    private static func pluck(_ mix: inout [Float], at: Double, f: Double, volume: Double, length: Double) {
        let start = Int(at * rate), period = max(2, Int(rate / f)), n = Int(length * rate)
        var ring = (0..<period).map { _ in Double.random(in: -1...1, using: &noise) }
        for i in 0..<n where start + i < mix.count {
            let k = i % period, next = (k + 1) % period
            let sample = ring[k]
            ring[k] = 0.996 * 0.5 * (ring[k] + ring[next])
            mix[start + i] += Float(volume * sample * exp(-Double(i) / (0.25 * rate)) * min(1, Double(n - i) / (0.03 * rate)))
        }
    }

    private static func crackle(_ mix: inout [Float], at: Double, length: Double, pops: Int) {
        for _ in 0..<pops {
            let start = Int((at + Double.random(in: 0...1, using: &noise) * length) * rate)
            let n = Int(rate * (0.002 + Double.random(in: 0...1, using: &noise) * 0.006))
            let loud = 0.15 + Double.random(in: 0...1, using: &noise) * 0.3
            var last = 0.0
            for i in 0..<n where start + i < mix.count {
                last = 0.55 * last + 0.45 * Double.random(in: -1...1, using: &noise)
                mix[start + i] += Float(loud * last * (1 - Double(i) / Double(n)))
            }
        }
    }

    /// Cuts off the silence at the end, and keeps it from getting too loud.
    private static func trim(_ mix: [Float]) -> [Float] {
        var end = mix.count
        while end > 0 && abs(mix[end - 1]) < 0.0005 { end -= 1 }
        let peak = mix[..<end].map { abs($0) }.max() ?? 0
        let scale: Float = peak > 0.42 ? 0.42 / peak : 1
        return mix[..<max(1, end)].map { $0 * scale }
    }

    /// The samples as a WAV file (16-bit mono), for AVAudioPlayer.
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func add<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); add(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); add(UInt32(16)); add(UInt16(1)); add(UInt16(1))
        add(UInt32(rate)); add(UInt32(rate * 2)); add(UInt16(2)); add(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); add(UInt32(bytes))
        for s in samples { add(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}
