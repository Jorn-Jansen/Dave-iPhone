import AppIntents

/// "Hey Siri, ask Dave": Siri asks what you want to know, Dave thinks (the same as in the app, PC included) and Siri
/// says his answer. Without opening the app.
struct AskDaveIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Dave"
    static var description = IntentDescription("Ask Dave something. He answers through Siri.")
    static var openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you want to ask Dave?"))
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await Brain.shared.reply(to: question)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

/// The phrases Siri knows without setting anything up ("Ask Dave", "Vraag Dave").
struct DaveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskDaveIntent(), phrases: [
            "Ask \(.applicationName)",
            "Talk to \(.applicationName)",
            "Hey \(.applicationName)",
            "Vraag \(.applicationName)",
            "Vraag het \(.applicationName)",
        ])
    }
}
