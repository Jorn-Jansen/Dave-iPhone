import SwiftUI
import UserNotifications

/// Shows a reminder's notification also when Dave is open (iOS only shows them for closed apps by itself).
final class NotificationShower: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

@main
struct DaveApp: App {
    private let notifications = NotificationShower()

    init() {
        UNUserNotificationCenter.current().delegate = notifications // phone reminders also show while Dave is open
    }

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
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }.tag(0)
            RemindersPanel(data: data)
                .tabItem { Label(settings.say("Reminders", "Herinneringen"), systemImage: "alarm.fill") }.tag(1)
            MemoriesPanel(data: data)
                .tabItem { Label(settings.say("Memories", "Geheugen"), systemImage: "brain.head.profile") }.tag(2)
            MusicPanel(data: data)
                .tabItem { Label(settings.say("Music", "Muziek"), systemImage: "music.note") }.tag(3)
            ScreenTimePanel(data: data)
                .tabItem { Label(settings.say("Screen time", "Schermtijd"), systemImage: "chart.bar.fill") }.tag(4)
        }
        .tint(.davePurple)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .id(settings.theme) // the tab bar in the new theme's colour too
        .onOpenURL { url in
            tab = 0
            if url.isFileURL { Brain.shared.received(file: url) } // "Open in Dave": send it to the PC
            else if url.host == "talk" { Brain.shared.talkFromWidget() } // the widget: start listening
        }
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
