import SwiftUI

struct ContentView: View {
    @StateObject private var brain = Brain()
    @ObservedObject private var settings = Settings.shared
    @State private var typed = ""
    @State private var showSettings = false
    @FocusState private var typing: Bool

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                header
                chat
                controls
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { if settings.groqKey.isEmpty { showSettings = true } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Orb(state: .idle, level: 0).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.displayName).font(.title3.bold())
                Text(status).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
                    .padding(10).background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
    }

    private var status: String {
        switch brain.state {
        case .listening: return settings.say("Listening…", "Ik luister…")
        case .thinking: return settings.say("Thinking…", "Even denken…")
        case .speaking: return settings.say("Talking", "Aan het praten")
        case .idle:
            if !settings.hasPC { return settings.say("On your iPhone", "Op je iPhone") }
            return settings.pcLinked ? settings.say("💻 Linked to your PC", "💻 Gekoppeld aan je pc")
                                     : settings.say("⚠️ PC not reachable: see settings", "⚠️ Pc niet bereikbaar: zie instellingen")
        }
    }

    private var chat: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if brain.lines.isEmpty { welcome }
                    ForEach(brain.lines) { line in Bubble(line: line).id(line.id) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: brain.lines.count) { _ in
                if let last = brain.lines.last { withAnimation(.easeOut(duration: 0.25)) { scroll.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 8) {
            Text(settings.say("Hi! Tap the orb and talk to me.", "Hoi! Tik op de bol en praat tegen me.")).font(.headline)
            Text(settings.hasPC
                 ? settings.say("I can also do things on your PC: \"pause the music on my PC\", \"lock my PC\".",
                                "Ik kan ook dingen op je pc doen: \"zet de muziek op mijn pc op pauze\", \"vergrendel mijn pc\".")
                 : settings.say("Connect me to your PC in the settings to control it from here.",
                                "Koppel me in de instellingen aan je pc om hem vanaf hier te bedienen."))
                .font(.subheadline).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
        }
        .padding(.top, 60).padding(.horizontal, 24)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Button { brain.micTapped() } label: {
                Orb(state: brain.state, level: brain.level).frame(width: 96, height: 96)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.say("Talk to Dave", "Praat met Dave"))

            HStack(spacing: 10) {
                TextField(settings.say("Type to \(settings.displayName)…", "Typ naar \(settings.displayName)…"), text: $typed)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12)))
                if !typed.isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.headline.bold()).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(LinearGradient(colors: [.davePurple, .davePink], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10).padding(.top, 6)
    }

    private func send() {
        let text = typed
        typed = ""
        typing = false
        brain.submit(text)
    }
}

/// One message: yours on the right, Dave's on the left (💻 when it came from the PC).
struct Bubble: View {
    let line: Brain.Line

    var body: some View {
        HStack {
            if line.fromUser { Spacer(minLength: 50) }
            Text((line.viaPC ? "💻 " : "") + line.text)
                .font(.body)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    line.fromUser
                        ? AnyShapeStyle(LinearGradient(colors: [.davePurple.opacity(0.85), .daveViolet.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(line.fromUser ? 0 : 0.1)))
                .textSelection(.enabled)
            if !line.fromUser { Spacer(minLength: 50) }
        }
    }
}

/// Dave's glowing orb: calm when idle, pulsing with your voice when listening, swirling while thinking or talking.
struct Orb: View {
    let state: Brain.State
    let level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed: Double = state == .thinking ? 2.2 : state == .speaking ? 1.4 : 0.5
            let pulse = state == .listening ? 1 + CGFloat(level) * 0.25 : 1 + 0.03 * CGFloat(sin(t * 2))
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [.davePurple, .davePink, .daveCyan, .daveViolet, .davePurple], center: .center,
                                          angle: .degrees(t * 60 * speed)))
                    .blur(radius: 14)
                    .opacity(state == .idle ? 0.55 : 0.9)
                    .scaleEffect(pulse * 1.08)
                Circle()
                    .fill(AngularGradient(colors: [.davePurple, .davePink, .daveCyan, .daveViolet, .davePurple], center: .center,
                                          angle: .degrees(-t * 45 * speed)))
                    .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.45), .clear], center: UnitPoint(x: 0.35, y: 0.3),
                                                          startRadius: 0, endRadius: 40)))
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                    .scaleEffect(pulse)
                if state == .listening {
                    Image(systemName: "waveform").font(.title2.bold()).foregroundStyle(.white)
                }
            }
        }
    }
}

/// Slowly drifting northern lights behind everything.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate / 8
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Color.daveDeep
                    blob(.davePurple, x: w * (0.3 + 0.2 * sin(t)), y: h * (0.25 + 0.1 * cos(t * 0.8)), size: w * 1.1)
                    blob(.davePink, x: w * (0.8 + 0.15 * cos(t * 1.1)), y: h * (0.55 + 0.12 * sin(t * 0.7)), size: w * 0.9)
                    blob(.daveCyan, x: w * (0.2 + 0.15 * cos(t * 0.6)), y: h * (0.85 + 0.08 * sin(t)), size: w * 0.8)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, x: CGFloat, y: CGFloat, size: CGFloat) -> some View {
        Circle().fill(color.opacity(0.32)).frame(width: size, height: size).blur(radius: 90).position(x: x, y: y)
    }
}
