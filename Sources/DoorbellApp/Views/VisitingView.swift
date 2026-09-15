import SwiftUI

/// I'm at their door. They can see and hear me; I see myself as they do.
struct VisitingView: View {
    let door: Door
    let geometry: NotchGeometry
    @EnvironmentObject private var controller: DoorController
    @ObservedObject private var media: MediaSession
    @AppStorage(SettingsKey.peepholeStyle) private var style: PeepholeStyle = .eyehole

    init(door: Door, geometry: NotchGeometry, media: MediaSession) {
        self.door = door
        self.geometry = geometry
        self.media = media
    }

    var body: some View {
        DoorFrame(geometry: geometry) {
            DoorTitle(name: "\(firstName)’s door") {
                HStack(spacing: 6) {
                    KnockingDots()
                    Text("They can see and hear you")
                }
            }
        } glass: {
            DoorGlass(style: style) {
                if let track = media.localVideo {
                    LiveVideo(track: track, mirrored: true)
                } else if AppConfig.current.useSupabase {
                    // The seat's own capturer owns the camera; a preview would fight it.
                    Color(white: 0.08)
                } else {
                    CameraPreview(mirrored: true)
                }
            }
        } controls: {
            RoundControl(symbol: "xmark", label: "Leave") { controller.leaveVisit() }
        }
    }

    private var firstName: String {
        door.profile.displayName.split(separator: " ").first.map(String.init) ?? door.profile.handle
    }
}

/// Three dots breathing: you're waiting, and that's fine.
private struct KnockingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(DesignTokens.social.opacity(phase == i ? 0.95 : 0.3))
                    .frame(width: 4, height: 4)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(420))
                withAnimation(.easeInOut(duration: 0.3)) { phase = (phase + 1) % 3 }
            }
        }
    }
}
