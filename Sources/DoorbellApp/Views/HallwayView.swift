import SwiftUI

/// A row of friends. You first, then everyone you follow, then a way to find more.
/// Wider than the shell, it pages: chevrons appear at whichever edge has more.
struct HallwayView: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var hallway: HallwayStore
    @State private var offset: CGFloat = 0
    @State private var overflow: CGFloat = 0   // content width minus visible width
    @State private var scrollTarget: String?

    // Sub-pixel jitter while the shell's spring settles must not flicker the chevrons.
    private var canGoBack: Bool { offset > 4 }
    private var canGoForward: Bool { overflow - offset > 4 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: cardSpacing) {
                if let me = hallway.me {
                    OwnDoorCard(me: me, requests: hallway.requests.count) {
                        hallway.openWindow?()
                    }
                    .id("me")
                }
                ForEach(hallway.doors) { door in
                    DoorCard(door: door).id(door.id)
                }
                AddDoorCard { state.mode = .search }
                    .id("add")
            }
            .scrollTargetLayout()
            .padding(.horizontal, rowInset)
        }
        .scrollClipDisabled()
        .scrollPosition(id: $scrollTarget, anchor: .leading)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.width - $0.containerSize.width) } action: { _, o in overflow = o }
        .overlay(alignment: .leading) {
            if canGoBack { PageChevron(forward: false) { page(by: -1) } }
        }
        .overlay(alignment: .trailing) {
            if canGoForward { PageChevron(forward: true) { page(by: 1) } }
        }
        .animation(.easeOut(duration: 0.15), value: canGoBack)
        .animation(.easeOut(duration: 0.15), value: canGoForward)
        .frame(maxHeight: .infinity)
    }

    private var ids: [String] {
        (hallway.me == nil ? [] : ["me"]) + hallway.doors.map(\.id) + ["add"]
    }

    /// One page is however many whole cards fit in the shell.
    private func page(by direction: Int) {
        let visible = DesignTokens.expandedWidth - rowInset * 2
        let perPage = max(1, Int((visible + cardSpacing) / (cardWidth + cardSpacing)))
        let current = Int(round(offset / (cardWidth + cardSpacing)))
        let next = min(max(0, current + direction * perPage), max(0, ids.count - perPage))
        withAnimation(DesignTokens.springOpen) { scrollTarget = ids[next] }
    }
}

// MARK: - Cards

private let avatarSize: CGFloat = 54
private let cardWidth: CGFloat = 76
private let cardSpacing: CGFloat = 18
private let rowInset: CGFloat = 22

private struct PageChevron: View {
    let forward: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? DesignTokens.ink : DesignTokens.inkSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.black.opacity(0.85)))
                .overlay(Circle().strokeBorder(DesignTokens.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        // Sits at avatar height, where the eye already is.
        .offset(y: -(cardWidth - avatarSize) / 2 - 6)
        .transition(.opacity)
    }
}

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
            Toggle("Close Friend", isOn: Binding(
                get: { door.isCloseFriend },
                set: { hallway.setCloseFriend(door.profile, $0) }
            ))
            .disabled(!door.followsMe || hallway.busy)
            if !door.followsMe {
                Text("Available once they follow you back")
            }
            Divider()
            Button("Unfollow @\(door.profile.handle)", role: .destructive) {
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
