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

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel()
        panel?.show()
    }
}
