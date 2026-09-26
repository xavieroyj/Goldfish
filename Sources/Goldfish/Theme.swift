import SwiftUI

extension Color {
    static let ink = Color(hex: 0xE7EFEE)
    static let muted = Color(hex: 0x89999A)
    static let lilac = Color(hex: 0x8C9DFF)
    static let mint = Color(hex: 0x62D7B1)
    static let coral = Color(hex: 0xF07D83)
    static let canvas = Color(hex: 0x0B1114)
    static let surface = Color(hex: 0x121A1E)
    static let panel = Color(hex: 0x151F23)
    static let raised = Color(hex: 0x1B272B)
    static let border = Color(hex: 0x2B393D)
    static let blue = Color(hex: 0x6CAAF8)
    static let amber = Color(hex: 0xE6BD66)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
