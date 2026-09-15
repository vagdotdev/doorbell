import SwiftUI

/// The door itself. Idle: a black pill hugging the notch. Hovered: unfurls into the shell.
struct DoorShellView: View {
    let geometry: NotchGeometry
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var controller: DoorController

    private var size: CGSize { geometry.size(for: state.kind) }
    private var frameSize: CGSize { geometry.frameSize(for: state.kind) }

    private var shape: NotchShape {
        state.isExpanded
            ? NotchShape(topFillet: DesignTokens.shellFillet, bottomRadius: DesignTokens.shellRadius)
            : NotchShape(topFillet: DesignTokens.compactFillet, bottomRadius: DesignTokens.compactRadius)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(.black)
            // Glass, used once: a top-lit hairline down the sides. Stroked at 2pt and
            // clipped by the silhouette, so exactly 1pt sits inside the edge.
            shape.stroke(
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 2
            )
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
        .onHover { state.isHovering = $0 }
        .onExitCommand { state.unpin() }
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
                Text("Doorbell")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .padding(.horizontal, 10)
                Spacer()
            } else {
                HStack(spacing: 4) {
                    TabPill(title: "Hallway", symbol: "door.left.hand.open",
                            selected: state.mode != .shelf) { state.mode = .hallway }
                    TabPill(title: "Shelf", symbol: "tray",
                            selected: state.mode == .shelf) { state.mode = .shelf }
                }
                Spacer()
                HStack(spacing: 2) {
                    ToolButton(symbol: "magnifyingglass", active: state.mode == .search) {
                        state.mode = state.mode == .search ? .hallway : .search
                    }
                    ToolButton(symbol: "gearshape", active: state.mode == .settings) {
                        state.mode = state.mode == .settings ? .hallway : .settings
                    }
                }
            }
        }
    }
}

private struct TabPill: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The label shows on the selected tab only, so both fit beside the notch.
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                if selected {
                    Text(title).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(selected ? DesignTokens.ink : DesignTokens.inkSecondary)
            .padding(.horizontal, selected ? 10 : 9)
            .frame(height: 22)
            .background(
                Capsule().fill(selected ? DesignTokens.raised : .clear)
            )
        }
        .buttonStyle(.plain)
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
            case .peephole, .visiting: EmptyView()   // door modes render in the door shell
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
