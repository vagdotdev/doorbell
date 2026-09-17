import SwiftUI

/// Do not disturb. Someone is at the door and the notch has grown just enough to
/// show their face, small and silent — something happening two rooms away. No
/// name, no buttons. Click it to look properly.
struct PinholeView: View {
    let visitor: Profile
    let geometry: NotchGeometry
    @EnvironmentObject private var door: DoorController
    @ObservedObject private var peep: MediaSession
    @State private var hovering = false

    init(visitor: Profile, geometry: NotchGeometry, peep: MediaSession) {
        self.visitor = visitor
        self.geometry = geometry
        self.peep = peep
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: geometry.notchHeight)
            ZStack {
                if let track = peep.peers.first?.video {
                    LiveVideo(track: track, mirrored: false)
                } else {
                    AvatarView(profile: visitor, size: DesignTokens.pinholeFace)
                }
            }
            .frame(width: DesignTokens.pinholeFace, height: DesignTokens.pinholeFace)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(hovering ? 0.35 : 0.14), lineWidth: 1))
            .frame(maxHeight: .infinity)
        }
        .frame(width: geometry.notchWidth, height: geometry.pinholeSize.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { door.answerPinhole() }
    }
}
