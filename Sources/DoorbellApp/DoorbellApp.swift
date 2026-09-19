import AppKit
import SwiftUI

@main
struct DoorbellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Agent app: no main window, only the notch panel.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.reopen()
        return true
    }

    func applicationDidFinishLaunching(_: Notification) {
        // First launch: a real app with a Dock icon until onboarding finishes.
        // Returning users stay a notch-only accessory.
        NSApp.setActivationPolicy(AppConfig.hasStoredSession ? .accessory : .regular)
        // The Dock shows this during first launch, when the app briefly has a window.
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        panel = NotchPanel()
        panel?.show()
        FreshRing.shared.registerBusyCheck { [weak panel] in
            guard let door = panel?.doorForUpdates else { return false }
            return door.blocksAutomaticUpdate
        }
        FreshRing.shared.checkOnLaunch()
    }
}
