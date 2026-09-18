@preconcurrency import AVFoundation
import LiveKit
import SwiftUI

/// One capture session shared by every preview on screen. Starts when the first
/// preview appears, stops when the last one goes — idle Doorbell never holds the camera.
/// Phase 3 replaces this with LiveKit's local video track; the previews stay.
@MainActor
final class CameraFeed: ObservableObject {
    static let shared = CameraFeed()

    enum Status: Equatable { case idle, starting, running, unavailable }
    @Published private(set) var status: Status = .idle

    let session = AVCaptureSession()
    private var refs = 0
    private var generation = 0
    private(set) var startTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "doorbell.camera")
    private let cameraAccess: @MainActor () async -> Bool
    private let captureStart: (@MainActor () async -> Bool)?
    private let captureStop: (@MainActor () -> Void)?

    init(cameraAccess: @escaping @MainActor () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .video)
    }, captureStart: (@MainActor () async -> Bool)? = nil,
         captureStop: (@MainActor () -> Void)? = nil) {
        self.cameraAccess = cameraAccess
        self.captureStart = captureStart
        self.captureStop = captureStop
    }

    func retain() {
        refs += 1
        guard refs == 1 else { return }
        generation += 1
        let ticket = generation
        status = .starting
        startTask = Task { await start(ticket: ticket) }
    }

    func release() {
        refs = max(0, refs - 1)
        guard refs == 0 else { return }
        generation += 1
        startTask?.cancel()
        if let captureStop { captureStop() }
        else {
            let session = self.session
            queue.async { session.stopRunning() }
        }
        status = .idle
    }

    private func start(ticket: Int) async {
        guard refs > 0, generation == ticket else { return }
        let allowed = await cameraAccess()
        // The permission sheet can outlive its preview. Its result must not start
        // capture, or change a newer preview's state, after the old one closes.
        guard refs > 0, generation == ticket else { return }
        guard allowed else {
            status = .unavailable
            return
        }
        let ok: Bool
        if let captureStart { ok = await captureStart() }
        else { ok = await startSession() }
        guard refs > 0, generation == ticket else { return }
        status = ok ? .running : .unavailable
    }

    private func startSession() async -> Bool {
        let session = self.session
        return await withCheckedContinuation { cont in
            queue.async {
                if session.inputs.isEmpty {
                    session.beginConfiguration()
                    session.sessionPreset = .medium
                    if let device = AVCaptureDevice.default(for: .video),
                       let input = try? AVCaptureDeviceInput(device: device),
                       session.canAddInput(input) {
                        session.addInput(input)
                    }
                    session.commitConfiguration()
                }
                guard !session.inputs.isEmpty else { return cont.resume(returning: false) }
                session.startRunning()
                cont.resume(returning: true)
            }
        }
    }
}

/// Live camera, or a quiet placeholder when there isn't one.
struct CameraPreview: View {
    var mirrored = true
    /// Shown when the camera is unavailable.
    var fallback: Profile?
    @ObservedObject private var feed = CameraFeed.shared

    var body: some View {
        ZStack {
            Color(white: 0.08)
            if let fallback, feed.status != .running {
                AvatarView(profile: fallback, size: 40)
            }
            PreviewLayerView(session: feed.session, mirrored: mirrored)
                .opacity(feed.status == .running ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.45), value: feed.status == .running)
        .onAppear { feed.retain() }
        .onDisappear { feed.release() }
    }
}

/// A LiveKit track in the glass or a tile. Fills, like the camera preview does.
struct LiveVideo: View {
    let track: VideoTrack
    var mirrored = false
    var fit = false

    var body: some View {
        // LiveKit's mirror flag is unreliable on macOS; flip the view instead.
        SwiftUIVideoView(track, layoutMode: fit ? .fit : .fill, mirrorMode: .off)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .background(Color(white: 0.08))
    }
}

/// Someone whose picture hasn't arrived (or is off): their portrait, quietly.
struct Placeholder: View {
    let profile: Profile

    var body: some View {
        ZStack {
            Color(white: 0.08)
            AvatarView(profile: profile, size: 56)
        }
    }
}

private struct PreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.frame = view.bounds
        guard let layer = view.layer as? AVCaptureVideoPreviewLayer,
              let connection = layer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
