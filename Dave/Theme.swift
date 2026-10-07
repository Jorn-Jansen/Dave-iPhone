import SwiftUI

/// Dave's colour themes, the same as on the PC (Settings → Theme there). Legacy is the original look: a calm background
/// and a bright gradient button with a microphone, instead of the glowing orb and northern lights.
struct Theme: Identifiable {
    let id: String
    let name: String
    let description: String
    let main: Color
    let middle: Color
    let accent: Color
    let bright: Color
    let deep: Color
    var legacy = false

    static let all: [Theme] = [
        Theme(id: "aurora", name: "Aurora", description: "Swirling northern lights in dark glass.",
              main: hex(0x9646FF), middle: hex(0x6E5AFF), accent: hex(0xDC50E6), bright: hex(0x00D2FF), deep: hex(0x100A26)),
        Theme(id: "ember", name: "Ember", description: "Glowing fire: red, orange and gold.",
              main: hex(0xFF4D2E), middle: hex(0xFF2E63), accent: hex(0xFF9F1C), bright: hex(0xFFD166), deep: hex(0x1C0A06)),
        Theme(id: "toxic", name: "Toxic", description: "Radioactive green and lime.",
              main: hex(0x22C55E), middle: hex(0x16A34A), accent: hex(0xA3E635), bright: hex(0x2DD4BF), deep: hex(0x06160C)),
        Theme(id: "ocean", name: "Ocean", description: "Deep sea blue and turquoise.",
              main: hex(0x1E6BFF), middle: hex(0x2448C8), accent: hex(0x00C2A8), bright: hex(0x5CE1FF), deep: hex(0x060E20)),
        Theme(id: "sakura", name: "Sakura", description: "Cherry blossom pink and lavender.",
              main: hex(0xFF6FAE), middle: hex(0xC77DFF), accent: hex(0xFF9ECF), bright: hex(0xFFD1E6), deep: hex(0x1E0A18)),
        Theme(id: "midnight", name: "Midnight", description: "Sleek silver and white, nothing loud.",
              main: hex(0x8EA0BC), middle: hex(0x5B6B85), accent: hex(0xC9D4E5), bright: hex(0xFFFFFF), deep: hex(0x0C0E14)),
        Theme(id: "legacy", name: "Legacy", description: "The original Dave: a bright gradient button with a microphone.",
              main: hex(0x9646FF), middle: hex(0x6E5AFF), accent: hex(0xDC50E6), bright: hex(0x00D2FF), deep: hex(0x100A26), legacy: true),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }

    /// The theme chosen in the settings.
    static var current: Theme { named(Settings.shared.theme) }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
