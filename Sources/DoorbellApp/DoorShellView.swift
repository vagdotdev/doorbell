import SwiftUI

/// The door itself. Milestone 1: idle shell only.
struct DoorShellView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.shellRadius, style: .continuous)
                .fill(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.shellRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.14), .white.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
            HStack(spacing: 12) {
                Circle()
                    .fill(DesignTokens.doorOpen)
                    .frame(width: 10, height: 10)
                    .shadow(color: DesignTokens.doorOpen.opacity(0.8), radius: 6)
                Text("Doorbell")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("@vagdev")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 22)
        }
        .frame(width: DesignTokens.expandedWidth, height: 220)
    }
}
