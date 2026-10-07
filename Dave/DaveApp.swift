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

/// Dave's Aurora colours, the same as on the PC.
extension Color {
    static let davePurple = Color(red: 0x96 / 255, green: 0x46 / 255, blue: 0xFF / 255)
    static let daveViolet = Color(red: 0x6E / 255, green: 0x5A / 255, blue: 0xFF / 255)
    static let davePink = Color(red: 0xDC / 255, green: 0x50 / 255, blue: 0xE6 / 255)
    static let daveCyan = Color(red: 0x00 / 255, green: 0xD2 / 255, blue: 0xFF / 255)
    static let daveDeep = Color(red: 0x10 / 255, green: 0x0A / 255, blue: 0x26 / 255)
}
