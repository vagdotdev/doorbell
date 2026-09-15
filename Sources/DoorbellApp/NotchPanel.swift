import AppKit
import SwiftUI

/// Borderless floating panel that hangs off the notch.
/// Milestone 1: static shell. Expand/collapse, peephole, live states come next.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: Self.topCenterRect(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: DoorShellView())
    }

    func show() {
        orderFrontRegardless()
    }

    private static func topCenterRect() -> NSRect {
        let w: CGFloat = DesignTokens.expandedWidth
        let h: CGFloat = 220
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: w, height: h)
        }
        let x = screen.visibleFrame.midX - w / 2
        let y = screen.visibleFrame.maxY - h
        return NSRect(x: x, y: y, width: w, height: h)
    }
}
