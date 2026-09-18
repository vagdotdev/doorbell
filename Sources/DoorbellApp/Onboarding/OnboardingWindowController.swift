import AppKit
import SwiftUI

/// First launch, and any time there is no account: a real window, once. Black, the
/// room window's chrome. While it is up the app is a normal app — Dock icon, menu bar —
/// and when it closes the app goes back to being the notch.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let hallway: HallwayStore
    private let finished: () -> Void

    init(hallway: HallwayStore, finished: @escaping () -> Void) {
        self.hallway = hallway
        self.finished = finished
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        let host = NSHostingView(
            rootView: OnboardingView { [weak self] in self?.done() }
                .environmentObject(hallway)
                .environment(\.colorScheme, .dark)
        )
        window.contentView = host.fillingContainer()
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        window.title = "Doorbell"
        if !window.isVisible { window.center() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func done() {
        window?.close()
        if hallway.account == .ready { finished() }
    }

    func windowWillClose(_ notification: Notification) {
        guard hallway.account == .ready else {
            // Setup isn't done — keep the Dock icon so the window is findable.
            NSApp.setActivationPolicy(.regular)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }
}
