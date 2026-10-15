import SwiftUI

/// The stopwatch on the iPhone, like on the PC: "start a stopwatch", "lap", "how long has it been?", "pause", "carry on",
/// "stop". Kept, so it keeps counting when the app is closed; shown as a card at the top of the chat while it's on.
@MainActor
final class PhoneStopwatch: ObservableObject {
    static let shared = PhoneStopwatch()

    private struct State: Codable {
        var on = false
        var runningSince: Date?
        var banked: Double = 0
        var laps: [Double] = []
    }

    @Published private var state = State() { didSet { save() } }
    /// The last stop, shown for a moment after stopping.
    @Published private(set) var stoppedAt: (time: TimeInterval, when: Date)?

    var on: Bool { state.on }
    var running: Bool { state.on && state.runningSince != nil }
    var laps: [Double] { state.laps }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        state.banked + (state.runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "stopwatch"), let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: "stopwatch") }
    }

    /// Does what was asked; returns what to say.
    func run(_ action: String, settings: Settings) -> String {
        let s = settings
        switch action {
        case "start" where running:
            return s.say("It's already running: \(Self.spoken(elapsed(), s)).", "Hij loopt al: \(Self.spoken(elapsed(), s)).")
        case "start", "reset":
            let keepGoing = action == "start" || running || !state.on
            stoppedAt = nil
            state = State(on: true, runningSince: keepGoing ? Date() : nil)
            return action == "start" ? s.say("⏱ Stopwatch started.", "⏱ Stopwatch gestart.") : s.say("⏱ Back to zero.", "⏱ Terug naar nul.")
        case _ where !state.on:
            return s.say("There's no stopwatch running. Say \"start a stopwatch\".", "Er loopt geen stopwatch. Zeg \"start een stopwatch\".")
        case "lap":
            let total = elapsed(), lap = total - (state.laps.last ?? 0)
            state.laps.append(total)
            return s.say("Lap \(state.laps.count): \(Self.short(lap))", "Ronde \(state.laps.count): \(Self.short(lap))")
                + (state.laps.count > 1 ? s.say(" (total \(Self.short(total)))", " (totaal \(Self.short(total)))") : "")
        case "pause":
            guard running else { return s.say("It's already paused at \(Self.short(elapsed())).", "Hij staat al op pauze op \(Self.short(elapsed())).") }
            state.banked = elapsed()
            state.runningSince = nil
            return s.say("⏸ Paused at \(Self.short(elapsed())).", "⏸ Gepauzeerd op \(Self.short(elapsed())).")
        case "resume":
            guard !running else { return s.say("It's still running.", "Hij loopt nog.") }
            state.runningSince = Date()
            return s.say("▶ Going again from \(Self.short(elapsed())).", "▶ Hij loopt weer, vanaf \(Self.short(elapsed())).")
        case "stop":
            let end = elapsed()
            let laps = state.laps.enumerated().map { i, t in Self.short(t - (i > 0 ? state.laps[i - 1] : 0)) }.prefix(10)
            state = State()
            stoppedAt = (end, Date())
            Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !state.on { stoppedAt = nil } } // the card shows the end time, then goes
            return s.say("⏹ Stopped at \(Self.short(end))", "⏹ Gestopt op \(Self.short(end))")
                + (laps.isEmpty ? "" : s.say(", laps: ", ", rondes: ") + laps.joined(separator: ", ")) + "."
        default: // "check"
            return "⏱ " + Self.spoken(elapsed(), s) + (running ? "" : s.say(" (paused)", " (gepauzeerd)"))
                + (state.laps.isEmpty ? "" : s.say(", \(state.laps.count) lap\(state.laps.count == 1 ? "" : "s")", ", \(state.laps.count) ronde\(state.laps.count == 1 ? "" : "s")")) + "."
        }
    }

    /// "0:41.3", "12:03.0", "1:05:12".
    static func short(_ t: TimeInterval) -> String {
        let t = max(0, t), whole = Int(t)
        if whole >= 3600 { return "\(whole / 3600):" + String(format: "%02d:%02d", whole / 60 % 60, whole % 60) }
        return "\(whole / 60):" + String(format: "%02d.%d", whole % 60, Int((t - Double(whole)) * 10))
    }

    /// "1 minute and 23 seconds".
    private static func spoken(_ t: TimeInterval, _ s: Settings) -> String {
        let whole = Int(t)
        var parts: [String] = []
        func part(_ n: Int, _ one: String, _ many: String, _ een: String, _ veel: String) { if n > 0 { parts.append("\(n) " + (n == 1 ? s.say(one, een) : s.say(many, veel))) } }
        part(whole / 3600, "hour", "hours", "uur", "uur")
        part(whole / 60 % 60, "minute", "minutes", "minuut", "minuten")
        part(whole % 60, "second", "seconds", "seconde", "seconden")
        if parts.isEmpty { return s.say("less than a second", "minder dan een seconde") }
        return parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + s.say(" and ", " en ") + parts.last!
    }
}

/// The stopwatch's card at the top of the chat: the time counting up, a ring going round once a minute, the last lap,
/// and buttons to lap, pause / carry on, and stop.
struct StopwatchCard: View {
    @ObservedObject private var watch = PhoneStopwatch.shared
    private let settings = Settings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let stopped = !watch.on
            let time = stopped ? (watch.stoppedAt?.time ?? 0) : watch.elapsed(at: timeline.date)
            let paused = watch.on && !watch.running
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 4)
                    Circle().trim(from: 0, to: stopped ? 1 : time.truncatingRemainder(dividingBy: 60) / 60)
                        .stroke(LinearGradient(colors: [.daveCyan, .davePurple], startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: stopped ? "stop.fill" : paused ? "pause.fill" : "stopwatch").font(.caption)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PhoneStopwatch.short(time)).font(.title3.monospacedDigit().weight(.semibold)).opacity(paused ? 0.6 : 1)
                    Text(label(stopped: stopped, paused: paused)).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer()
                if !stopped {
                    button(paused ? "play.fill" : "flag.fill") { _ = watch.run(paused ? "resume" : "lap", settings: settings) }
                    if !paused { button("pause.fill") { _ = watch.run("pause", settings: settings) } }
                    button("stop.fill") { _ = watch.run("stop", settings: settings) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.davePurple.opacity(0.5), lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private func label(stopped: Bool, paused: Bool) -> String {
        var text = stopped ? settings.say("Stopwatch · stopped", "Stopwatch · gestopt")
            : paused ? settings.say("Stopwatch · paused", "Stopwatch · gepauzeerd") : "Stopwatch"
        if let last = watch.laps.last {
            let lap = last - (watch.laps.count > 1 ? watch.laps[watch.laps.count - 2] : 0)
            text += settings.say(" · lap \(watch.laps.count): ", " · ronde \(watch.laps.count): ") + PhoneStopwatch.short(lap)
        }
        return text
    }

    private func button(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.footnote).foregroundStyle(.white).frame(width: 32, height: 32).background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
