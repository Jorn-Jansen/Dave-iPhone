import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var brain = Brain.shared
    @StateObject private var updater = Updater()
    @Environment(\.scenePhase) private var scenePhase
    @State private var updateStatus = ""
    @ObservedObject private var settings = Settings.shared
    @State private var typed = ""
    @State private var showSettings = false
    @FocusState private var typing: Bool

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                header
                if let release = updater.available { updateNotice(release) }
                chat
                controls
            }
        }
        .id(settings.theme) // another theme: draw everything again in its colours
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fileImporter(isPresented: $brain.pickingFile, allowedContentTypes: [.item]) { result in
            brain.filePicked(try? result.get())
        }
        .onChange(of: brain.pickingFile) { picking in
            // Closed without picking: let Dave know (a pick arrives before this, so it isn't lost)
            if !picking { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { brain.filePicked(nil) } }
        }
        .onAppear { if settings.groqKey.isEmpty { showSettings = true } }
        .task { await updater.check() }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await updater.check() } } }
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

    /// "A new Dave is out": the new Dave.ipa is installed from the PC, so the page can be opened there.
    private func updateNotice(_ release: Updater.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.say("✨ Dave \(release.version) is out", "✨ Dave \(release.version) is uit")).font(.headline)
            Text(settings.say("Download Dave.ipa on your PC and install it with Sideloadly, like before. Your settings stay.",
                              "Download Dave.ipa op je pc en installeer hem met Sideloadly, zoals eerder. Je instellingen blijven."))
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 10) {
                if settings.hasPC {
                    Button(settings.say("Open on my PC", "Open op mijn pc")) {
                        Task {
                            do {
                                _ = try await PCLink.command("open_website", args: ["url": release.page.absoluteString], settings: settings)
                                updateStatus = settings.say("✅ Opened on your PC.", "✅ Geopend op je pc.")
                            } catch {
                                updateStatus = "⚠️ " + error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.davePurple)
                } else {
                    Link(settings.say("Show page", "Toon pagina"), destination: release.page)
                        .buttonStyle(.borderedProminent).tint(.davePurple)
                }
                Button(settings.say("Later", "Later")) { updateStatus = ""; updater.later() }
                    .buttonStyle(.bordered).tint(.white)
            }
            if !updateStatus.isEmpty { Text(updateStatus).font(.caption).foregroundStyle(.white.opacity(0.7)) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.davePurple.opacity(0.5)))
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private var status: String {
        switch brain.state {
        case .listening: return settings.say("Listening…", "Ik luister…")
        case .thinking:
            if let progress = brain.progress { return settings.say("Looking through your photos… ", "Ik bekijk je foto's… ") + progress }
            return settings.say("Thinking…", "Even denken…")
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
        VStack(alignment: .leading, spacing: 6) {
            message
            if !line.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(line.images.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 92, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private var message: some View {
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
        if Theme.current.legacy { legacy } else { orb }
    }

    /// The original look: a bright gradient button with a microphone, that grows with your voice.
    private var legacy: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = state == .listening ? 1 + CGFloat(level) * 0.2 : state == .thinking ? 1 + 0.05 * CGFloat(sin(t * 6)) : 1
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.davePurple, .davePink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .davePurple.opacity(0.6), radius: 14)
                Image(systemName: state == .listening ? "waveform" : state == .speaking ? "speaker.wave.2.fill" : "mic.fill")
                    .font(.title.bold()).foregroundStyle(.white)
            }
            .scaleEffect(pulse)
        }
    }

    private var orb: some View {
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
        if Theme.current.legacy {
            // The original look: calm, no northern lights
            LinearGradient(colors: [.daveDeep, .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        } else {
            lights
        }
    }

    private var lights: some View {
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
