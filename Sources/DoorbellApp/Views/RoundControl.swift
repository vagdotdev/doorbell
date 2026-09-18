import SwiftUI

/// A FaceTime-style round control: glyph in a circle, small label beneath.
/// Plain glass by default; `tint` fills it (the one green button); `active` turns
/// it white, the way FaceTime shows a control that is on.
struct RoundControl: View {
    let symbol: String
    let label: String
    var tint: Color?
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundControlLabel(symbol: symbol, label: label, tint: tint, active: active, hovering: hovering)
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
    }
}

/// Same face as `RoundControl`, opening a menu instead of firing one action.
struct RoundMenuControl<Content: View>: View {
    let symbol: String
    let label: String
    var tint: Color?
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            RoundControlLabel(symbol: symbol, label: label, tint: tint, active: false, hovering: hovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .tint(tint ?? DesignTokens.ink)
    }
}

private struct RoundControlLabel: View {
    let symbol: String
    let label: String
    var tint: Color?
    var active = false
    var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(glyph)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: DesignTokens.controlSize, height: DesignTokens.controlSize)
                .background(Circle().fill(fill))
                .shadow(color: tint?.opacity(hovering ? 0.45 : 0.28) ?? .clear, radius: 10, y: 3)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DesignTokens.inkSecondary)
        }
        .frame(width: 70)
        .contentShape(Rectangle())
    }

    private var glyph: Color {
        if tint != nil || active { return .black.opacity(0.85) }
        return DesignTokens.ink
    }

    private var fill: Color {
        if let tint { return tint.opacity(hovering ? 1 : 0.92) }
        if active { return .white.opacity(hovering ? 1 : 0.92) }
        return .white.opacity(hovering ? 0.20 : 0.13)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
