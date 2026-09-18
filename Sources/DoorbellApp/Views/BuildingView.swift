import SwiftUI

/// A row of doors. Yours first, then everyone you follow, then a way to find more.
struct BuildingView: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var hallway: HallwayStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                if let me = hallway.me {
                    OwnDoorCard(me: me, requests: hallway.requests.count) {
                        state.mode = .requests
                    }
                }
                ForEach(hallway.doors) { door in
                    DoorCard(door: door)
                }
                AddDoorCard { state.mode = .search }
            }
            .padding(.horizontal, 22)
        }
        .scrollClipDisabled()
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Cards

private let avatarSize: CGFloat = 54
private let cardWidth: CGFloat = 76

private struct DoorCard: View {
    let door: Door
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var controller: DoorController
    @State private var hovering = false

    var body: some View {
        Button {
            controller.visit(door)
        } label: {
            VStack(spacing: 7) {
                AvatarView(profile: door.profile, size: avatarSize)
                    .overlay {
                        if door.isCloseFriend {
                            Circle()
                                .strokeBorder(DesignTokens.openDoor, lineWidth: 2)
                                .padding(-4)
                        }
                    }
                    .buildingAvatar(door.profile.id)
                VStack(spacing: 1) {
                    Text(firstName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.ink)
                    Text("@\(door.profile.handle)")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.inkTertiary)
                }
                .lineLimit(1)
            }
            .frame(width: cardWidth)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(DesignTokens.spring, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Toggle("Allow walk-ins", isOn: Binding(
                get: { door.isCloseFriend },
                set: { hallway.setCloseFriend(door.profile, $0) }
            ))
            .tint(DesignTokens.openDoor)
            .disabled(!door.followsMe)
            Text("Friends knock. Close friends just get in.")
            if !door.followsMe {
                Text("Available once you're friends")
            }
            if door.followsMe {
                Button("Remove Follower", role: .destructive) { hallway.removeFollower(door.profile) }
            }
            Divider()
            Button("Remove Friend", role: .destructive) {
                hallway.unfollow(door.profile)
            }
            #if DEBUG
            Divider()
            Button("Simulate: they knock") { controller.simulate(.knock(door.profile)) }
            Button("Simulate: they walk in") { controller.simulate(.walkIn(door.profile)) }
            #endif
        }
    }

    private var firstName: String {
        door.profile.displayName.split(separator: " ").first.map(String.init) ?? door.profile.handle
    }
}

private struct OwnDoorCard: View {
    let me: Profile
    let requests: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                AvatarView(profile: me, size: avatarSize)
                    .overlay(alignment: .topTrailing) {
                        if requests > 0 {
                            Text("\(requests)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Circle().fill(DesignTokens.social))
                                .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                                .offset(x: 4, y: -3)
                        }
                    }
                    .buildingAvatar(me.id)
                VStack(spacing: 1) {
                    Text("You")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.ink)
                    Text("@\(me.handle)")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.inkTertiary)
                }
                .lineLimit(1)
            }
            .frame(width: cardWidth)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(DesignTokens.spring, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct AddDoorCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .foregroundStyle(hovering ? DesignTokens.inkSecondary : DesignTokens.hairline)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(hovering ? DesignTokens.ink : DesignTokens.inkSecondary)
                }
                .frame(width: avatarSize, height: avatarSize)
                VStack(spacing: 1) {
                    Text("Add")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.inkSecondary)
                    Text(" ").font(.system(size: 10))
                }
            }
            .frame(width: cardWidth)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(DesignTokens.spring, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
