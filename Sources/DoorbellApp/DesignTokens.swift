import SwiftUI

/// Single source of truth for Doorbell's visual language.
/// Values distilled from the NotchNook + DynamicLake study in docs/design-language.md.
enum DesignTokens {
    // Silhouette. At rest: the notch (square top, hidden in the hardware). Open: one
    // rounded rectangle, the same radius on every corner.
    static let compactRadius: CGFloat = 12
    static let shellRadius: CGFloat = 28

    // One expanded width for everything; only the height breathes.
    static let expandedWidth: CGFloat = 480
    /// Below the notch row. The shell is this plus the notch height.
    /// Tall enough for Settings → Profile + prefs without feeling cramped.
    static let boardBodyHeight: CGFloat = 248
    /// The door card: name, the glass as the hero, a row of round controls.
    static let doorBodyHeight: CGFloat = 296
    /// Do not disturb: how far the notch grows to fit one small face. Two rooms away.
    static let pinholeBodyHeight: CGFloat = 34
    static let pinholeFace: CGFloat = 24
    /// Eyehole diameter; the rectangle is 16:9 of this.
    static let glassHeight: CGFloat = 174
    static let glassRadius: CGFloat = 16
    static let controlSize: CGFloat = 40
    /// A friend's voice through the door, before you choose to listen.
    static let doorVolume: Float = 0.25
    /// Raised-cosine fades for incoming voice. Long enough to feel, short enough to vanish.
    /// Arrival is slow on purpose: it rises under the tail of the knock tone.
    static let audioArrive: TimeInterval = 0.9
    static let audioListen: TimeInterval = 0.40
    static let audioEnter: TimeInterval = 0.48
    static let audioDepart: TimeInterval = 0.34

    // At rest the shell is the notch: it does not peek out beside or below it.
    static let compactBleedX: CGFloat = 0
    static let compactBleedY: CGFloat = 0
    // Macs without a notch get a pill this wide under the menu bar.
    static let fallbackNotchWidth: CGFloat = 185

    // Two accents, two worlds. Never mixed.
    static let utility = Color(red: 0.36, green: 0.62, blue: 1.0)   // tabs, tray, settings
    static let social = Color(red: 1.0, green: 0.72, blue: 0.32)    // knocks, close friends
    static let openDoor = Color(red: 0.30, green: 0.85, blue: 0.50) // the one green button

    // Atmosphere, not an accent: the one cold light that catches every rim. Barely
    // blue — a colour you notice only when it is gone.
    static let horizon = Color(red: 0.70, green: 0.78, blue: 0.90)
    /// The room is not flat black; it is a dark space with a floor.
    static let roomFloor = Color(red: 0.045, green: 0.05, blue: 0.065)
    /// How far the doorstep dome rises above the bottom of the door shell.
    static let doorstepRise: CGFloat = 72

    // Type on black
    static let ink = Color.white
    static let inkSecondary = Color.white.opacity(0.55)
    static let inkTertiary = Color.white.opacity(0.32)
    static let hairline = Color.white.opacity(0.10)
    static let raised = Color.white.opacity(0.07)

    // Door presence
    static let doorOpen = Color.green
    static let doorCracked = Color.yellow
    static let doorClosed = Color.red

    // Motion
    static let spring = Animation.interpolatingSpring(stiffness: 300, damping: 28)
    /// Opening is quick and lands once; no visible overshoot. Closing settles clean.
    static let springOpen = Animation.spring(response: 0.38, dampingFraction: 0.88)
    static let springClose = Animation.spring(response: 0.34, dampingFraction: 0.92)
    /// Time the window waits after a shape change before snapping to the exact frame.
    static let springSettle: Duration = .milliseconds(600)
    /// Extra window on each side so the spring can overshoot without clipping.
    static let overshootRoom: CGFloat = 24
    /// A passing cursor doesn't open the door; leaving the edge doesn't slam it.
    static let hoverOpenDelay: Duration = .milliseconds(90)
    static let hoverCloseGrace: Duration = .milliseconds(220)
}
