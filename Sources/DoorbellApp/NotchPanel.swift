import AppKit
import Combine
import SwiftUI

/// Borderless panel flush with the top of the screen, sized to the notch when idle
/// and to the shell when open. Resizing (not a permanent large transparent window)
/// is what keeps clicks on the menu bar working while the door is closed.
final class NotchPanel: NSPanel {
    private let geometry = NotchGeometry.current()
    private let state = NotchState()
    private let backend: any DoorbellBackend
    private let hallway: HallwayStore
    private let door: DoorController
    private var clickOutsideMonitor: Any?
    private var hoverMonitors: [Any] = []
    private var settleTask: Task<Void, Never>?
    private var accountSink: AnyCancellable?

    init() {
        let config = AppConfig.current
        if config.useConvex, let url = config.convexURL {
            backend = ConvexBackend(url: url, config: config)
        } else if config.useSupabase, let url = config.supabaseURL, let key = config.supabaseAnonKey {
            backend = SupabaseBackend(url: url, anonKey: key, config: config)
        } else {
            backend = MockBackend()
        }
        hallway = HallwayStore(backend: backend)
        door = DoorController(backend: backend, state: state, hallway: hallway)
        super.init(
            contentRect: geometry.rect(for: geometry.frameSize(for: .compact)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // at rest the shell is the notch; the shadow comes with the shell
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // The shell is black no matter what the system is doing.
        appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(
            rootView: DoorShellView(geometry: geometry)
                .environmentObject(state)
                .environmentObject(hallway)
                .environmentObject(door)
                .environment(\.colorScheme, .dark)
        )
        contentView = host.fillingContainer()
        state.onKindChange = { [weak self] kind in
            self?.resize(to: kind)
            // Opening the building is the moment to catch up on accepts and requests.
            if kind == .board, let hallway = self?.hallway { Task { await hallway.refresh() } }
        }
        state.onModeChange = { [weak self] mode in
            // Typing needs key status; a non-activating panel gets it without stealing the app.
            if mode == .search || mode == .account { self?.makeKey() }
        }
        // Signed out → the board is the sign-in form and stays open. Ready → let go.
        accountSink = hallway.$account.removeDuplicates().sink { [weak self] account in
            guard let self else { return }
            if account != .ready {
                state.mode = .account
            } else if state.mode == .account {
                state.mode = .building
            }
        }

        // A pinned shell (search, settings…) lets go when you click anywhere else.
        // Not while a snapshot is being taken: whoever asked for it is still typing, and
        // their pointer must not open or close the shell either.
        guard ProcessInfo.processInfo.environment["DOORBELL_SNAPSHOT"] == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.state.unpin() }
        }
        // Hover, from the pointer's position against the window — the one thing that
        // reports reliably while some other app is frontmost. Global covers other apps'
        // events, local covers our own once the panel is key.
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.trackMouse() }
        }) { hoverMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] event in
            Task { @MainActor [weak self] in self?.trackMouse() }
            return event
        }) { hoverMonitors.append(local) }
    }

    private func trackMouse() {
        // Against the shell's own rect, not the window's: while a spring settles the
        // window is deliberately larger than the shell, and that slack must not count.
        let shell = geometry.rect(for: geometry.frameSize(for: state.kind))
        let inside = shell.contains(NSEvent.mouseLocation)
        if state.isHovering != inside { state.isHovering = inside }
    }

    // Lets the search field take keyboard focus without activating the app.
    override var canBecomeKey: Bool { true }

    func show() {
        orderFrontRegardless()
        Snapshot.armIfRequested(window: self)
        // Hover can't be scripted without Accessibility rights, so for screenshots:
        //   DOORBELL_START_EXPANDED=1
        //   DOORBELL_START_MODE=search|requests|settings|shelf|visit:arjun
        //   DOORBELL_SIMULATE=knock:arjun|walkin:arjun   (handled by MockBackend)
        let env = ProcessInfo.processInfo.environment
        //   DOORBELL_SIGNIN=email:password  (real backend) sign in before anything else
        if let cred = env["DOORBELL_SIGNIN"], let colon = cred.firstIndex(of: ":") {
            let email = String(cred[..<colon]), password = String(cred[cred.index(after: colon)...])
            Task { @MainActor [weak self] in try? await self?.hallway.signIn(email: email, password: password) }
        }
        if let mode = env["DOORBELL_START_MODE"] {
            // Board modes wait for the account to settle, which otherwise lands on the hallway.
            func once(_ target: ShellMode) {
                Task { @MainActor [weak self] in
                    for _ in 0..<40 where self?.hallway.account != .ready {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    self?.state.mode = target
                }
            }
            switch mode {
            case "search": once(.search)
            case "requests": once(.requests)
            case "settings": once(.settings)
            case "shelf": state.mode = .shelf; state.isHovering = true
            case let v where v.hasPrefix("visit:"):
                let handle = String(v.dropFirst(6))
                Task { @MainActor [weak self] in
                    // Give sign-in and the first hallway fetch a moment.
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(250))
                        if self?.hallway.doors.contains(where: { $0.profile.handle == handle }) == true { break }
                    }
                    guard let self, let door = self.hallway.doors.first(where: { $0.profile.handle == handle }) else { return }
                    self.door.visit(door)
                }
            default: break
            }
        } else if env["DOORBELL_START_EXPANDED"] != nil {
            state.isHovering = true
        }
    }

    /// Grow immediately to cover both the old and new shell, with room for the spring
    /// to overshoot; snap to the exact target once it has settled.
    private func resize(to kind: ShellKind) {
        let target = geometry.rect(for: geometry.frameSize(for: kind))
        // Closing is critically damped and lands on the notch; no room needed there.
        let open = kind == .board || kind == .door
        let room = open ? DesignTokens.overshootRoom : 0
        let roomy = NSRect(x: target.minX - room, y: target.minY - room,
                           width: target.width + 2 * room, height: target.height + room)
        settleTask?.cancel()
        hasShadow = open
        setFrame(frame.union(roomy), display: true)
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: DesignTokens.springSettle)
            guard let self, !Task.isCancelled, self.state.kind == kind else { return }
            self.setFrame(target, display: true)
        }
    }
}
