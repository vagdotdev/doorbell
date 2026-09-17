import SwiftUI

/// Header for the shell's sub-modes: back chevron + title (or custom content).
struct SubHeader<Content: View>: View {
    @EnvironmentObject private var state: NotchState
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { state.mode = .hallway } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DesignTokens.raised))
            }
            .buttonStyle(.plain)
            content
        }
        .frame(height: 30)
    }
}

extension SubHeader where Content == Text {
    init(_ title: String) {
        self.init {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
        }
    }
}

/// Small capsule button. `prominent` is filled with the utility accent.
struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? .black : DesignTokens.ink)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(
                    Capsule().fill(prominent
                                   ? DesignTokens.utility.opacity(hovering ? 1 : 0.9)
                                   : (hovering ? .white.opacity(0.12) : DesignTokens.raised))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One line in a list of people: avatar, name, handle, and whatever goes on the right.
struct PersonRow<Trailing: View>: View {
    let profile: Profile
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(profile: profile, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.ink)
                Text("@\(profile.handle)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 40)
    }
}
