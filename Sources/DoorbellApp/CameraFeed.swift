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
    private let queue = DispatchQueue(label: "doorbell.camera")

    private init() {}

    func retain() {
        refs += 1
        guard refs == 1 else { return }
        status = .starting
        Task { await start() }
    }

    func release() {
        refs = max(0, refs - 1)
        guard refs == 0 else { return }
        let session = self.session
        queue.async { session.stopRunning() }
        status = .idle
    }

    private func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = .unavailable
            return
        }
        let session = self.session
        let ok: Bool = await withCheckedContinuation { cont in
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
        guard refs > 0 else { return }
        status = ok ? .running : .unavailable
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

    var body: some View {
        SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: mirrored ? .mirror : .off)
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
    }
}
