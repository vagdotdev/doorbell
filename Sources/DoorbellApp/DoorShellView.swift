import SwiftUI

/// The door itself. Idle: a black pill hugging the notch. Hovered: unfurls into the shell.
struct DoorShellView: View {
    let geometry: NotchGeometry
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var controller: DoorController
    @EnvironmentObject private var hallway: HallwayStore
    @Namespace private var avatars

    private var size: CGSize { geometry.size(for: state.kind) }
    private var frameSize: CGSize { geometry.frameSize(for: state.kind) }

    /// The intro plays when the board opens and you have no friends yet.
    private var wantsSplash: Bool {
        state.kind == .board && state.splash != .done && hallway.me != nil
            && hallway.orderedDoors.isEmpty
            && ProcessInfo.processInfo.environment["DOORBELL_NO_SPLASH"] == nil
    }

    private var shape: NotchShape {
        state.isOpen
            ? NotchShape(topRadius: DesignTokens.shellRadius, bottomRadius: DesignTokens.shellRadius)
            : NotchShape(topRadius: 0, bottomRadius: DesignTokens.compactRadius)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(.black)
            // Open, the black has a floor: the room's dark, rising from the bottom edge.
            // At rest the shell is the notch and stays pure black.
            shape.fill(LinearGradient(
                stops: [.init(color: .clear, location: 0.35),
                        .init(color: DesignTokens.roomFloor.opacity(0.9), location: 1)],
                startPoint: .top, endPoint: .bottom))
                .opacity(state.isOpen ? 1 : 0)
            // Glass, used once: a top-lit hairline down the sides. Stroked at 2pt and
            // clipped by the silhouette, so exactly 1pt sits inside the edge. Only once
            // open — at rest (and as a pinhole) the shell is the notch and nothing else.
            if state.isOpen {
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 2
                )
            }
            switch state.kind {
            case .compact: EmptyView()
            case .pinhole: pinholeContent.transition(.opacity.animation(.easeOut(duration: 0.4).delay(0.2)))
            case .board: boardContent.transition(.shellContent)
            case .door: doorContent.transition(.shellContent)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipShape(shape)
        // The knock: a quick, heavy dip from the top edge.
        .modifier(KnockBounce(trigger: state.bounce))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Hover is tracked by the panel (see NotchPanel.trackMouse), not here: SwiftUI's
        // onHover only reports reliably while the app is active, and this app never is.
        .onExitCommand { state.unpin() }
        .task(id: state.kind) {
            guard state.kind == .board else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await hallway.refresh()
            }
        }
        .alert("Doorbell", isPresented: Binding(get: { controller.problem != nil || hallway.problem != nil }, set: { if !$0 { controller.problem = nil; hallway.problem = nil } })) {
            Button("OK") { controller.problem = nil; hallway.problem = nil }
        } message: { Text(controller.problem ?? hallway.problem ?? "") }
        // Signing out (or losing the account) means the intro is due again.
        .onChange(of: hallway.account) { _, account in
            if account != .ready { state.splash = .pending }
        }
        .onChange(of: hallway.orderedDoors.count) { _, count in
            if count > 0 { state.splash = .done }
        }
    }

    private var boardContent: some View {
        let s = geometry.size(for: .board)
        return ZStack {
            VStack(spacing: 0) {
                TopRow()
                    .frame(height: geometry.notchHeight)
                    .padding(.horizontal, 14)
                ShellBody()
                    .background {
                        // The building's front step: the same dome the door stands on,
                        // lower, so the row of doors has something under it.
                        ZStack {
                            Starfield(intensity: 0.55, seed: 11)
                            Doorstep(rise: 30)
                        }
                    }
            }
            // Requests and shelf: bottom-right corner tools.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    BoardCornerTools()
                }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 6)
            VStack {
                Spacer()
                VagdevCredit()
            }
            .padding(.bottom, 6)
            .allowsHitTesting(false)
            .environment(\.avatarNamespace, avatars)
            .environment(\.splashOwnsAvatars, wantsSplash && state.splash != .settling)
            .environment(\.splashOnScreen, wantsSplash)
            if wantsSplash, let me = hallway.me {
                SplashView(me: me, friends: hallway.orderedDoors.map(\.profile), geometry: geometry,
                           namespace: avatars)
                    .zIndex(1)
            }
        }
        .frame(width: s.width, height: s.height)
    }

    @ViewBuilder
    private var pinholeContent: some View {
        if case .pinhole(let visitor, _) = state.mode {
            PinholeView(visitor: visitor, geometry: geometry, peep: controller.peep)
        }
    }

    @ViewBuilder
    private var doorContent: some View {
        let s = geometry.size(for: .door)
        Group {
            switch state.mode {
            case .peephole(let visitor): PeepholeView(visitor: visitor, geometry: geometry, peep: controller.peep, room: controller.room)
            case .visiting(let door): VisitingView(door: door, geometry: geometry, media: controller.media)
            default: EmptyView()
            }
        }
        .frame(width: s.width, height: s.height)
        .overlay(alignment: .topTrailing) {
            QuietDoorButton()
                .frame(height: geometry.notchHeight)
                .padding(.trailing, 14)
        }
    }
}

private struct QuietDoorButton: View {
    @EnvironmentObject private var door: DoorController

    var body: some View {
        ToolButton(symbol: door.quiet ? "moon.fill" : "moon", active: door.quiet) {
            withAnimation(.easeOut(duration: 0.18)) { door.quiet.toggle() }
        }
        .help(door.quiet ? "\(door.quietLabel) · Click to turn off" : "Quiet for 6 hours · You can still accept calls")
        .accessibilityLabel("Quiet Door")
        .accessibilityValue(door.quiet ? door.quietLabel : "Off")
    }
}

/// Content arrives once the shell has room for it — sharpening and settling out of the
/// notch — and leaves quickly, before the shell shrinks around it.
private extension AnyTransition {
    @MainActor
    static var shellContent: AnyTransition { .asymmetric(
        insertion: .modifier(active: ContentFX(blur: 8, scale: 0.94, opacity: 0),
                             identity: ContentFX(blur: 0, scale: 1, opacity: 1))
            .animation(.spring(response: 0.36, dampingFraction: 0.86).delay(0.07)),
        removal: .modifier(active: ContentFX(blur: 6, scale: 0.98, opacity: 0),
                           identity: ContentFX(blur: 0, scale: 1, opacity: 1))
            .animation(.easeIn(duration: 0.11))
    ) }
}

private struct ContentFX: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale, anchor: .top)
            .opacity(opacity)
    }
}

/// One dip-and-settle each time `trigger` flips.
private struct KnockBounce: ViewModifier {
    var trigger: Bool
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .onChange(of: trigger) { _, _ in
                withAnimation(.interpolatingSpring(stiffness: 900, damping: 9)) { offset = 7 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(90))
                    withAnimation(.interpolatingSpring(stiffness: 500, damping: 16)) { offset = 0 }
                }
            }
    }
}

/// Home on the left, tools on the right, nothing in the middle: the middle ±92pt of
/// this strip sits behind the physical notch. Keep both clusters in their corners.
private struct TopRow: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var hallway: HallwayStore

    var body: some View {
        HStack(spacing: 0) {
            if hallway.account != .ready {
                Spacer()   // nothing to say up here until there is a building
            } else {
                TabPill(title: "Doorbell", symbol: nil,
                        selected: state.mode != .shelf && state.mode != .settings) { state.mode = .building }
                Spacer()
                HStack(spacing: 2) {
                    QuietDoorButton()
                    ToolButton(symbol: "magnifyingglass", active: state.mode == .search) {
                        state.mode = state.mode == .search ? .building : .search
                    }
                    .help("Find friends")
                    ToolButton(symbol: "gearshape", active: state.mode == .settings) {
                        state.mode = state.mode == .settings ? .building : .settings
                    }
                    .help("Settings")
                }
            }
        }
    }
}

private struct TabPill: View {
    let title: String
    /// SF Symbol, or nil for the peephole mark (home).
    let symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                } else {
                    PeepholeMark()
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .fixedSize()
            .foregroundStyle(selected ? DesignTokens.ink : DesignTokens.inkSecondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                Capsule().fill(selected ? DesignTokens.raised : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A dark lens and a thin rim: the same peephole as the door, at tab size.
private struct PeepholeMark: View {
    var body: some View {
        Circle()
            .fill(.black)
            .overlay(Circle().strokeBorder(.primary.opacity(0.8), lineWidth: 1))
            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5).padding(3))
            .overlay(alignment: .topLeading) {
                Circle().fill(.primary.opacity(0.8))
                    .frame(width: 2, height: 2)
                    .offset(x: 3, y: 3)
            }
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }
}

/// Requests and shelf in the board's bottom-right corner.
private struct BoardCornerTools: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var hallway: HallwayStore

    var body: some View {
        HStack(spacing: 2) {
            CornerTool(
                symbol: "person.crop.circle.badge.plus",
                active: state.mode == .requests,
                badge: hallway.requests.count
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    state.mode = state.mode == .requests ? .building : .requests
                }
            }
            .help("Friend requests")
            CornerTool(
                symbol: "square.stack.3d.up",
                active: state.mode == .shelf
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    state.mode = state.mode == .shelf ? .building : .shelf
                }
            }
            .help("Shelf")
        }
    }
}

private struct CornerTool: View {
    let symbol: String
    let active: Bool
    var badge: Int = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? DesignTokens.utility
                                    : (hovering ? DesignTokens.ink : DesignTokens.inkSecondary))
                    .frame(width: 26, height: 22)
                    .background(Capsule().fill(active || hovering ? DesignTokens.raised : .clear))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Circle().fill(DesignTokens.social))
                        .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                        .offset(x: 5, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small credit, bottom of the board and onboarding window.
struct VagdevCredit: View {
    var body: some View {
        Text("by vagdev")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(DesignTokens.inkTertiary.opacity(0.7))
    }
}

private struct ToolButton: View {
    let symbol: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? DesignTokens.utility : (hovering ? DesignTokens.ink : DesignTokens.inkSecondary))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(active || hovering ? DesignTokens.raised : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Everything under the top row, by mode.
private struct ShellBody: View {
    @EnvironmentObject private var state: NotchState

    @EnvironmentObject private var hallway: HallwayStore

    var body: some View {
        Group {
            if hallway.account != .ready {
                AccountView()
            } else {
            switch state.mode {
            case .building: BuildingView().transition(.opacity)
            case .shelf: ShelfPlaceholder().transition(.opacity)
            case .search: SearchView().transition(.opacity)
            case .requests: RequestsView().transition(.opacity)
            case .settings: SettingsView().transition(.opacity)
            case .peephole, .pinhole, .visiting: EmptyView()   // door modes render in their own shells
            }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.mode)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfPlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(DesignTokens.inkTertiary)
            Text("Empty")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.inkTertiary)
        }
    }
}
