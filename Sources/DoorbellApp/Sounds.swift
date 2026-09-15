import AppKit

/// Placeholder sounds until sound design (Phase 7). System sounds honour system mute.
@MainActor
enum Sounds {
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.soundsEnabled) as? Bool ?? true
    }

    /// Knock-knock, quiet enough to sit under the notch rather than startle.
    static func knock() {
        guard enabled else { return }
        play("Tink", volume: 0.28)
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            play("Tink", volume: 0.18)
        }
    }

    /// Door opens.
    static func creak() {
        guard enabled else { return }
        play("Tink", volume: 0.22)
    }

    private static func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
