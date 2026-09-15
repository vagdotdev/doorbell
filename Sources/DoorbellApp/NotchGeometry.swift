import AppKit

/// Where the door lives on screen, derived from the physical notch when there is one.
struct NotchGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        return NotchGeometry(screen: screen)
    }

    init(screen: NSScreen) {
        self.screen = screen
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = right.minX - left.maxX
            notchHeight = screen.safeAreaInsets.top
        } else {
            hasNotch = false
            notchWidth = DesignTokens.fallbackNotchWidth
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchHeight = menuBar > 0 ? menuBar : 24
        }
    }

    var compactSize: CGSize {
        CGSize(width: notchWidth + DesignTokens.compactBleedX * 2,
               height: notchHeight + DesignTokens.compactBleedY)
    }

    var boardSize: CGSize {
        CGSize(width: DesignTokens.expandedWidth, height: notchHeight + DesignTokens.boardBodyHeight)
    }

    /// The door shell for a knock: a card hanging under the notch.
    var doorSize: CGSize {
        CGSize(width: DesignTokens.expandedWidth, height: notchHeight + DesignTokens.doorBodyHeight)
    }

    /// The body: where content is laid out.
    func size(for kind: ShellKind) -> CGSize {
        switch kind {
        case .compact: compactSize
        case .board: boardSize
        case .door: doorSize
        }
    }

    /// What the window is sized to. The shell no longer flares into the screen edge,
    /// so this is the body itself; kept as a seam in case the silhouette grows again.
    func frameSize(for kind: ShellKind) -> CGSize {
        size(for: kind)
    }

    /// A rect of the given size, top-centred and flush with the top edge of the screen.
    func rect(for size: CGSize) -> NSRect {
        NSRect(x: screen.frame.midX - size.width / 2,
               y: screen.frame.maxY - size.height,
               width: size.width,
               height: size.height)
    }
}
