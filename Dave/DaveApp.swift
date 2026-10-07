import SwiftUI

@main
struct DaveApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// The tabs, like the ones in Dave's window on the PC: chat, reminders, memories, music and screen time.
struct RootView: View {
    @ObservedObject private var settings = Settings.shared
    @StateObject private var data = PCData()

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            RemindersPanel(data: data)
                .tabItem { Label(settings.say("Reminders", "Herinneringen"), systemImage: "alarm.fill") }
            MemoriesPanel(data: data)
                .tabItem { Label(settings.say("Memories", "Geheugen"), systemImage: "brain.head.profile") }
            MusicPanel(data: data)
                .tabItem { Label(settings.say("Music", "Muziek"), systemImage: "music.note") }
            ScreenTimePanel(data: data)
                .tabItem { Label(settings.say("Screen time", "Schermtijd"), systemImage: "chart.bar.fill") }
        }
        .tint(.davePurple)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .id(settings.theme) // the tab bar in the new theme's colour too
    }
}

/// Dave's colours, from the chosen theme (Aurora's names: purple, violet, pink, cyan, deep).
extension Color {
    static var davePurple: Color { Theme.current.main }
    static var daveViolet: Color { Theme.current.middle }
    static var davePink: Color { Theme.current.accent }
    static var daveCyan: Color { Theme.current.bright }
    static var daveDeep: Color { Theme.current.deep }
}
