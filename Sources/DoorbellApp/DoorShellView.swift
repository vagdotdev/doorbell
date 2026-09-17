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
        state.isOpen
            ? NotchShape(topRadius: DesignTokens.shellRadius, bottomRadius: DesignTokens.shellRadius)
            : NotchShape(topRadius: 0, bottomRadius: DesignTokens.compactRadius)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(.black)
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
    }

    private var boardContent: some View {
        let s = geometry.size(for: .board)
        return VStack(spacing: 0) {
            TopRow()
                .frame(height: geometry.notchHeight)
                .padding(.horizontal, 14)
            ShellBody()
                .background(Starfield(intensity: 0.55, seed: 11))
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

/// Doorbell is both the app name and home tab; settings sits beside it, spelled out.
/// Shelf and search stay on the right.
private struct TopRow: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var hallway: HallwayStore

    var body: some View {
        HStack(spacing: 0) {
            if hallway.account != .ready {
                Spacer()   // nothing to say up here until there is a hallway
            } else {
                HStack(spacing: 4) {
                    TabPill(title: "Doorbell", symbol: nil,
                            selected: state.mode != .shelf && state.mode != .settings) { state.mode = .hallway }
                    TabPill(title: "Open settings", symbol: "gearshape",
                            selected: state.mode == .settings) {
                        state.mode = state.mode == .settings ? .hallway : .settings
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    TabPill(title: "Shelf", symbol: "tray",
                            selected: state.mode == .shelf) { state.mode = .shelf }
                    ToolButton(symbol: "magnifyingglass", active: state.mode == .search) {
                        state.mode = state.mode == .search ? .hallway : .search
                    }
                    .help("Find friends")
                }
            }
        }
    }
}

private struct TabPill: View {
    let title: String
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
            .padding(.horizontal, 8)
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
            case .hallway: HallwayView()
            case .shelf: ShelfPlaceholder()
            case .search: SearchView()
            case .requests: RequestsView()
            case .settings: SettingsView()
            case .account: HallwayView()
            case .peephole, .pinhole, .visiting: EmptyView()   // door modes render in their own shells
            }
            }
        }
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
