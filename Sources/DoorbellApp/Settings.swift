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
    static let doorVolume = "doorVolume"
    static let roomOnNotchScreen = "roomOnNotchScreen"
    static let roomFullscreen = "roomFullscreen"
    static let audioInput = "audioInput"
    static let audioOutput = "audioOutput"
    static var currentDoorVolume: Float {
        guard UserDefaults.standard.object(forKey: doorVolume) != nil else { return DesignTokens.doorVolume }
        let value = UserDefaults.standard.float(forKey: doorVolume)
        return value.isFinite ? min(1, max(0, value)) : DesignTokens.doorVolume
    }
    static let peepholeStyle = "peepholeStyle"
    static let soundsEnabled = "soundsEnabled"
    static let micModeNudged = "micModeNudged"
}
