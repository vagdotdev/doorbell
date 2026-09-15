import AppKit
import SwiftUI

extension NSHostingView {
    /// Wraps the hosting view in a plain NSView that fills the window.
    ///
    /// When an NSHostingView is a window's contentView it takes over window sizing
    /// (animated, constraint-driven) and fights any code that sets the frame itself —
    /// eventually AppKit throws "more Update Constraints passes than views". Nesting it
    /// one level down turns that off; we own the window size.
    func fillingContainer() -> NSView {
        sizingOptions = []
        let container = NSView()
        container.wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = true
        frame = container.bounds
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        return container
    }
}
