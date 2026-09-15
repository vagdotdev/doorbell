import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @AppStorage(SettingsKey.peepholeStyle) private var peephole: PeepholeStyle = .eyehole
    @AppStorage(SettingsKey.soundsEnabled) private var sounds = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubHeader("Settings")

            VStack(spacing: 0) {
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
                    Button("Sign Out") { hallway.signOut() }
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
