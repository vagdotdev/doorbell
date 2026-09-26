import SwiftUI

/// Someone is outside. See them, hear them a little, accept — or don't.
struct PeepholeView: View {
    let visitor: Profile
    let geometry: NotchGeometry
    @EnvironmentObject private var door: DoorController
    @ObservedObject private var peep: MediaSession
    @ObservedObject private var room: RoomSession
    @AppStorage(SettingsKey.peepholeStyle) private var style: PeepholeStyle = .eyehole
    /// The knock lands as light on the doorstep, then lets go.
    @State private var flare = true
    @State private var rendering = false

    init(visitor: Profile, geometry: NotchGeometry, peep: MediaSession, room: RoomSession) {
        self.visitor = visitor
        self.geometry = geometry
        self.peep = peep
        self.room = room
    }

    var body: some View {
        DoorFrame(geometry: geometry, lit: door.listening || flare) {
            DoorTitle(name: visitor.displayName) {
                Text(door.isAdmitting ? "Opening…" : door.doorstepAudioStatus)
                    .contentTransition(.opacity)
            }
        } glass: {
            DoorGlass(style: style, emphasized: door.listening) {
                if AppConfig.current.isLive {
                    ZStack {
                        // Their face as they knocked holds the glass until a live frame is on screen.
                        if let still = door.visitorStill {
                            Image(nsImage: still)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 1.5)
                                .saturation(0.85)
                        } else {
                            Placeholder(profile: visitor)
                        }
                        if let track = peep.peers.first(where: { $0.id == visitor.handle })?.video {
                            LiveVideo(track: track, mirrored: false, isRendering: $rendering)
                                .opacity(rendering ? 1 : 0)
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: rendering)
                } else {
                    // Mock: the local camera stands in for the visitor.
                    CameraPreview(mirrored: false, fallback: visitor)
                }
            }
            .onChange(of: rendering) { _, now in if now { door.peepholeShowedVideo() } }
            .onChange(of: visitor.id) { _, _ in rendering = false }
        } controls: {
            HStack(spacing: 20) {
                RoundControl(symbol: "xmark", label: "Not Now") { door.dismissPeephole() }.disabled(door.isAdmitting)
                RoundControl(symbol: door.listening ? "speaker.wave.3.fill" : "speaker.wave.2",
                             label: door.listening ? "Listening" : "Listen",
                             active: door.listening) {
                    withAnimation(DesignTokens.spring) { door.toggleListening() }
                }
                if room.isActive {
                    RoundMenuControl(symbol: "checkmark",
                                     label: door.isAdmitting ? "Opening…" : "Let in",
                                     tint: DesignTokens.openDoor) {
                        Button("Add to this call") { door.openDoor(bringIn: .add) }
                            .disabled(room.isFull)
                        Button("End this call") { door.openDoor(bringIn: .end) }
                    }
                    .disabled(door.isAdmitting)
                    .help(room.isFull ? "This call is full. End it to let them in." : "Add them to this call, or end it and take the knock.")
                } else {
                    RoundControl(symbol: "checkmark", label: "Accept",
                                 tint: DesignTokens.openDoor) { door.openDoor() }
                        .disabled(door.isAdmitting)
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1400))
            flare = false
        }
    }
}
