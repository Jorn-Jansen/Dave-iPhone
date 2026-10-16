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

/// The tabs, like the ones in Dave's window on the PC: chat, social, reminders, memories, the PC's music and screen time
/// (sharing a tab), and the lists (iPhones show five: the last ones are under More).
struct RootView: View {
    @ObservedObject private var settings = Settings.shared
    @StateObject private var data = PCData()
    @ObservedObject private var chat = SocialChat.shared
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }.tag(0)
            SocialPanel(data: data)
                .tabItem { Label(settings.say("Social", "Sociaal"), systemImage: "person.2.fill") }.tag(1)
                .badge(chat.unread + data.friends.filter { $0.status == "incoming" }.count)
            RemindersPanel(data: data)
                .tabItem { Label(settings.say("Reminders", "Herinneringen"), systemImage: "alarm.fill") }.tag(2)
            MemoriesPanel(data: data)
                .tabItem { Label(settings.say("Memories", "Geheugen"), systemImage: "brain.head.profile") }.tag(3)
            PCTab(data: data)
                .tabItem { Label("PC", systemImage: "desktopcomputer") }.tag(4)
            ListsPanel()
                .tabItem { Label(settings.say("Lists", "Lijsten"), systemImage: "checklist") }.tag(5)
        }
        .tint(.davePurple)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .id(settings.theme) // the tab bar in the new theme's colour too
        .task { await Lists.shared.listen() } // the lists stay the same as on the Pi and your other devices while Dave is open
        .task {
            // Scheduled chat messages go out when their time comes (while Dave is open)
            while !Task.isCancelled {
                await chat.sendDue(settings: settings)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .onOpenURL { url in
            tab = 0
            if url.isFileURL { Brain.shared.received(file: url) } // "Open in Dave": send it to the PC
            else if url.host == "talk" { Brain.shared.talkFromWidget() } // the widget: start listening
            else if url.host == "lists", let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value {
                tab = 5 // the QR code from `sudo dave lijst koppel`, scanned with the camera: join the house
                _ = Lists.shared.joinHouse(code)
            }
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
