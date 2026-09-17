import AppKit
import AVFoundation

/// The knock is a cabin chime: two clean tones, high then low, under two seconds
/// (`Assets/Sounds/knock.wav`), handing over to the visitor's voice as it dies away.
/// Everything else is still a placeholder system sound until sound design (Phase 7).
@MainActor
enum Sounds {
    /// How far into the knock tone the visitor's voice starts to come up under it.
    static let knockHandoff: TimeInterval = 1.0

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.soundsEnabled) as? Bool ?? true
    }

    private static var knockPlayer: AVAudioPlayer?

    /// Rings the knock tone. Returns false when nothing played (sounds off, file missing),
    /// so the caller can bring the voice in straight away instead.
    @discardableResult
    static func knock() -> Bool {
        guard enabled,
              let url = Bundle.module.url(forResource: "knock", withExtension: "wav", subdirectory: "Sounds"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        knockPlayer?.stop()
        player.volume = 0.3
        player.play()
        knockPlayer = player
        return true
    }

    /// Cuts the knock tone short, gently — the door opened or the peephole closed.
    static func stopKnock() {
        guard let player = knockPlayer, player.isPlaying else { return }
        player.setVolume(0, fadeDuration: 0.25)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if knockPlayer === player { player.stop(); knockPlayer = nil }
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
