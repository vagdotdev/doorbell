import AppKit
import SwiftUI

@main
struct DoorbellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        MenuBarExtra("Doorbell", systemImage: "bell") {
            Button("Open Doorbell…") { appDelegate.openDoorbell() }.keyboardShortcut(",")
            Divider()
            Button("Quit Doorbell") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Open Doorbell…") { appDelegate.openDoorbell() }.keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = AudioDevices.shared
        panel = NotchPanel()
        panel?.show()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where AppConfig.acceptsAuthCallback(url) { panel?.handleAuthCallback(url) }
    }
    func openDoorbell() { panel?.openAppWindow() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDoorbell()
        return true
    }
}
