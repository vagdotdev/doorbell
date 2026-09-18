import AppKit
import SwiftUI

/// The one conventional window Doorbell has. Black, traffic lights floating.
@MainActor
final class RoomWindowController: NSWindowController, NSWindowDelegate {
    private let session: RoomSession

    init(session: RoomSession, door: DoorController) {
        self.session = session
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        // We own the short arrival fade; don't stack the system's opening zoom.
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.fullScreenPrimary]
        let host = NSHostingView(
            rootView: RoomView()
                .environmentObject(session)
                .environmentObject(door)
                .environment(\.colorScheme, .dark)
        )
        window.contentView = host.fillingContainer()
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Hide the hang without Leave. Used when we vacate to take a knock in a new room.
    func hide() {
        finishArrival()
        window?.orderOut(nil)
    }

    func present() {
        guard let window else { return }
        window.title = "Doorbell"   // for Mission Control and the Window menu; the titlebar itself is hidden
        let arriving = !window.isVisible
        if arriving {
            window.center()
            window.alphaValue = 0
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if arriving {
            NSAnimationContext.runAnimationGroup { context in
                // A fade also works with Reduce Motion: no window travel or zoom.
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.22
                window.animator().alphaValue = 1
            }
        }
    }

    override func close() {
        finishArrival()
        super.close()
    }

    private func finishArrival() {
        // Stop an in-flight fade synchronously. No delayed close callback can
        // dismiss a different call if someone immediately accepts again.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window?.animator().alphaValue = 1
        }
    }

    func windowWillClose(_ notification: Notification) {
        finishArrival()
        session.leave()
    }
}
