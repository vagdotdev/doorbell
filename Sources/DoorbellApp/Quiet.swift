import CoreAudio
import CoreMediaIO
import Foundation

/// Do not disturb, decided on this Mac at the moment of a knock and never published.
/// Quiet when a Focus is on, or when some other app has the camera or microphone —
/// a Meet in the browser, Zoom, FaceTime all look the same from here.
enum Quiet {
    static func isOn() -> Bool {
        if let forced = ProcessInfo.processInfo.environment["DOORBELL_QUIET"] { return forced != "0" }
        return focusIsOn() || cameraInUse() || microphoneInUse()
    }

    /// macOS has no public API for Focus. The assertions file is what every menu-bar
    /// DND indicator reads: any active record means a Focus is on.
    private static func focusIsOn() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return false }
        return entries.contains { entry in
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { return false }
            return !records.isEmpty
        }
    }

    /// Any camera streaming anywhere, in any process.
    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0,
              size > 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0
        else { return false }
        var running = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        return devices.contains { device in
            var flag: UInt32 = 0
            var flagSize = UInt32(MemoryLayout<UInt32>.size)
            return CMIOObjectGetPropertyData(device, &running, 0, nil, flagSize, &flagSize, &flag) == 0 && flag != 0
        }
    }

    /// Any input device running anywhere, in any process.
    private static func microphoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == 0,
              size > 0 else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == 0
        else { return false }
        return devices.contains { device in
            // Only devices that have input streams count; a running speaker is not a call.
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == 0, streamSize > 0 else { return false }
            var running = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var flag: UInt32 = 0
            var flagSize = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &running, 0, nil, &flagSize, &flag) == 0 && flag != 0
        }
    }
}
