import SwiftUI

/// Single source of truth for Doorbell's visual language.
/// Values distilled from the NotchNook + DynamicLake study in docs/design-language.md.
enum DesignTokens {
    // Shell
    static let shellRadius: CGFloat = 26
    static let expandedWidth: CGFloat = 560
    static let compactHeight: CGFloat = 40

    // Door presence
    static let doorOpen = Color.green
    static let doorCracked = Color.yellow
    static let doorClosed = Color.red

    // Motion
    static let spring = Animation.interpolatingSpring(stiffness: 300, damping: 28)
}
