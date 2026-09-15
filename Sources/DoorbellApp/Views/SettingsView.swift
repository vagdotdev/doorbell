import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var door: DoorController
    @AppStorage(SettingsKey.peepholeStyle) private var peephole: PeepholeStyle = .eyehole
    @AppStorage(SettingsKey.soundsEnabled) private var sounds = true
    @StateObject private var mic = MicrophoneMode()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubHeader("Settings")

            VStack(spacing: 0) {
                SettingRow(title: "Quiet door") {
                    Toggle("Quiet door", isOn: $door.quiet).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .help("No automatic walk-ins or door audio. You choose when to answer.")
                }
                Divider().overlay(DesignTokens.hairline)
                SettingRow(title: "Glass") {
                    SegmentedPills(options: PeepholeStyle.allCases, selection: $peephole) { $0.label }
                }
                Divider().overlay(DesignTokens.hairline)
                SettingRow(title: "Sounds") {
                    Toggle("", isOn: $sounds)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(DesignTokens.utility)
                }
                Divider().overlay(DesignTokens.hairline)
                // macOS's own Voice Isolation. It is the system's choice, not ours to set;
                // we can only open the picker. Applies to the doorstep as much as the room.
                SettingRow(title: "Microphone") {
                    PillButton(title: mic.label) { MicrophoneMode.choose() }
                }
            }
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DesignTokens.raised)
            )

            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("Doorbell")
                if let me = hallway.me {
                    Text("·")
                    Text("@\(me.handle)")
                }
                Spacer()
                if AppConfig.current.useSupabase {
                    Button("Sign Out") { hallway.signOut() }.disabled(hallway.isSigningOut)
                        .buttonStyle(.plain)
                        .foregroundStyle(DesignTokens.inkSecondary)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(DesignTokens.inkTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.ink)
            Spacer(minLength: 8)
            control
        }
        .frame(height: 36)
    }
}
