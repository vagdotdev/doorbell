import SwiftUI

/// Someone is outside. See them, hear them a little, accept — or don't.
struct PeepholeView: View {
    let visitor: Profile
    let geometry: NotchGeometry
    @EnvironmentObject private var door: DoorController
    @ObservedObject private var peep: MediaSession
    @AppStorage(SettingsKey.peepholeStyle) private var style: PeepholeStyle = .eyehole
    /// The knock lands as light on the doorstep, then lets go.
    @State private var flare = true

    init(visitor: Profile, geometry: NotchGeometry, peep: MediaSession) {
        self.visitor = visitor
        self.geometry = geometry
        self.peep = peep
    }

    var body: some View {
        DoorFrame(geometry: geometry, lit: door.listening || flare) {
            DoorTitle(name: visitor.displayName) {
                Text(door.listening ? "Listening" : "Knocking")
                    .contentTransition(.opacity)
            }
        } glass: {
            DoorGlass(style: style, emphasized: door.listening) {
                if let track = peep.peers.first(where: { $0.id == visitor.handle })?.video {
                    LiveVideo(track: track, mirrored: false)
                } else if AppConfig.current.isLive {
                    Placeholder(profile: visitor)
                } else {
                    // Mock: the local camera stands in for the visitor.
                    CameraPreview(mirrored: false, fallback: visitor)
                }
            }
        } controls: {
            HStack(spacing: 20) {
                RoundControl(symbol: "xmark", label: "Not Now") { door.dismissPeephole() }.disabled(door.isAdmitting)
                RoundControl(symbol: door.listening ? "speaker.wave.3.fill" : "speaker.wave.2",
                             label: door.listening ? "Listening" : "Listen",
                             active: door.listening) {
                    withAnimation(DesignTokens.spring) { door.toggleListening() }
                }
                // In a room already: they join it. Otherwise they come into yours.
                RoundControl(symbol: "checkmark", label: "Accept",
                             tint: DesignTokens.openDoor) { door.openDoor() }
                    .disabled(door.isAdmitting)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1400))
            flare = false
        }
    }
}
