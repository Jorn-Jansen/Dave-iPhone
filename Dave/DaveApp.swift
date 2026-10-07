import SwiftUI

@main
struct DaveApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
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
