import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @AppStorage(SettingsKey.peepholeStyle) private var peephole: PeepholeStyle = .eyehole
    @AppStorage(SettingsKey.soundsEnabled) private var sounds = true
    @StateObject private var mic = MicrophoneMode()

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

/// The system microphone mode (Standard / Voice Isolation / Wide Spectrum), as the
/// user set it in Control Center. Read-only from here; `choose()` opens the picker.
@MainActor
private final class MicrophoneMode: ObservableObject {
    @Published private(set) var label = "Standard"
    private var poll: Task<Void, Never>?

    init() {
        refresh()
        // A class property with no Swift KVO; the picker lives in Control Center, so
        // poll gently while the settings board is up.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refresh()
            }
        }
    }

    deinit { poll?.cancel() }

    private func refresh() {
        label = switch AVCaptureDevice.preferredMicrophoneMode {
        case .voiceIsolation: "Voice Isolation"
        case .wideSpectrum: "Wide Spectrum"
        default: "Standard"
        }
    }

    static func choose() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
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
