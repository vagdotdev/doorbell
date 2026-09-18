import CoreAudio
import CoreMediaIO
import Foundation
import Intents

/// Local privacy gate for automatic doorstep audio, never published to friends.
/// Unknown permission/activity is treated as quiet; accepting a call is explicit
/// and does not use this gate.
enum Quiet {
    struct AudioProcess: Equatable {
        let pid: Int32
        let inputRunning: Bool
    }

    enum Status: Equatable {
        case available, focusOn, focusAccessRequired, focusStatusUnavailable
        case otherAppRecording, audioActivityUnavailable, manuallyQuiet

        var suppressesAmbient: Bool { self != .available }
        var message: String? {
            switch self {
            case .available: nil
            case .focusOn: "Doorstep audio is paused while Focus is on."
            case .focusAccessRequired: "Allow Focus access to enable doorstep audio safely."
            case .focusStatusUnavailable: "Doorstep audio is paused because Focus status is unavailable."
            case .otherAppRecording: "Doorstep audio is paused while another app uses your microphone or camera."
            case .audioActivityUnavailable: "Doorstep audio is paused while microphone activity is unavailable."
            case .manuallyQuiet: "Quiet Door is on."
            }
        }
    }

    static func isOn() -> Bool { status().suppressesAmbient }

    // Set by packaging only when the restricted entitlement is provisioned.
    // Ad-hoc builds must neither claim support nor prompt for unavailable access.
    static var supportsFocusStatus: Bool {
        Bundle.main.object(forInfoDictionaryKey: "DoorbellFocusStatusEnabled") as? Bool == true
    }

    static func status(ignoringOwnCamera: Bool = false,
                       focusSupported: Bool = supportsFocusStatus,
                       focus: () -> Status = focusStatus,
                       camera: () -> Bool? = cameraInUse,
                       processes: () -> [AudioProcess]? = audioProcesses) -> Status {
        if let forced = ProcessInfo.processInfo.environment["DOORBELL_QUIET"] {
            return forced != "0" ? .manuallyQuiet : .available
        }
        // The ad-hoc beta uses the notch moon for manual DND. Only provisioned
        // builds query system Focus; activity checks apply to both distributions.
        if focusSupported {
            let status = focus()
            if status.suppressesAmbient { return status }
        }
        if !ignoringOwnCamera {
            guard let cameraActive = camera() else { return .audioActivityUnavailable }
            if cameraActive { return .otherAppRecording }
        }
        guard let processes = processes() else { return .audioActivityUnavailable }
        return shouldSuppressAmbient(focused: false, processes: processes,
            ownPID: ProcessInfo.processInfo.processIdentifier) ? .otherAppRecording : .available
    }

    private static func focusStatus() -> Status {
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized else { return .focusAccessRequired }
        guard let focused = center.focusStatus.isFocused else { return .focusStatusUnavailable }
        return focused ? .focusOn : .available
    }

    /// Call only from the user enabling doorstep audio. Never prompt on a knock.
    @MainActor static func requestFocusAccess() async -> Bool {
        guard supportsFocusStatus else { return false }
        let status = await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    static func shouldSuppressAmbient(focused: Bool?, processes: [AudioProcess]?, ownPID: Int32) -> Bool {
        guard focused == false, let processes else { return true }
        return processes.contains { $0.pid != ownPID && $0.inputRunning }
    }

    /// Public CoreAudio process objects distinguish another app recording from
    /// Doorbell's own mic. Device-wide "running somewhere" includes our capture
    /// and would repeatedly mute/unmute us as soon as ambient audio started.
    private static func audioProcesses() -> [AudioProcess]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }
        var result: [AudioProcess] = []
        for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
            guard let pid = value(object, selector: kAudioProcessPropertyPID),
                  let running = value(object, selector: kAudioProcessPropertyIsRunningInput) else { return nil }
            result.append(AudioProcess(pid: Int32(bitPattern: pid), inputRunning: running != 0))
        }
        return result
    }

    /// CMIO has no process-owner equivalent. The caller tells us when Doorbell
    /// is itself capturing video; never infer another app from our own camera.
    private static func cameraInUse() -> Bool? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else { return nil }
        var running = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        for device in devices.prefix(Int(used) / MemoryLayout<CMIODeviceID>.size) {
            var flag: UInt32 = 0
            var flagSize = UInt32(MemoryLayout<UInt32>.size)
            guard CMIOObjectGetPropertyData(device, &running, 0, nil, flagSize, &flagSize, &flag) == noErr else { return nil }
            if flag != 0 { return true }
        }
        return false
    }

    private static func value(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }
}
