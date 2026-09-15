import Combine
import Foundation
import LiveKit

/// One seat in one LiveKit room. Publishes what you allow, mirrors who else is there,
/// and plays their voices at whatever level `IncomingAudio` says — door volume through
/// the peephole, full once you're in. Nothing is recorded; nothing is stored.
@MainActor
final class MediaSession: ObservableObject {
    struct Peer: Identifiable, Equatable {
        let id: String           // LiveKit identity = handle
        let name: String
        let via: String?
        let video: VideoTrack?
        let micOn: Bool
        let camOn: Bool
        let isSpeaking: Bool

        static func == (a: Peer, b: Peer) -> Bool {
            a.id == b.id && a.name == b.name && a.video === b.video
                && a.micOn == b.micOn && a.camOn == b.camOn && a.isSpeaking == b.isSpeaking
        }
    }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var localVideo: VideoTrack?
    @Published private(set) var isConnected = false
    /// This seat's share of `IncomingAudio.gain`. 0 keeps a doorstep silent while a
    /// room is already talking.
    var volumeScale: Double = 1 { didSet { applyVolume(Double(IncomingAudio.shared.gain)) } }

    /// A reliable data message on a topic, with the sender's identity.
    var onData: ((Data, String, String?) -> Void)?

    // Every seat's microphone is cleaned the same way — the knocker on the doorstep as
    // much as anyone in the room. Apple's voice processing where the platform has it,
    // WebRTC's otherwise; the high-pass takes fan and room rumble off the bottom.
    // See docs/audio.md for what this does and doesn't cover.
    private let room = Room(roomOptions: RoomOptions(
        defaultAudioCaptureOptions: AudioCaptureOptions(
            echoCancellation: true, autoGainControl: true, noiseSuppression: true, highpassFilter: true
        )
    ))
    private var gainSink: AnyCancellable?
    /// One Room, one thing at a time. A seat trade (doorstep → room) can arrive while
    /// the first seat's camera is still coming up; the SDK does not like a disconnect
    /// landing in the middle of that, so connects and disconnects queue.
    private var inflight: Task<Void, Error>?

    init() {
        room.add(delegate: self)
        gainSink = IncomingAudio.shared.$gain.sink { [weak self] gain in
            self?.applyVolume(Double(gain))
        }
    }

    func connect(_ grant: MediaGrant, microphone: Bool, camera: Bool) async throws {
        let previous = inflight
        let task = Task { [self] in
            _ = try? await previous?.value
            if room.connectionState != .disconnected { await room.disconnect() }
            do {
                try await room.connect(url: grant.url, token: grant.token)
            } catch {
                NSLog("media: connect failed: \(error)")
                throw error
            }
            isConnected = true
            // Voice first (fast); the picture follows a beat later.
            if microphone {
                do { try await room.localParticipant.setMicrophone(enabled: true) }
                catch { NSLog("media: microphone: \(error)") }
            }
            if camera {
                do { try await room.localParticipant.setCamera(enabled: true) }
                catch { NSLog("media: camera: \(error)") }
            }
            refresh()
        }
        inflight = task
        try await task.value
    }

    func disconnect() async {
        let previous = inflight
        let task = Task<Void, Error> { [self] in
            _ = try? await previous?.value
            guard isConnected || room.connectionState != .disconnected else { return }
            await room.disconnect()
            isConnected = false
            peers = []
            localVideo = nil
        }
        inflight = task
        _ = try? await task.value
    }

    func setMicrophone(_ on: Bool) async {
        try? await room.localParticipant.setMicrophone(enabled: on)
        refresh()
    }

    func setCamera(_ on: Bool) async {
        try? await room.localParticipant.setCamera(enabled: on)
        refresh()
    }

    func setScreenShare(_ on: Bool) async {
        try? await room.localParticipant.setScreenShare(enabled: on)
        refresh()
    }

    func send(_ data: Data, topic: String) async {
        try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: topic, reliable: true))
    }

    // MARK: -

    private func refresh() {
        let local = room.localParticipant
        localVideo = local.firstCameraVideoTrack
        peers = room.remoteParticipants.values
            .map { Self.peer(from: $0) }
            .sorted { $0.id < $1.id }
        applyVolume(Double(IncomingAudio.shared.gain))
    }

    private func applyVolume(_ gain: Double) {
        for participant in room.remoteParticipants.values {
            for pub in participant.audioTracks {
                (pub.track as? RemoteAudioTrack)?.volume = gain * volumeScale
            }
        }
    }

    private static func peer(from p: RemoteParticipant) -> Peer {
        let meta = p.metadata.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        let id = p.identity?.stringValue ?? ""
        return Peer(id: id,
                    name: p.name?.isEmpty == false ? p.name! : (meta?.displayName ?? id),
                    via: meta?.via,
                    video: p.firstScreenShareVideoTrack ?? p.firstCameraVideoTrack,
                    micOn: p.isMicrophoneEnabled(),
                    camOn: p.isCameraEnabled(),
                    isSpeaking: p.isSpeaking)
    }

    private struct Meta: Decodable {
        let handle: String?
        let displayName: String?
        let via: String?
        enum CodingKeys: String, CodingKey { case handle, via, displayName = "display_name" }
    }
}

extension MediaSession: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in refresh() }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in refresh() }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in refresh() }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in refresh() }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        Task { @MainActor in refresh() }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        Task { @MainActor in refresh() }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor in refresh() }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor in refresh() }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let from = participant?.identity?.stringValue
        Task { @MainActor in onData?(data, topic, from) }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            isConnected = false
            peers = []
            localVideo = nil
        }
    }
}
