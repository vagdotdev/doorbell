import SwiftUI

/// Black, clean, quiet. Tiles, a strip of controls, a chat drawer.
struct RoomView: View {
    @EnvironmentObject private var room: RoomSession
    @EnvironmentObject private var door: DoorController

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TileGrid(participants: room.participants)
                    .padding(.horizontal, 16)
                    .padding(.top, 44)   // room for the traffic lights + title
                ControlBar()
                    .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity)

            if room.chatOpen {
                ChatDrawer()
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(RoomBackdrop())
        .overlay(alignment: .topLeading) {
            Text(room.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.inkSecondary)
                .padding(.leading, 82)
                .padding(.top, 12)
        }
        .overlay(alignment: .topTrailing) {
            // Someone knocked while we're talking. Same choice as the notch, here too.
            if let visitor = door.visitor {
                AtTheDoor(visitor: visitor)
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: room.chatOpen)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: door.visitor)
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// A knock, seen from inside the room: who, and let them in or not.
private struct AtTheDoor: View {
    let visitor: Profile
    @EnvironmentObject private var door: DoorController

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(profile: visitor, size: 24)
            Text("\(visitor.displayName) is at the door")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
            PillButton(title: "Not Now") { door.dismissPeephole() }
            PillButton(title: "Let In", prominent: true) { door.openDoor() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(Capsule().fill(.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(DesignTokens.hairline, lineWidth: 1))
    }
}

/// Black with a floor: the light pools low and behind the tiles, the way a dark
/// room is lit from one lamp, and the dust gives the black depth.
private struct RoomBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [DesignTokens.roomFloor, .black],
                center: .init(x: 0.5, y: 0.62), startRadius: 0, endRadius: 720
            )
            Starfield(intensity: 0.8, seed: 5)
            Doorstep(rise: 118)
                .opacity(0.7)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Tiles

private struct TileGrid: View {
    let participants: [RoomParticipant]

    private var columns: Int {
        switch participants.count {
        case 0...1: 1
        case 2...4: 2
        default: 3
        }
    }

    var body: some View {
        GeometryReader { geo in
            let n = max(participants.count, 1)
            let cols = columns
            let rows = Int(ceil(Double(n) / Double(cols)))
            let spacing: CGFloat = 12
            let w = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            // Keep tiles no wider than 16:9 so a lone tile doesn't stretch into a banner.
            let tileW = min(w, h * 16 / 9)
            let gridW = tileW * CGFloat(cols) + spacing * CGFloat(cols - 1)

            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(rowItems(r, cols: cols)) { p in
                            ParticipantTile(participant: p)
                                .frame(width: tileW, height: h)
                        }
                    }
                }
            }
            .frame(width: gridW, height: geo.size.height)
            .frame(maxWidth: .infinity)
        }
    }

    private func rowItems(_ row: Int, cols: Int) -> [RoomParticipant] {
        let start = row * cols
        let end = min(start + cols, participants.count)
        return start < end ? Array(participants[start..<end]) : []
    }
}

private struct ParticipantTile: View {
    let participant: RoomParticipant
    @EnvironmentObject private var room: RoomSession

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            shape.fill(Color(white: 0.09))
            if let track = participant.video, participant.camOn || !participant.isLocal {
                LiveVideo(track: track, mirrored: participant.isLocal)
            } else if participant.camOn && participant.isLocal && !AppConfig.current.useSupabase {
                // Mock: no seat, so the local camera stands in.
                CameraPreview(mirrored: true, fallback: participant.profile)
            } else {
                AvatarView(profile: participant.profile, size: 88)
            }
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(participant.isSpeaking ? .white.opacity(0.45) : DesignTokens.hairline,
                               lineWidth: 1)
        )
        .shadow(color: .white.opacity(participant.isSpeaking ? 0.28 : 0), radius: 10)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if !participant.micOn {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Text(participant.isLocal ? "You" : participant.profile.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                if let via = participant.via {
                    Text("· friend of \(via)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(12)
        }
    }
}

// MARK: - Controls

private struct ControlBar: View {
    @EnvironmentObject private var room: RoomSession

    var body: some View {
        HStack(spacing: 10) {
            RoomControl(symbol: room.micOn ? "mic.fill" : "mic.slash.fill",
                        tint: room.micOn ? .neutral : .off) { room.micOn.toggle() }
            RoomControl(symbol: room.camOn ? "video.fill" : "video.slash.fill",
                        tint: room.camOn ? .neutral : .off) { room.camOn.toggle() }
            RoomControl(symbol: "rectangle.on.rectangle",
                        tint: room.sharing ? .active : .neutral) { room.sharing.toggle() }
            RoomControl(symbol: "bubble.left.fill",
                        tint: room.chatOpen ? .active : .neutral, badge: room.unread) { room.toggleChat() }
            RoomControl(symbol: "phone.down.fill", tint: .leave, wide: true) {
                NSApp.keyWindow?.close()
            }
        }
    }
}

private struct RoomControl: View {
    enum Tint { case neutral, off, active, leave }

    let symbol: String
    let tint: Tint
    var badge = 0
    var wide = false
    let action: () -> Void
    @State private var hovering = false

    private var fill: Color {
        switch tint {
        case .neutral: hovering ? .white.opacity(0.16) : .white.opacity(0.10)
        case .off: Color(red: 0.92, green: 0.30, blue: 0.30)
        case .active: DesignTokens.utility
        case .leave: Color(red: 0.86, green: 0.22, blue: 0.24).opacity(hovering ? 1 : 0.9)
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint == .active ? .black : .white)
                .frame(width: wide ? 64 : 44, height: 44)
                .background(Capsule().fill(fill))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Circle().fill(DesignTokens.social))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Chat

private struct ChatDrawer: View {
    @EnvironmentObject private var room: RoomSession
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
                .padding(.horizontal, 16)
                .padding(.top, 46)
                .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(room.chat) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(m.from.id == room.me?.id ? "You" : m.from.displayName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(DesignTokens.inkSecondary)
                                    Text(m.at, style: .time)
                                        .font(.system(size: 10))
                                        .foregroundStyle(DesignTokens.inkTertiary)
                                }
                                Text(m.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(DesignTokens.ink)
                                    .textSelection(.enabled)
                            }
                            .id(m.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .onChange(of: room.chat.count) { _, _ in
                    if let last = room.chat.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(draft.isEmpty ? DesignTokens.inkTertiary : DesignTokens.utility))
                }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DesignTokens.raised))
            .padding(12)
        }
        .background(Color(white: 0.05))
        .overlay(alignment: .leading) { Rectangle().fill(DesignTokens.hairline).frame(width: 1) }
    }

    private func send() {
        room.send(draft)
        draft = ""
    }
}
