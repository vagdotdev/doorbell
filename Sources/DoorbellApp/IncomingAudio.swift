import SwiftUI

/// Incoming voice never cuts. Gain eases in and out on a raised-cosine.
/// This does not play anything on its own — it only ramps the level that a
/// real track (LiveKit, Phase 3) should be multiplied by.
@MainActor
final class IncomingAudio: ObservableObject {
    static let shared = IncomingAudio()

    /// 0…1. Bind a remote track's volume to this.
    @Published private(set) var gain: Float = 0

    private var ramp: Task<Void, Never>?

    private init() {}

    /// Someone starts talking. `muffled` is the peephole (door volume).
    func arrive(muffled: Bool) {
        ramp(to: muffled ? DesignTokens.doorVolume : 1,
             duration: muffled ? DesignTokens.audioArrive : DesignTokens.audioEnter)
    }

    func setListening(_ on: Bool) {
        ramp(to: on ? 1 : DesignTokens.doorVolume, duration: DesignTokens.audioListen)
    }

    func depart() {
        ramp(to: 0, duration: DesignTokens.audioDepart)
    }

    private func ramp(to target: Float, duration: TimeInterval) {
        ramp?.cancel()
        let from = gain
        let steps = max(1, Int(duration * 60))
        ramp = Task { [weak self] in
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                guard !Task.isCancelled, let self else { return }
                let t = Float(i) / Float(steps)
                let eased = 0.5 - 0.5 * cos(t * .pi)
                self.gain = from + (target - from) * eased
            }
        }
    }
}
