import SwiftUI

enum ShellMode: Equatable {
    case building, shelf, search, requests, settings
    /// Someone is at my door.
    case peephole(Profile)
    /// Someone is at my door while I'm not to be disturbed: a face, nothing else.
    /// `walkedIn` means they are already in my room, waiting for me to step in.
    case pinhole(Profile, walkedIn: Bool)
    /// I'm at someone's door, knocking.
    case visiting(Door)

    /// Modes that hold the shell open even when the mouse wanders off.
    var pins: Bool {
        switch self {
        case .building, .shelf: false
        case .search, .requests, .settings, .peephole, .pinhole, .visiting: true
        }
    }

    /// Door moments use the small shell; everything else the board.
    var isDoor: Bool {
        switch self {
        case .peephole, .visiting: true
        default: false
        }
    }

    var isPinhole: Bool {
        if case .pinhole = self { return true }
        return false
    }
}

/// The physical sizes the shell takes. `pinhole` is the notch grown by a few points.
enum ShellKind: Equatable {
    case compact, pinhole, board, door
}

/// Compact ↔ expanded, and what the expanded shell is showing.
/// The view animates it; the panel resizes its window to match.
@MainActor
final class NotchState: ObservableObject {
    /// Raw hover from the view. Opening waits a beat so a passing cursor doesn't
    /// trigger it; closing waits a little longer so grazing the edge doesn't flicker.
    @Published var isHovering = false { didSet { if oldValue != isHovering { settleHover() } } }
    @Published var mode: ShellMode = .building {
        didSet {
            if oldValue != mode { onModeChange?(mode) }
            recompute()
        }
    }
    @Published private(set) var kind: ShellKind = .compact {
        didSet { if oldValue != kind { onKindChange?(kind) } }
    }
    /// Toggles to make the shell bounce once (a knock).
    @Published var bounce = false
    /// Keeps the board open without a pointer over it: the moment after first launch,
    /// so the notch can show itself once before it goes quiet.
    @Published var heldOpen = false { didSet { if oldValue != heldOpen { recompute() } } }
    /// The intro that plays each time the board opens.
    /// `.playing` owns the avatars' geometry; `.settling` hands it to the building.
    @Published var splash: SplashPhase = .pending

    enum SplashPhase: Equatable { case pending, playing, settling, done }

    var isExpanded: Bool { kind != .compact }
    /// The shell reads as an open card: rounded all round, hairline, shadow.
    /// Compact and pinhole are the notch itself, only bigger.
    var isOpen: Bool { kind == .board || kind == .door }

    var onKindChange: ((ShellKind) -> Void)?
    var onModeChange: ((ShellMode) -> Void)?
    /// Signed out: the board offers to finish setting up, which happens in a window.
    var onSetupRequested: (() -> Void)?

    private var hoverTask: Task<Void, Never>?
    private var hoverSettled = false

    /// Back to the plain hallway; collapses if the mouse has left.
    /// Door moments are not dismissed this way.
    func unpin() {
        switch mode {
        case .search, .requests, .settings: mode = .building
        default: break
        }
    }

    func knockBounce() {
        withAnimation(.interpolatingSpring(stiffness: 700, damping: 14)) { bounce.toggle() }
    }

    private func settleHover() {
        hoverTask?.cancel()
        let target = isHovering
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: target ? DesignTokens.hoverOpenDelay : DesignTokens.hoverCloseGrace)
            guard let self, !Task.isCancelled else { return }
            hoverSettled = target
            recompute()
        }
    }

    private func recompute() {
        let expanded = hoverSettled || mode.pins || heldOpen
        let next: ShellKind = !expanded ? .compact : mode.isPinhole ? .pinhole : mode.isDoor ? .door : .board
        guard next != kind else { return }
        // The pinhole is not an event: it eases in, it does not spring.
        let animation: Animation = next == .compact ? DesignTokens.springClose
            : next == .pinhole ? .easeOut(duration: 0.5) : DesignTokens.springOpen
        withAnimation(animation) { kind = next }
    }
}
