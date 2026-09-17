import AppKit
import LiveKit
import ServiceManagement
import SwiftUI

@MainActor
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var outputs: [AudioDevice] = []
    @Published var input = "default"
    @Published var output = "default"
    init() { refresh(); applySaved() }
    func refresh() {
        inputs = AudioManager.shared.inputDevices.filter { !$0.isDefault }
        outputs = AudioManager.shared.outputDevices.filter { !$0.isDefault }
    }
    func applySaved() {
        selectInput(UserDefaults.standard.string(forKey: SettingsKey.audioInput) ?? "default", persist: false)
        selectOutput(UserDefaults.standard.string(forKey: SettingsKey.audioOutput) ?? "default", persist: false)
    }
    func selectInput(_ id: String, persist: Bool = true) {
        let device = inputs.first { $0.id == id }
        AudioManager.shared.inputDevice = device ?? AudioManager.shared.defaultInputDevice
        input = device?.id ?? "default"
        if persist { UserDefaults.standard.set(input, forKey: SettingsKey.audioInput) }
    }
    func selectOutput(_ id: String, persist: Bool = true) {
        let device = outputs.first { $0.id == id }
        AudioManager.shared.outputDevice = device ?? AudioManager.shared.defaultOutputDevice
        output = device?.id ?? "default"
        if persist { UserDefaults.standard.set(output, forKey: SettingsKey.audioOutput) }
    }
}

struct AudioSettingsPage: View {
    @StateObject private var mic = MicrophoneMode()
    @ObservedObject private var devices = AudioDevices.shared
    @AppStorage(SettingsKey.doorVolume) private var volume = Double(DesignTokens.doorVolume)
    @AppStorage(SettingsKey.soundsEnabled) private var sounds = true
    var body: some View {
        PageHeading(title: "Audio")
        Picker("Input", selection: Binding(get: { devices.input }, set: { devices.selectInput($0) })) {
            Text("System Default").tag("default")
            ForEach(devices.inputs) { Text($0.name).tag($0.id) }
        }
        Picker("Output", selection: Binding(get: { devices.output }, set: { devices.selectOutput($0) })) {
            Text("System Default").tag("default")
            ForEach(devices.outputs) { Text($0.name).tag($0.id) }
        }
        // macOS's own Voice Isolation. The system owns the choice; we can only open its picker.
        HStack {
            Text("Voice Isolation")
            Spacer()
            Button(mic.label) { MicrophoneMode.choose() }
        }
        Divider()
        HStack {
            Text("Knock volume")
            Spacer()
            Text("\(Int(volume * 100))%").monospacedDigit().foregroundStyle(.secondary)
        }
        Slider(value: $volume, in: 0...1, step: 0.05) { Text("Knock volume") }.labelsHidden()
        Toggle("Sounds", isOn: $sounds).toggleStyle(.switch)
        .task {
            while !Task.isCancelled {
                devices.refresh()
                if devices.input != "default", !devices.inputs.contains(where: { $0.id == devices.input }) { devices.applySaved() }
                if devices.output != "default", !devices.outputs.contains(where: { $0.id == devices.output }) { devices.applySaved() }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}

struct WindowSettingsPage: View {
    @EnvironmentObject private var door: DoorController
    @AppStorage(SettingsKey.peepholeStyle) private var glass: PeepholeStyle = .eyehole
    @AppStorage(SettingsKey.roomOnNotchScreen) private var notchScreen = false
    @AppStorage(SettingsKey.roomFullscreen) private var fullscreen = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var approval = SMAppService.mainApp.status == .requiresApproval
    @State private var changingLogin = false
    @State private var problem: String?
    var body: some View {
        PageHeading(title: "Window")
        Text("Camera view").font(.headline)
        HStack(spacing: 16) {
            CameraViewOption(style: .rectangle, selected: glass == .rectangle) { glass = .rectangle }
            CameraViewOption(style: .eyehole, selected: glass == .eyehole) { glass = .eyehole }
        }
        Divider()
        Toggle("Do not disturb", isOn: Binding(get: { door.quiet }, set: { door.quiet = $0 })).toggleStyle(.switch)
        Text("Nobody walks in and nothing makes a sound. You still see who's knocking and can answer.")
            .font(.callout).foregroundStyle(.secondary)
        Divider()
        Toggle("Open rooms on the notch's screen", isOn: $notchScreen).toggleStyle(.switch)
        Text("Otherwise, new rooms open on the screen you're using.").font(.callout).foregroundStyle(.secondary)
        Toggle("Start rooms in fullscreen", isOn: $fullscreen).toggleStyle(.switch)
        Divider()
        Toggle("Launch at login", isOn: Binding(get: { login || approval }, set: { changeLogin($0) }))
            .toggleStyle(.switch).disabled(changingLogin || Bundle.main.bundleURL.pathExtension != "app")
        if approval {
            Text("Allow Doorbell in Login Items to finish enabling it.").font(.callout).foregroundStyle(.secondary)
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
        }
        if Bundle.main.bundleURL.pathExtension != "app" {
            Text("Launch the Doorbell app bundle to enable launch at login.").font(.caption).foregroundStyle(.secondary)
        }
        if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }
        Color.clear.frame(height: 0).onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readLogin() }
    }
    private func readLogin() {
        login = SMAppService.mainApp.status == .enabled
        approval = SMAppService.mainApp.status == .requiresApproval
    }
    private func changeLogin(_ on: Bool) {
        guard !changingLogin else { return }
        changingLogin = true; problem = nil
        Task {
            defer { changingLogin = false; readLogin() }
            do {
                if on { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { problem = "Couldn't change launch at login. Check Login Items in System Settings." }
        }
    }
}

/// The two shapes a friend's picture can take, drawn as themselves. Click one to pick it.
private struct CameraViewOption: View {
    let style: PeepholeStyle
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(hovering || selected ? 0.06 : 0.035))
                    if style == .rectangle {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(glass)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(rim, lineWidth: 1))
                            .frame(width: 96, height: 60)
                    } else {
                        Circle().fill(glass)
                            .overlay(Circle().strokeBorder(rim, lineWidth: 1))
                            .frame(width: 60, height: 60)
                    }
                }
                .frame(width: 150, height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? DesignTokens.utility : .clear, lineWidth: 2)
                )
                Text(style.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? .white : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var glass: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom)
    }
    private var rim: Color { .white.opacity(0.35) }
}

struct AccountSettingsPage: View {
    @EnvironmentObject private var hallway: HallwayStore
    @State private var name = ""
    @State private var confirmSignOut = false
    var body: some View {
        PageHeading(title: "Settings")
        if let me = hallway.me {
            HStack(spacing: 16) {
                AvatarView(profile: me, size: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text("@\(me.handle)").font(.title3.weight(.medium))
                    Text("Your handle stays the same.").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Display name", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
                .disabled(hallway.busy)
            Button(hallway.busy ? "Saving…" : "Save Name") { hallway.updateDisplayName(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .disabled(hallway.busy || !ProfileValidation.validName(name) || name.trimmingCharacters(in: .whitespacesAndNewlines) == me.displayName)
            Divider()
            Text("Permissions").font(.title3.weight(.semibold))
            PermissionsContent()
            Divider()
            if AppConfig.current.useSupabase {
                Button("Sign Out", role: .destructive) { confirmSignOut = true }.disabled(hallway.busy)
                Text("This ends your calls and signs out on this Mac.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("You're using a local demo. No account or network connection is needed.").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Text("Doorbell").font(.headline)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")")
                .font(.callout).foregroundStyle(.secondary)
        }
        Color.clear.frame(height: 0)
            .onAppear { name = hallway.me?.displayName ?? "" }
            .alert("Sign out of Doorbell?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) { hallway.signOut() }
            } message: { Text("Your current call will end. Your friends and settings will be here when you return.") }
    }
}
