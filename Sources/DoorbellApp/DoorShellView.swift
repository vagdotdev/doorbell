import SwiftUI

/// The door itself. Idle: a black pill hugging the notch. Hovered: unfurls into the shell.
struct DoorShellView: View {
    let geometry: NotchGeometry
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var controller: DoorController
    @EnvironmentObject private var hallway: HallwayStore

    private var size: CGSize { geometry.size(for: state.kind) }
    private var frameSize: CGSize { geometry.frameSize(for: state.kind) }

    private var shape: NotchShape {
        state.isExpanded
            ? NotchShape(topRadius: DesignTokens.shellRadius, bottomRadius: DesignTokens.shellRadius)
            : NotchShape(topRadius: 0, bottomRadius: DesignTokens.compactRadius)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(.black)
                // The same dust as everywhere else, faint, on the shell in every state. Drawn
                // at one fixed size (an overlay, so it never sizes the shell) so the stars
                // hold still while the silhouette animates around them.
                .overlay(alignment: .top) {
                    Starfield(intensity: 0.55, seed: 11)
                        .frame(width: geometry.boardSize.width, height: geometry.doorSize.height)
                }
            // Glass, used once: a top-lit hairline down the sides. Stroked at 2pt and
            // clipped by the silhouette, so exactly 1pt sits inside the edge. Only once
            // open — at rest the shell is the notch and nothing else.
            if state.isExpanded {
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 2
                )
            }
            switch state.kind {
            case .compact: EmptyView()
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
    }

    private var boardContent: some View {
        let s = geometry.size(for: .board)
        return VStack(spacing: 0) {
            TopRow()
                .frame(height: geometry.notchHeight)
                .padding(.horizontal, 14)
            ShellBody()
        }
        .frame(width: s.width, height: s.height)
    }

    @ViewBuilder
    private var doorContent: some View {
        let s = geometry.size(for: .door)
        Group {
            switch state.mode {
            case .peephole(let visitor): PeepholeView(visitor: visitor, geometry: geometry, peep: controller.peep)
            case .visiting(let door): VisitingView(door: door, geometry: geometry, media: controller.media)
            default: EmptyView()
            }
        }
        .frame(width: s.width, height: s.height)
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

/// Menu-bar-height row: tabs left of the physical notch, tools right of it.
private struct TopRow: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var hallway: HallwayStore

    var body: some View {
        HStack(spacing: 0) {
            if hallway.account != .ready {
                Spacer()   // nothing to say up here until you're signed in
            } else {
                HStack(spacing: 4) {
                    TabPill(title: "Friends", selected: state.mode != .shelf) { state.mode = .hallway }
                    TabPill(title: "Shelf", selected: state.mode == .shelf) { state.mode = .shelf }
                }
                Spacer()
                HStack(spacing: 2) {
                    ToolButton(symbol: "magnifyingglass", active: state.mode == .search) {
                        state.mode = state.mode == .search ? .hallway : .search
                    }
                    ToolButton(symbol: "gearshape", active: state.mode == .settings) {
                        hallway.openWindow?()
                    }
                }
            }
        }
    }
}

/// A word, not a glyph. Both tabs fit beside the notch at this size.
private struct TabPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? DesignTokens.ink : (hovering ? DesignTokens.ink : DesignTokens.inkSecondary))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(selected ? DesignTokens.raised : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? DesignTokens.utility : (hovering ? DesignTokens.ink : DesignTokens.inkTertiary))
                .frame(width: 24, height: 22)
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
                VStack(spacing: 10) {
                    Text(hallway.account == .loading ? "Signing in…" : "Welcome to Doorbell").font(.headline)
                    Button("Open Doorbell") { hallway.openWindow?() }.buttonStyle(.borderedProminent)
                }
            } else {
            switch state.mode {
            case .hallway: HallwayView()
            case .shelf: ShelfPlaceholder()
            case .search: SearchView()
            case .requests: HallwayView()
            case .settings: HallwayView()
            case .account: HallwayView()
            case .peephole, .visiting: EmptyView()   // door modes render in the door shell
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let problem = hallway.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).padding(8).background(.black)
                    .onTapGesture { hallway.openWindow?() }
            }
        }
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
