import SwiftUI

/// The board while there is no account behind it. Setting up happens in a window
/// (`OnboardingView`); here there is only the way back to it, or a retry.
struct AccountView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var state: NotchState

    var body: some View {
        VStack(spacing: 12) {
            switch hallway.account {
            case .unavailable:
                Text("Doorbell can’t connect right now.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.ink)
                PillButton(title: "Try Again", prominent: true) { Task { await hallway.refresh() } }
            default:
                Text("Doorbell isn’t set up yet.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.ink)
                PillButton(title: "Set Up", prominent: true) { state.onSetupRequested?() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 14)
    }
}
