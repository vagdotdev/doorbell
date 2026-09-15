import AppKit

/// Development: `DOORBELL_SNAPSHOT=/tmp/door.png` writes the panel to disk and quits.
/// Capturing our own window needs no screen-recording permission, so agents and CI
/// can look at every state. `DOORBELL_SNAPSHOT_DELAY` (seconds, default 3.5) leaves
/// time for springs to settle and for `DOORBELL_SIMULATE` to fire.
@MainActor
enum Snapshot {
    static func armIfRequested(window: NSWindow) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DOORBELL_SNAPSHOT"] else { return }
        let delay = env["DOORBELL_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3.5
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let url = URL(fileURLWithPath: path)
            write(window: window, to: url)
            // Any other window (the room) lands beside it as <name>-room.png.
            for other in NSApp.windows where other !== window && other.isVisible {
                let name = url.deletingPathExtension().lastPathComponent + "-room"
                write(window: other, to: url.deletingLastPathComponent().appendingPathComponent(name + ".png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func write(window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            FileHandle.standardError.write(Data("snapshot: capture failed\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
