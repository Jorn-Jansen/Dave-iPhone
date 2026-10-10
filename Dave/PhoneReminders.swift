import Foundation
import UserNotifications

/// Reminders and timers on the iPhone itself ("remind me at 8 to call mom", "timer for 10 minutes"): real iPhone
/// notifications, also when the app is closed and the PC is off.
enum PhoneReminders {
    struct Reminder: Identifiable {
        let id: String
        let message: String
        let when: String
        let repeats: Bool
    }

    /// Set one; returns what to say ("Okay, at 08:00: call mom.").
    static func set(_ args: [String: Any], settings: Settings) async -> String {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else {
            return settings.say("I'm not allowed to send notifications. Turn them on in iOS' settings → Dave → Notifications.",
                                "Ik mag geen meldingen sturen. Zet ze aan in de iOS-instellingen → Dave → Meldingen.")
        }
        let message = (args["message"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let repeatDaily = (args["repeat"] as? String) == "daily"
        let content = UNMutableNotificationContent()
        content.title = "⏰ " + settings.displayName
        content.body = message.isEmpty ? settings.say("Your reminder", "Je herinnering") : message
        content.sound = .default

        let trigger: UNNotificationTrigger
        let when: String
        if let minutes = (args["minutes"] as? Double) ?? (args["minutes"] as? Int).map(Double.init), minutes > 0, !repeatDaily {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, minutes * 60), repeats: false)
            when = minutes < 60 ? settings.say("in \(spoken(minutes, settings))", "over \(spoken(minutes, settings))")
                                : settings.say("at ", "om ") + clock(Date().addingTimeInterval(minutes * 60))
        } else if let time = args["time"] as? String, let (hour, minute) = parse(time) {
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeatDaily)
            let label = String(format: "%02d:%02d", hour, minute)
            when = repeatDaily ? settings.say("every day at \(label)", "elke dag om \(label)") : settings.say("at \(label)", "om \(label)")
        } else {
            return settings.say("I didn't get when to remind you.", "Ik snapte niet wanneer ik je moet herinneren.")
        }
        let id = "dave-\(UUID().uuidString)"
        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) }
        catch { return settings.say("The reminder didn't work.", "De herinnering lukte niet.") }
        return settings.say("Okay, \(when): \(content.body)", "Oké, \(when): \(content.body)")
    }

    /// The reminders still to come, soonest first.
    static func all(settings: Settings) async -> [Reminder] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests().filter { $0.identifier.hasPrefix("dave-") }
        let dated: [(Date, Reminder)] = requests.map { request in
            var next = Date.distantFuture
            var repeats = false
            if let t = request.trigger as? UNTimeIntervalNotificationTrigger { next = t.nextTriggerDate() ?? next; repeats = t.repeats }
            if let t = request.trigger as? UNCalendarNotificationTrigger { next = t.nextTriggerDate() ?? next; repeats = t.repeats }
            let when = next == .distantFuture ? "?" : describe(next, settings) + (repeats ? settings.say(" · every day", " · elke dag") : "")
            return (next, Reminder(id: request.identifier, message: request.content.body, when: when, repeats: repeats))
        }
        return dated.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Cancel the ones whose message contains [which] (or all, when it's empty); returns how many.
    static func cancel(_ which: String) async -> Int {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("dave-") }
        let words = which.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
        let matching = requests.filter { r in words.isEmpty || words.contains { r.content.body.lowercased().contains($0) } }
        center.removePendingNotificationRequests(withIdentifiers: matching.map(\.identifier))
        return matching.count
    }

    static func delete(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    private static func parse(_ time: String) -> (Int, Int)? {
        let parts = time.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
        guard let hour = parts.first, (0...23).contains(hour) else { return nil }
        let minute = parts.count > 1 ? parts[1] : 0
        return (0...59).contains(minute) ? (hour, minute) : nil
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static func describe(_ date: Date, _ settings: Settings) -> String {
        if Calendar.current.isDateInToday(date) { return settings.say("today ", "vandaag ") + clock(date) }
        if Calendar.current.isDateInTomorrow(date) { return settings.say("tomorrow ", "morgen ") + clock(date) }
        let f = DateFormatter()
        f.locale = Locale(identifier: settings.isDutch ? "nl_NL" : "en_GB")
        f.dateFormat = "EEE d MMM HH:mm"
        return f.string(from: date)
    }

    private static func spoken(_ minutes: Double, _ settings: Settings) -> String {
        if minutes < 1 { return settings.say("\(Int(minutes * 60)) seconds", "\(Int(minutes * 60)) seconden") }
        let m = Int(minutes.rounded())
        return m == 1 ? settings.say("1 minute", "1 minuut") : settings.say("\(m) minutes", "\(m) minuten")
    }
}
