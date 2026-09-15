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

    /// The body plus the fillets that flare into the screen edge on either side.
    func frameSize(for kind: ShellKind) -> CGSize {
        let body = size(for: kind)
        let fillet = kind == .compact ? DesignTokens.compactFillet : DesignTokens.shellFillet
        return CGSize(width: body.width + 2 * fillet, height: body.height)
    }

    /// A rect of the given size, top-centred and flush with the top edge of the screen.
    func rect(for size: CGSize) -> NSRect {
        NSRect(x: screen.frame.midX - size.width / 2,
               y: screen.frame.maxY - size.height,
               width: size.width,
               height: size.height)
    }
}
