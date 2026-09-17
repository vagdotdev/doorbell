import SwiftUI

/// Layout of the door shell: the notch row stays black (the hardware has just grown),
/// then a centred title, the glass as the hero, and a row of round controls.
struct DoorFrame<Title: View, Glass: View, Controls: View>: View {
    let geometry: NotchGeometry
    /// Brightens the doorstep — listening, or the door about to open.
    var lit = false
    @ViewBuilder let title: Title
    @ViewBuilder let glass: Glass
    @ViewBuilder let controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: geometry.notchHeight)
            title
                .padding(.top, 6)
                .padding(.horizontal, 24)
            glass
                .frame(height: DesignTokens.glassHeight)
                .padding(.top, 6)
            controls
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .background {
            // The shell already carries the stars; the doorstep rises beneath the notch row.
            VStack(spacing: 0) {
                Color.clear.frame(height: geometry.notchHeight)
                Doorstep(rise: DesignTokens.doorstepRise, lit: lit)
            }
        }
    }
}

/// Two-line title: who, and what's happening.
struct DoorTitle<Subtitle: View>: View {
    let name: String
    @ViewBuilder let subtitle: Subtitle

    var body: some View {
        VStack(spacing: 3) {
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            subtitle
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.inkSecondary)
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
    }
}
