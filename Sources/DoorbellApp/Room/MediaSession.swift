import AVFoundation
import Combine
import Foundation
import LiveKit

/// One serialized LiveKit seat. Every queued operation belongs to a generation;
/// leaving invalidates that generation before waiting for the SDK to finish.
@MainActor
class MediaSession: ObservableObject {
    enum Phase: Equatable { case idle, connecting, connected, reconnecting, failed }
    struct Peer: Identifiable, Equatable {
        let id: String
        let name: String
        let via: String?
        let video: VideoTrack?
        let screen: VideoTrack?
        let micOn: Bool
        let camOn: Bool
        let isSpeaking: Bool
        static func == (a: Peer, b: Peer) -> Bool {
            a.id == b.id && a.name == b.name && a.via == b.via && a.video === b.video
                && a.screen === b.screen && a.micOn == b.micOn && a.camOn == b.camOn && a.isSpeaking == b.isSpeaking
        }
    }
    struct ShareSource: Identifiable {
        let id: String
        let title: String
        let isDisplay: Bool
        let source: MacOSScreenCaptureSource
    }

    @Published var peers: [Peer] = []
    @Published var localVideo: VideoTrack?
    @Published var localScreen: VideoTrack?
    @Published var phase: Phase = .idle
    @Published var micOn = false
    @Published var camOn = false
    @Published var sharing = false
    @Published var problem: String?
    @Published var isUpdating = false
    var isConnected: Bool { phase == .connected }
    var volumeScale: Double = 1 { didSet { applyVolume(playbackGain) } }
    private(set) var playbackGain: Double = 0
    private var playbackRamp: Task<Void, Never>?
    var onData: ((Data, String, String?) -> Void)?

    private let room = Room(roomOptions: RoomOptions(
        defaultAudioCaptureOptions: AudioCaptureOptions(
            echoCancellation: true, autoGainControl: true, noiseSuppression: true, highpassFilter: true
        )
    ))
    private var inflight: Task<Void, Error>?
    private let generation = OperationGeneration()
    private let microphoneIntent = OperationGeneration()
    private var wantsConnection = false
    private var screenPublication: LocalTrackPublication?
    private var updateCount = 0
    private let microphoneAccess: @MainActor () async -> Bool
    private let microphonePrivacySetup: @MainActor () throws -> Void
    private let microphoneControl: (@MainActor (Bool) async throws -> Void)?

    init(
        microphoneAccess: @escaping @MainActor () async -> Bool = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        },
        microphoneControl: (@MainActor (Bool) async throws -> Void)? = nil,
        microphonePrivacySetup: (@MainActor () throws -> Void)? = nil
    ) {
        self.microphoneAccess = microphoneAccess
        self.microphoneControl = microphoneControl
        let privacySetup = microphonePrivacySetup ?? {
            if microphoneControl == nil { try Self.configureMicrophonePrivacy() }
        }
        self.microphonePrivacySetup = privacySetup
        do { try privacySetup() }
        catch { problem = MicrophoneFailure.privacyConfiguration.message }
        room.add(delegate: self)
    }

    /// Each seat owns its envelope. Raising a doorstep must never lower the
    /// foreground conversation, and cancelling one visit cannot mute another.
    func fadePlayback(to target: Double, duration: TimeInterval = 0.2) {
        playbackRamp?.cancel()
        let target = target.isFinite ? min(1, max(0, target)) : 0
        guard duration.isFinite, duration > 0 else {
            playbackGain = target
            applyVolume(target)
            return
        }
        let from = playbackGain
        let steps = max(1, Int(min(duration, 10) * 60))
        playbackRamp = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(min(duration, 10) / Double(steps)))
                guard !Task.isCancelled, let self else { return }
                let fraction = Double(step) / Double(steps)
                let eased = 0.5 - 0.5 * cos(fraction * .pi)
                playbackGain = from + (target - from) * eased
                applyVolume(playbackGain)
            }
        }
    }

    func connect(_ grant: MediaGrant, microphone: Bool, camera: Bool) async throws {
        let ticket = generation.advance()
        let micTicket = microphoneIntent.advance()
        wantsConnection = true
        phase = .connecting
        problem = nil
        try await enqueue { [self] in
            try generation.check(ticket)
            if room.connectionState != .disconnected { await room.disconnect() }
            do {
                try generation.check(ticket)
                try await room.connect(url: grant.url, token: grant.token)
                try generation.check(ticket)
                if microphone {
                    do { try await changeMicrophone(true, intent: micTicket, allowWhileConnecting: true) }
                    catch is CancellationError { /* A newer mute or connection state wins. */ }
                    catch { problem = microphoneFailureMessage(error) }
                    try generation.check(ticket)
                }
                if camera {
                    do { _ = try await room.localParticipant.setCamera(enabled: true) }
                    catch { if problem == nil { problem = "Camera unavailable. You can keep talking without video." } }
                    try generation.check(ticket)
                }
                phase = .connected
                refresh()
            } catch {
                await room.disconnect()
                if generation.isCurrent(ticket) {
                    wantsConnection = false
                    clearTracks()
                    phase = .failed
                    problem = "Couldn’t connect. Check your internet connection and try again."
                }
                throw error
            }
        }
    }

    func disconnect() async {
        _ = generation.advance()
        microphoneIntent.advance()
        wantsConnection = false
        fadePlayback(to: 0, duration: 0)
        phase = .idle
        clearTracks()
        _ = try? await enqueue { [self] in
            await room.disconnect()
            screenPublication = nil
        }
    }

    func setMicrophone(_ on: Bool) async {
        guard isConnected || (!on && (phase == .reconnecting || phase == .connecting)) else { return }
        // Record intent before queueing behind a permission prompt or SDK work.
        // A newer mute must invalidate an unmute before it starts capture.
        let intent = microphoneIntent.advance()
        // A mute requested during camera/device work must not be discarded.
        // The same generation queue also prevents delayed unmute after leaving.
        await update("Microphone unavailable. Choose an input in the call’s device menu.",
                     allowWhileUpdating: true, allowDuringConnection: !on) { [self] in
            try await changeMicrophone(on, intent: intent)
        }
    }
    func setCamera(_ on: Bool) async {
        await update("Couldn’t change the camera. Check macOS permissions.") { [self] in
            _ = try await room.localParticipant.setCamera(enabled: on)
        }
    }
    func setCameraDevice(_ device: AVCaptureDevice) async {
        await update("That camera is unavailable. Choose another camera.") { [self] in
            guard let capturer = (room.localParticipant.firstCameraVideoTrack as? LocalVideoTrack)?.capturer as? CameraCapturer else {
                throw MediaFailure.unavailable
            }
            _ = try await capturer.set(options: CameraCaptureOptions(device: device))
        }
    }

    func shareSources() async throws -> [ShareSource] {
        let sources = try await MacOSScreenCapturer.sources(for: .any)
        return sources.compactMap { source in
            if let display = source as? MacOSDisplay {
                return ShareSource(id: "display:\(display.displayID)", title: "Display · \(display.width) × \(display.height)", isDisplay: true, source: source)
            }
            if let window = source as? MacOSWindow {
                let app = window.owningApplication?.applicationName ?? "Window"
                return ShareSource(id: "window:\(window.windowID)", title: "\(app) · \(window.title ?? "Untitled")", isDisplay: false, source: source)
            }
            return nil
        }
    }

    func startScreenShare(_ source: ShareSource) async {
        await update("Couldn’t share that window. Check Screen Recording permission, then try again.") { [self] in
            if let screenPublication { try await room.localParticipant.unpublish(publication: screenPublication) }
            // LiveKit's source descriptors contain immutable ScreenCaptureKit metadata.
            // Its async factory transfers the descriptor to the RTC executor.
            nonisolated(unsafe) let captureSource = source.source
            let track = await LocalVideoTrack.createMacOSScreenShareTrack(source: captureSource,
                options: ScreenShareCaptureOptions(fps: 15, appAudio: false))
            track.capturer.delegates.add(delegate: self)
            do { screenPublication = try await room.localParticipant.publish(videoTrack: track) }
            catch { try? await track.stop(); throw error }
        }
    }
    func stopScreenShare() async {
        await update("Couldn’t stop sharing. Leave the room to stop all media.") { [self] in
            if let publication = screenPublication { try await room.localParticipant.unpublish(publication: publication) }
            else { _ = try await room.localParticipant.setScreenShare(enabled: false) }
            screenPublication = nil
        }
    }
    func send(_ data: Data, topic: String) async throws {
        guard isConnected, data.count <= 4_000 else { throw MediaFailure.unavailable }
        try await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: topic, reliable: true))
    }

    private func enqueue(_ body: @escaping @MainActor () async throws -> Void) async throws {
        let previous = inflight
        let task = Task { _ = try? await previous?.value; try await body() }
        inflight = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func update(_ message: String, allowWhileUpdating: Bool = false,
                        allowDuringConnection: Bool = false,
                        action: @escaping @MainActor () async throws -> Void) async {
        // A connection interruption must not discard a privacy mute: the SDK
        // retains local tracks while reconnecting and can resume publishing them.
        guard isConnected || (allowDuringConnection && (phase == .reconnecting || phase == .connecting)),
              allowWhileUpdating || !isUpdating else { return }
        updateCount += 1
        isUpdating = true
        let ticket = generation.current
        defer { updateCount -= 1; isUpdating = updateCount > 0 }
        do {
            try await enqueue { [self] in
                try generation.check(ticket)
                try await action()
                try generation.check(ticket)
            }
            if generation.isCurrent(ticket) { problem = nil; refresh() }
        } catch is CancellationError {
            // A newer request or lifecycle change superseded this operation.
        } catch {
            if generation.isCurrent(ticket) { problem = (error as? MicrophoneFailure)?.message ?? message; refresh() }
        }
    }
    private func changeMicrophone(_ on: Bool, intent: UInt64, allowWhileConnecting: Bool = false) async throws {
        let ticket = generation.current
        try microphoneIntent.check(intent)
        if on {
            // Retry configuration if an earlier audio-device initialization failed.
            // Never publish capture with a mute mode that leaves mic input running.
            do { try microphonePrivacySetup() }
            catch { throw MicrophoneFailure.privacyConfiguration }
            let allowed = await microphoneAccess()
            try generation.check(ticket)
            try microphoneIntent.check(intent)
            guard isConnected || (allowWhileConnecting && phase == .connecting) else { throw CancellationError() }
            guard allowed else { throw MicrophoneFailure.permissionDenied }
            if microphoneControl == nil {
                let manager = AudioManager.shared
                guard !manager.inputDevices.isEmpty else { throw MicrophoneFailure.noInput }
                // A disconnected USB headset/AirPods selection can outlive the device.
                // Preserve a valid explicit choice; otherwise follow the system input.
                if !manager.inputDevice.isDefault,
                   !manager.inputDevices.contains(where: { $0.deviceId == manager.inputDevice.deviceId }) {
                    manager.inputDevice = manager.defaultInputDevice
                }
            }
        }
        if let microphoneControl { try await microphoneControl(on) }
        else { _ = try await room.localParticipant.setMicrophone(enabled: on) }
    }

    private static func configureMicrophonePrivacy() throws {
        let manager = AudioManager.shared
        if manager.microphoneMuteMode != .restart {
            try manager.set(microphoneMuteMode: .restart)
        }
        guard manager.microphoneMuteMode == .restart else { throw MicrophoneFailure.privacyConfiguration }
        // This changes only the shared engine's policy when its mic becomes muted.
        // Each seat still mutes its own track. Never call stopLocalRecording(),
        // setEngineAvailability(), or global isMicrophoneMuted here: those would
        // interrupt another seat's foreground conversation.
    }

    private func microphoneFailureMessage(_ error: Error) -> String {
        (error as? MicrophoneFailure)?.message ?? "Microphone unavailable. Choose an input in the call’s device menu."
    }

    private enum MicrophoneFailure: Error {
        case permissionDenied, noInput, privacyConfiguration
        var message: String {
            switch self {
            case .permissionDenied: "Allow Doorbell in System Settings → Privacy & Security → Microphone, then turn your mic on again."
            case .noInput: "No microphone found. Connect a microphone, then turn your mic on again."
            case .privacyConfiguration: "Microphone couldn’t start safely. Turn your mic on again to retry."
            }
        }
    }

    private func clearTracks() {
        peers = []; localVideo = nil; localScreen = nil
        micOn = false; camOn = false; sharing = false
    }
    private func refresh() {
        guard wantsConnection else { return }
        let local = room.localParticipant
        localVideo = local.firstCameraVideoTrack
        let screen = local.firstScreenShareVideoTrack as? LocalVideoTrack
        localScreen = screen?.capturer.captureState == .started ? screen : nil
        micOn = local.isMicrophoneEnabled()
        camOn = local.isCameraEnabled()
        sharing = localScreen != nil && local.isScreenShareEnabled()
        peers = room.remoteParticipants.values.map(Self.peer).sorted { $0.id < $1.id }
        applyVolume(playbackGain)
    }
    private func applyVolume(_ gain: Double) {
        for participant in room.remoteParticipants.values {
            for pub in participant.audioTracks { (pub.track as? RemoteAudioTrack)?.volume = gain * volumeScale }
        }
    }
    private static func peer(_ p: RemoteParticipant) -> Peer {
        let meta = p.metadata.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        let id = p.identity?.stringValue ?? ""
        return Peer(id: id, name: p.name?.isEmpty == false ? p.name! : (meta?.displayName ?? id), via: meta?.via,
                    video: p.firstCameraVideoTrack, screen: p.firstScreenShareVideoTrack,
                    micOn: p.isMicrophoneEnabled(), camOn: p.isCameraEnabled(), isSpeaking: p.isSpeaking)
    }
    private struct Meta: Decodable {
        let displayName: String?
        let via: String?
        enum CodingKeys: String, CodingKey { case via, displayName = "display_name" }
    }
    enum MediaFailure: Error { case unavailable }
}

extension MediaSession: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) { Task { @MainActor in refresh() } }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) { Task { @MainActor in refresh() } }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) { Task { @MainActor in refresh() } }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) { Task { @MainActor in refresh() } }
    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) { Task { @MainActor in refresh() } }
    nonisolated func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) { Task { @MainActor in refresh() } }
    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) { Task { @MainActor in refresh() } }
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) { Task { @MainActor in refresh() } }
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard data.count <= 4_000 else { return }
        let from = participant?.identity?.stringValue
        Task { @MainActor in onData?(data, topic, from) }
    }
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            guard wantsConnection, connectionState == room.connectionState else { return }
            if connectionState == .reconnecting { phase = .reconnecting }
            if connectionState == .connected { phase = .connected; refresh() }
        }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard wantsConnection, room.connectionState == .disconnected else { return }
            wantsConnection = false
            clearTracks()
            phase = .failed
            problem = "Connection lost. Leave and knock again when you’re back online."
        }
    }
}

extension MediaSession: VideoCapturerDelegate {
    nonisolated func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.CapturerState) {
        Task { @MainActor in
            guard state == .stopped,
                  let track = screenPublication?.track as? LocalVideoTrack,
                  track.capturer === capturer, !isUpdating else { return }
            await stopScreenShare()
        }
    }
}
