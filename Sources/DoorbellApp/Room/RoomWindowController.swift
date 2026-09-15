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

    func present() {
        guard let window else { return }
        window.title = "Doorbell"   // for Mission Control and the Window menu; the titlebar itself is hidden
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        session.leave()
    }
}
