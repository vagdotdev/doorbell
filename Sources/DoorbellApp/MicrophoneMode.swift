import AVFoundation
import SwiftUI

/// The system microphone mode (Standard / Voice Isolation / Wide Spectrum), as the
/// user set it in Control Center. Apps cannot set it; we can read it and open the
/// picker. See docs/audio.md.
@MainActor
final class MicrophoneMode: ObservableObject {
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

    /// The first time this Mac's microphone goes live for a door, and it is still on
    /// Standard, open the picker once so Voice Isolation is a click away. The modes
    /// are only selectable while the mic is capturing, which is why this waits for
    /// that moment rather than asking at launch. Never again after that.
    static func nudgeOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKey.micModeNudged) else { return }
        defaults.set(true, forKey: SettingsKey.micModeNudged)
        guard AVCaptureDevice.preferredMicrophoneMode == .standard else { return }
        choose()
    }
}
