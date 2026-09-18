import AppKit
import AVFoundation

/// The knock is a cabin chime: two clean tones, high then low, under two seconds
/// (`Assets/Sounds/knock.wav`), handing over to the visitor's voice as it dies away.
/// Chat has its own quiet two-note cue, generated locally without another asset.
@MainActor
enum Sounds {
    /// How far into the knock tone the visitor's voice starts to come up under it.
    static let knockHandoff: TimeInterval = 1.0

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.soundsEnabled) as? Bool ?? true
    }

    private static var knockPlayer: AVAudioPlayer?
    private static var chatPlayer: AVAudioPlayer?
    private static var chatThrottle = ChatCueThrottle()
    private static let chatData = makeChatTone()

    /// A small cue, including when the chat is already open. Burst messages stay quiet.
    static func chatMessage() {
        guard chatThrottle.shouldPlay(enabled: enabled, now: ProcessInfo.processInfo.systemUptime),
              let player = try? AVAudioPlayer(data: chatData) else { return }
        chatPlayer?.stop()
        player.volume = 0.12
        player.play()
        chatPlayer = player
    }

    /// A soft rising interval with no hard edges. Mono PCM keeps this independent
    /// of the call's capture engine, audio route, and microphone lifecycle.
    private static func makeChatTone() -> Data {
        let sampleRate = 48_000
        let sampleCount = Int(0.34 * Double(sampleRate))
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            func note(_ frequency: Double, start: Double, duration: Double) -> Double {
                let t = time - start
                guard t >= 0, t < duration else { return 0 }
                let attack = pow(sin(.pi / 2 * min(t / 0.014, 1)), 2)
                let release = pow(sin(.pi / 2 * min((duration - t) / 0.07, 1)), 2)
                return sin(2 * .pi * frequency * t) * attack * release * exp(-9 * t)
            }
            let value = 0.38 * (note(740, start: 0, duration: 0.24)
                                + note(988, start: 0.085, duration: 0.24))
            var sample = Int16((value * Double(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append32(UInt32(36 + pcm.count))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        wav.append(contentsOf: "data".utf8)
        append32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }

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

/// Uses monotonic time so changing the Mac's clock cannot mute later messages.
struct ChatCueThrottle {
    private var lastPlayed: TimeInterval?

    mutating func shouldPlay(enabled: Bool, now: TimeInterval) -> Bool {
        guard enabled else { return false }
        if let lastPlayed, now - lastPlayed < 0.5 { return false }
        lastPlayed = now
        return true
    }
}
