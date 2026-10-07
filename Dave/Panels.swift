import SwiftUI

/// What Dave's window on the PC shows (reminders, memories, music, screen time), fetched over the link. Shared by the tabs.
@MainActor
final class PCData: ObservableObject {
    struct Reminder: Identifiable { let id: String; let message: String; let repeats: String; let next: String }
    struct AppTime: Identifiable { var id: String { app }; let app: String; let seconds: Int }
    struct DayTime: Identifiable { var id: String { day }; let day: String; let seconds: Int }
    struct Song: Identifiable { let id = UUID(); let title: String; let artist: String; let at: String }

    @Published var reminders: [Reminder] = []
    @Published var watching: [String] = []
    @Published var memories: [String] = []
    @Published var today: [AppTime] = []
    @Published var week: [AppTime] = []
    @Published var days: [DayTime] = []
    @Published var nowPlaying: Song?
    @Published var history: [Song] = []
    @Published var disliked: [Song] = []
    @Published var problem: String?
    @Published var loaded = false
    @Published var updating = false

    private let settings = Settings.shared
    private let cacheKey = "pcState"

    /// What the tabs showed last time, so they're filled right away (and stay filled when the PC can't be reached).
    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            apply(json, fresh: false)
        }
    }

    func refresh() async {
        guard settings.hasPC, !updating else { return } // one fetch at a time (every tab asks when it opens)
        updating = true
        defer { updating = false }
        for attempt in 0..<3 {
            do {
                apply(try await PCLink.state(settings: settings))
                return
            } catch {
                if error is CancellationError { return }
                if attempt == 2 { problem = error.localizedDescription }
                else { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000) }
            }
        }
    }

    /// A change from a tab ("deleteReminder", "addMemory"…), done by Dave on the PC.
    func change(_ change: [String: Any]) async {
        do { apply(try await PCLink.change(change, settings: settings)) } catch { problem = error.localizedDescription }
    }

    private func apply(_ json: [String: Any], fresh: Bool = true) {
        if fresh, let data = try? JSONSerialization.data(withJSONObject: json) { UserDefaults.standard.set(data, forKey: cacheKey) }
        func list(_ key: String, in object: [String: Any]? = nil) -> [[String: Any]] { ((object ?? json)[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
        func song(_ d: [String: Any]) -> Song { Song(title: d["title"] as? String ?? "", artist: d["artist"] as? String ?? "", at: d["at"] as? String ?? "") }
        reminders = list("reminders").map { Reminder(id: $0["id"] as? String ?? "", message: $0["message"] as? String ?? "",
                                                     repeats: $0["repeat"] as? String ?? "", next: $0["next"] as? String ?? "") }
        watching = json["watching"] as? [String] ?? []
        memories = json["memories"] as? [String] ?? []
        settings.memories = memories // what the phone's AI knows about you stays the same as on the PC
        let screen = json["screen"] as? [String: Any]
        today = list("today", in: screen).map { AppTime(app: $0["app"] as? String ?? "", seconds: $0["seconds"] as? Int ?? 0) }
        week = list("week", in: screen).map { AppTime(app: $0["app"] as? String ?? "", seconds: $0["seconds"] as? Int ?? 0) }
        days = list("days", in: screen).map { DayTime(day: $0["day"] as? String ?? "", seconds: $0["seconds"] as? Int ?? 0) }
        let music = json["music"] as? [String: Any]
        nowPlaying = (music?["now"] as? [String: Any]).map(song)
        history = list("history", in: music).map(song)
        disliked = list("disliked", in: music).map(song)
        loaded = true
        if fresh {
            problem = nil
            settings.pcLinked = true
        }
    }
}

/// A tab's frame: the theme's background, a title, and the settings button.
struct Panel<Content: View>: View {
    let title: String
    @ObservedObject private var settings = Settings.shared
    @ObservedObject var data: PCData
    @State private var showSettings = false
    let content: Content

    init(_ title: String, data: PCData, @ViewBuilder content: () -> Content) {
        self.title = title
        self.data = data
        self.content = content()
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.largeTitle.bold())
                        if data.updating {
                            Text(settings.say("Updating…", "Bijwerken…")).font(.caption).foregroundStyle(.white.opacity(0.6))
                        } else if data.problem != nil && data.loaded {
                            Text(settings.say("⚠️ PC not reachable: showing the last data", "⚠️ Pc niet bereikbaar: laatste gegevens"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
                if !settings.hasPC {
                    note(settings.say("Connect me to your PC (⚙) to see this here.", "Koppel me aan je pc (⚙) om dit hier te zien."))
                } else if !data.loaded {
                    if let problem = data.problem { note("⚠️ " + problem) }
                    else { VStack { Spacer(); ProgressView().controlSize(.large).tint(.white); Spacer() } }
                } else {
                    content
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { await data.refresh() }
    }

    private func note(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7)).padding(30)
            Spacer()
        }
    }
}

/// A list in Dave's glass style (rows on the theme's background), with pull to refresh.
struct GlassList<Content: View>: View {
    @ObservedObject var data: PCData
    @ViewBuilder let content: () -> Content

    var body: some View {
        List { content() }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .refreshable { await data.refresh() }
    }
}

private func row<V: View>(@ViewBuilder _ content: () -> V) -> some View {
    content().listRowBackground(Color.white.opacity(0.07))
}

/// "2 h 15 min", "45 min", "under a minute"
func duration(_ seconds: Int, _ settings: Settings) -> String {
    let minutes = seconds / 60
    if minutes < 1 { return settings.say("under a minute", "minder dan een minuut") }
    if minutes < 60 { return "\(minutes) min" }
    return minutes % 60 == 0 ? "\(minutes / 60) \(settings.say("h", "u"))" : "\(minutes / 60) \(settings.say("h", "u")) \(minutes % 60) min"
}

// MARK: Reminders

struct RemindersPanel: View {
    @ObservedObject var data: PCData
    private let settings = Settings.shared

    var body: some View {
        Panel(settings.say("Reminders", "Herinneringen"), data: data) {
            GlassList(data: data) {
                Section {
                    if data.reminders.isEmpty {
                        row { Text(settings.say("No reminders. Say \"remind me at 8 to…\" to your PC Dave.", "Geen herinneringen. Zeg \"herinner me om 8 uur aan…\" tegen Dave.")).foregroundStyle(.secondary) }
                    }
                    ForEach(data.reminders) { reminder in
                        row {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(reminder.message)
                                Text("\(reminder.next) · \(reminder.repeats)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { let id = data.reminders[index].id; Task { await data.change(["type": "deleteReminder", "id": id]) } }
                    }
                } header: {
                    Text(settings.say("On your PC · swipe to delete", "Op je pc · veeg om te verwijderen"))
                }

                Section {
                    if data.watching.isEmpty {
                        row { Text(settings.say("Nothing right now. Say \"tell me when Roblox closes\".", "Nu niets. Zeg \"laat me weten als Roblox sluit\".")).foregroundStyle(.secondary) }
                    } else {
                        ForEach(data.watching, id: \.self) { item in row { Text(item) } }
                        row {
                            Button(settings.say("Stop watching", "Stop met opletten"), role: .destructive) { Task { await data.change(["type": "stopWatching"]) } }
                        }
                    }
                } header: {
                    Text(settings.say("Watching for", "Let op"))
                }
            }
        }
    }
}

// MARK: Memories

struct MemoriesPanel: View {
    @ObservedObject var data: PCData
    @State private var newMemory = ""
    private let settings = Settings.shared

    var body: some View {
        Panel(settings.say("Memories", "Geheugen"), data: data) {
            GlassList(data: data) {
                Section {
                    row {
                        HStack {
                            TextField(settings.say("Something to remember…", "Iets om te onthouden…"), text: $newMemory)
                                .onSubmit(add)
                            Button(action: add) { Image(systemName: "plus.circle.fill").font(.title2) }
                                .disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } footer: {
                    Text(settings.say("Dave uses these on your PC and here. You can also say \"remember that…\".",
                                      "Dave gebruikt deze op je pc en hier. Je kunt ook zeggen \"onthoud dat…\"."))
                }
                Section {
                    ForEach(data.memories, id: \.self) { memory in row { Text(memory) } }
                        .onDelete { offsets in
                            for index in offsets { let text = data.memories[index]; Task { await data.change(["type": "deleteMemory", "text": text]) } }
                        }
                } header: {
                    Text(settings.say("What I remember · swipe to forget", "Wat ik onthoud · veeg om te vergeten"))
                }
            }
        }
    }

    private func add() {
        let text = newMemory.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        newMemory = ""
        Task { await data.change(["type": "addMemory", "text": text]) }
    }
}

// MARK: Music

struct MusicPanel: View {
    @ObservedObject var data: PCData
    @State private var spotifyNow: String?
    private let settings = Settings.shared

    var body: some View {
        Panel(settings.say("Music", "Muziek"), data: data) {
            GlassList(data: data) {
                Section(settings.say("Now playing", "Nu speelt")) {
                    if let now = spotifyNow { row { Label(now, systemImage: "iphone") } }
                    if let song = data.nowPlaying {
                        row { Label("\(song.title) – \(song.artist)", systemImage: "desktopcomputer") }
                    } else if spotifyNow == nil {
                        row { Text(settings.say("Nothing is playing.", "Er speelt niets.")).foregroundStyle(.secondary) }
                    }
                }
                Section(settings.say("Played on your PC", "Gespeeld op je pc")) {
                    if data.history.isEmpty { row { Text(settings.say("No songs yet.", "Nog geen nummers.")).foregroundStyle(.secondary) } }
                    ForEach(data.history) { song in
                        row {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                    Text(song.artist).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(song.at).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !data.disliked.isEmpty {
                    Section {
                        ForEach(data.disliked) { song in row { Text("\(song.title) – \(song.artist)") } }
                            .onDelete { offsets in
                                for index in offsets {
                                    let song = data.disliked[index]
                                    Task { await data.change(["type": "undislike", "title": song.title, "artist": song.artist]) }
                                }
                            }
                    } header: {
                        Text(settings.say("Never played (you don't like them) · swipe to allow", "Nooit gespeeld (vind je niet leuk) · veeg om toe te staan"))
                    }
                }
            }
        }
        .task { if Spotify.isConnected { spotifyNow = try? await Spotify.nowPlaying(settings: settings) } }
    }
}

// MARK: Screen time

struct ScreenTimePanel: View {
    @ObservedObject var data: PCData
    @State private var week = false
    private let settings = Settings.shared

    var body: some View {
        Panel(settings.say("Screen time", "Schermtijd"), data: data) {
            GlassList(data: data) {
                Section {
                    row {
                        Picker("", selection: $week) {
                            Text(settings.say("Today", "Vandaag")).tag(false)
                            Text(settings.say("This week", "Deze week")).tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    let apps = week ? data.week : data.today
                    let total = apps.reduce(0) { $0 + $1.seconds }
                    row {
                        HStack {
                            Text(settings.say("Total", "Totaal")).font(.headline)
                            Spacer()
                            Text(duration(total, settings)).font(.headline)
                        }
                    }
                    let most = max(apps.map(\.seconds).max() ?? 1, 1)
                    ForEach(apps) { app in
                        row {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(app.app)
                                    Spacer()
                                    Text(duration(app.seconds, settings)).foregroundStyle(.secondary)
                                }
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(LinearGradient(colors: [.davePurple, .davePink], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(6, geo.size.width * CGFloat(app.seconds) / CGFloat(most)))
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                } header: {
                    Text(settings.say("On your PC (while you were at it)", "Op je pc (terwijl je erachter zat)"))
                }

                if week && !data.days.isEmpty {
                    Section(settings.say("Per day", "Per dag")) {
                        row {
                            let most = max(data.days.map(\.seconds).max() ?? 1, 1)
                            HStack(alignment: .bottom, spacing: 8) {
                                ForEach(data.days) { day in
                                    VStack(spacing: 4) {
                                        Spacer(minLength: 0)
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(LinearGradient(colors: [.daveCyan, .davePurple], startPoint: .top, endPoint: .bottom))
                                            .frame(height: max(4, 110 * CGFloat(day.seconds) / CGFloat(most)))
                                        Text(day.day).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(height: 140)
                        }
                    }
                }
            }
        }
    }
}
