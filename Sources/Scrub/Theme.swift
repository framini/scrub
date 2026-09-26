import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static let fog = Color(hex: 0xEEF1EF)
    static let snow = Color(hex: 0xFFFFFF)
    static let mist = Color(hex: 0xF6F8F7)
    static let line = Color(hex: 0xE3E9E5)
    static let rule = Color(hex: 0xDDE5E0)
    static let dash = Color(hex: 0xB9C4BE)
    static let slate = Color(hex: 0x5B6660)
    static let ink = Color(hex: 0x101413)
    static let evergreen = Color(hex: 0x1F4D3A)
    static let lichen = Color(hex: 0xE6EEE9)
    static let ember = Color(hex: 0x9A3B1F)
    static let emberWash = Color(hex: 0xF8ECE6)
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.evergreen.opacity(configuration.isPressed ? 0.85 : 1), in: .rect(cornerRadius: 7))
    }
}

struct KeyHint: View {
    let key: String
    var onDark = false
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(onDark ? Color.snow.opacity(0.85) : Color.slate)
            .padding(.horizontal, 5)
            .frame(minHeight: 18)
            .background(onDark ? Color.snow.opacity(0.16) : Color.ink.opacity(0.07), in: .rect(cornerRadius: 4))
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.snow.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.rule))
    }
}

struct Card<Content: View>: View {
    var dashed = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.snow, in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dashed ? Color.dash : Color.rule, style: StrokeStyle(lineWidth: dashed ? 1.5 : 1, dash: dashed ? [6, 5] : []))
            )
    }
}

struct ShortcutPress: ViewModifier {
    let shortcut: Shortcut
    let pulse: ShortcutPulse?
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(pressed ? 0.8 : 1)
            .onChange(of: pulse) { _, new in
                guard new?.shortcut == shortcut else { return }
                withAnimation(.easeOut(duration: 0.1)) { pressed = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeOut(duration: 0.15)) { pressed = false }
                }
            }
    }
}
