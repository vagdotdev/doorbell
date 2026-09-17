import AppKit
import SwiftUI

@MainActor
final class AppWindowModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case friends = "Friends", audio = "Audio", window = "Window", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .friends: "person.2"
            case .audio: "waveform"
            case .window: "macwindow"
            case .settings: "gearshape"
            }
        }
    }
    @Published var page: Page = .friends
    @Published var introSeen: Bool
    @Published private(set) var completed: Set<String>
    var finish: (() -> Void)?
    private let prefix: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, profile: String = AppConfig.current.profile) {
        self.defaults = defaults
        prefix = "onboarding.v1.\(profile)"
        introSeen = defaults.bool(forKey: prefix + ".intro")
        completed = Set(defaults.stringArray(forKey: prefix + ".accounts") ?? [])
    }
    func next() {
        introSeen = true
        defaults.set(true, forKey: prefix + ".intro")
    }
    func complete(_ id: String) {
        completed.insert(id)
        defaults.set(Array(completed), forKey: prefix + ".accounts")
        finish?()
    }
}

/// One retained window, shared by first launch, the notch gear and the menu bar.
@MainActor
final class AppWindowController: NSWindowController {
    let model = AppWindowModel()
    init(hallway: HallwayStore, door: DoorController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Doorbell"
        window.identifier = NSUserInterfaceItemIdentifier("DoorbellAppWindow")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.minSize = NSSize(width: 740, height: 560)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("DoorbellAppWindow")
        super.init(window: window)
        window.contentView = NSHostingView(rootView: AppWindowView()
            .environmentObject(hallway).environmentObject(model).environmentObject(door)
            .environment(\.colorScheme, .dark)).fillingContainer()
        window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    func present(page: AppWindowModel.Page? = nil) {
        if let page { model.page = page }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
