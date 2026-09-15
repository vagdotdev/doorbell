import SwiftUI

enum PeepholeStyle: String, CaseIterable, Identifiable {
    case rectangle, eyehole

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rectangle: "Wide"
        case .eyehole: "Round"
        }
    }
}

/// UserDefaults keys. All local; none of this leaves the machine.
enum SettingsKey {
    static let quiet = "quietDoor"
    static let peepholeStyle = "peepholeStyle"
    static let soundsEnabled = "soundsEnabled"
    static let micModeNudged = "micModeNudged"
}
