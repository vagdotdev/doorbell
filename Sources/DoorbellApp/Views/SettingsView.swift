import AppKit
import AVFoundation
import LiveKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var door: DoorController
    @AppStorage(SettingsKey.peepholeStyle) private var peephole: PeepholeStyle = .eyehole
    @AppStorage(SettingsKey.soundsEnabled) private var sounds = true
    @AppStorage(SettingsKey.freshRing) private var freshRing = FreshRing.isEnabled
    @StateObject private var mic = MicrophoneMode()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubHeader("Settings")

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    OpenDoorPolicyCard()
                    DoorstepAudioCard()

                    if hallway.me != nil {
                        ProfileCard()
                    }

                    VStack(spacing: 0) {
                        SettingRow(title: door.quietLabel) {
                            Toggle("Quiet door", isOn: $door.quiet)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .help("Pauses automatic walk-ins and doorstep audio for 6 hours. You can still accept calls.")
                        }
                        Divider().overlay(DesignTokens.hairline)
                        SettingRow(title: "Glass") {
                            HStack(spacing: 10) {
                                ForEach(PeepholeStyle.allCases) { style in
                                    Button {
                                        withAnimation(.easeOut(duration: 0.15)) { peephole = style }
                                    } label: {
                                        GlassSwatch(style: style, selected: peephole == style)
                                    }
                                    .buttonStyle(.plain)
                                    .help(style.label)
                                    .accessibilityLabel("Glass: \(style.label)")
                                    .accessibilityAddTraits(peephole == style ? .isSelected : [])
                                }
                            }
                        }
                        Divider().overlay(DesignTokens.hairline)
                        SettingRow(title: "Sounds") {
                            Toggle("", isOn: $sounds)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .tint(DesignTokens.utility)
                        }
                        Divider().overlay(DesignTokens.hairline)
                        MicrophoneInputRow()
                        Divider().overlay(DesignTokens.hairline)
                        SettingRow(title: "Mic mode") {
                            PillButton(title: mic.label) { MicrophoneMode.choose() }
                        }
                        Divider().overlay(DesignTokens.hairline)
                        FreshRingRow(freshRing: $freshRing)
                    }
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DesignTokens.raised)
                    )
                }
                .padding(.bottom, 4)
            }
            .defaultScrollAnchor(.top)

            HStack(spacing: 4) {
                Text("Doorbell")
                if let me = hallway.me {
                    Text("·")
                    Text("@\(me.handle)")
                }
                Spacer()
                if AppConfig.current.isLive {
                    Button("Sign Out") { hallway.signOut() }
                        .disabled(hallway.isSigningOut)
                        .buttonStyle(.plain)
                        .foregroundStyle(DesignTokens.inkSecondary)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(DesignTokens.inkTertiary)
            .padding(.top, 8)
        }
        .padding(.horizontal, 18)
        // Keep the account row clear of the shell's persistent bottom tools.
        .padding(.bottom, 24)
    }
}

/// The same LiveKit input selection used in the call, available before joining.
/// Merely opening Settings never changes the selected hardware or starts capture.
private struct MicrophoneInputRow: View {
    @State private var devices: [AudioDevice] = []
    @State private var currentID = "system"
    @State private var currentName = "System default"
    @State private var defaultName: String?

    var body: some View {
        SettingRow(title: "Microphone") {
            Menu {
                Button {
                    AudioManager.shared.inputDevice = AudioManager.shared.defaultInputDevice
                    refresh()
                } label: {
                    Label(defaultName.map { "System default · \($0)" } ?? "System default",
                          systemImage: currentID == "system" ? "checkmark" : "mic")
                }
                Divider()
                ForEach(devices.filter { !$0.isDefault }) { device in
                    Button {
                        AudioManager.shared.inputDevice = device
                        refresh()
                    } label: {
                        Label(device.name, systemImage: currentID == device.deviceId ? "checkmark" : "mic")
                    }
                }
                if devices.filter({ !$0.isDefault }).isEmpty {
                    Text("No microphone found")
                }
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if currentID == "system", let defaultName {
                        Text(defaultName)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 245, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Microphone input")
            .accessibilityValue(currentID == "system" ? defaultName ?? currentName : currentName)
            .help("Choose the microphone Doorbell uses for knocks and calls.")
        }
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
        }
    }

    private func refresh() {
        let manager = AudioManager.shared
        devices = manager.inputDevices
        let selected = manager.inputDevice
        currentID = selected.isDefault ? "system" : selected.deviceId
        currentName = selected.isDefault ? "System default" : selected.name
        defaultName = AVCaptureDevice.default(for: .audio)?.localizedName
    }
}

/// A deliberate invitation: the first setting, with room to explain what it means.
private struct OpenDoorPolicyCard: View {
    @EnvironmentObject private var door: DoorController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var policyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: door.openDoorPolicy ? "door.left.hand.open" : "door.left.hand.closed")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(door.openDoorPolicy ? DesignTokens.openDoor : DesignTokens.inkSecondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(DesignTokens.openDoor.opacity(0.08)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open Door Policy")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    Text(status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(door.openDoorPolicy && !door.effectiveDoorQuiet ? DesignTokens.openDoor : DesignTokens.inkSecondary)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
                if door.isUpdatingOpenDoorPolicy {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Saving Open Door Policy")
                }
                Toggle("Open Door Policy", isOn: $door.openDoorPolicy)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DesignTokens.openDoor)
                    .focused($policyFocused)
                    .disabled(door.isUpdatingOpenDoorPolicy)
                    .accessibilityHint("Allow friends to walk in without you accepting each knock.")
            }

            Text("In a hostel room, you leave your door open and anybody can walk in.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            Text("On Doorbell, only your friends can walk in. Paused during Quiet Door or calls in other apps or rooms. You can still accept.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if let problem = door.openDoorPolicyProblem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.social)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Open Door Policy: \(problem)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DesignTokens.raised))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(door.openDoorPolicy ? DesignTokens.openDoor.opacity(0.24) : DesignTokens.hairline, lineWidth: 1)
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: door.openDoorPolicy)
        .animation(.easeOut(duration: 0.18), value: door.effectiveDoorQuiet)
        // macOS otherwise chooses Profile's TextField and scrolls this first
        // setting out of view as soon as Settings opens.
        .defaultFocus($policyFocused, true)
        .onAppear { policyFocused = true }
    }

    private var status: String {
        if door.isUpdatingOpenDoorPolicy { return "Saving…" }
        if !door.openDoorPolicy { return "Off" }
        if door.focusAccessNeeded { return "On · allow Focus access to open" }
        return door.effectiveDoorQuiet ? "On · paused" : "On · come on in"
    }
}

private struct DoorstepAudioCard: View {
    @EnvironmentObject private var door: DoorController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Doorstep audio", systemImage: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.ink)
            Text("Quiet voices through the door. Pauses during Quiet Door or while another app uses your mic or camera.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            Text("Tap the moon in the notch for 6 hours of Quiet Door. Tap again to end it early.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !Quiet.supportsFocusStatus {
                Text("This beta uses your moon toggle instead of macOS Focus. Use it for DND or meetings with your mic and camera off.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            } else if door.focusAccessNeeded {
                Text("Doorstep audio and automatic walk-ins stay paused until Doorbell can read your Focus status. You can still accept calls.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                PillButton(title: "Allow Focus access") { door.requestFocusAccess() }
                    .accessibilityHint("Allow Doorbell to check Focus before playing doorstep audio or letting someone walk in.")
            }

            if let problem = door.focusAccessProblem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.social)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Focus access: \(problem)")
            }
            if door.microphoneAccessNeeded {
                Text("Your mic stays off until you allow it. Listening never turns it on.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PillButton(title: "Allow microphone") { door.requestMicrophoneAccess() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DesignTokens.raised))
    }
}

/// Email, photo, name, handle — scaled to the shell.
private struct ProfileCard: View {
    @EnvironmentObject private var hallway: HallwayStore
    @State private var name = ""
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let email = hallway.email {
                SettingRow(title: "Email") {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.inkSecondary)
                        .lineLimit(1)
                }
                Divider().overlay(DesignTokens.hairline)
            }

            HStack(alignment: .center, spacing: 10) {
                Text("Photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.ink)
                Spacer(minLength: 4)
                if let me = hallway.me {
                    AvatarView(profile: me, size: 28)
                }
                PillButton(title: "Upload") { pickPhoto() }
                    .disabled(busy)
                if hallway.me?.avatarURL != nil {
                    PillButton(title: "Remove") { removePhoto() }
                        .disabled(busy)
                }
            }
            .frame(minHeight: 36)

            Divider().overlay(DesignTokens.hairline)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Name")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.ink)
                    Spacer(minLength: 4)
                    TextField("Your name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.ink)
                        .multilineTextAlignment(.trailing)
                        .focused($nameFocused)
                        .onSubmit(saveName)
                        .onChange(of: nameFocused) { _, on in if !on { saveName() } }
                        .disabled(nameLocked)
                        .frame(maxWidth: 180)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                .frame(height: 36)
                if let hint = nameHint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Divider().overlay(DesignTokens.hairline)

            SettingRow(title: "Handle") {
                if let me = hallway.me {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("@\(me.handle)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignTokens.social)
                        Text("Permanent")
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.inkTertiary)
                    }
                }
            }

            if let problem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.social)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesignTokens.raised)
        )
        .onAppear { name = hallway.me?.displayName ?? "" }
        .onChange(of: hallway.me?.displayName) { _, next in
            if !nameFocused, let next { name = next }
        }
    }

    private var nameLocked: Bool {
        guard let quota = hallway.nameQuota else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return quota.remaining == 0 && trimmed != hallway.me?.displayName
    }

    private var nameHint: String? {
        guard let quota = hallway.nameQuota else { return nil }
        if quota.remaining == 0, let resetsAt = quota.resetsAt {
            return "Name changes reset \(resetsAt.formatted(.relative(presentation: .named)))"
        }
        if quota.remaining == 1 {
            return "One name change left in the next 14 days"
        }
        return nil
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !busy, !trimmed.isEmpty, trimmed != hallway.me?.displayName, !nameLocked else { return }
        busy = true
        problem = nil
        Task {
            do { try await hallway.updateProfile(displayName: trimmed) }
            catch {
                let text = error.localizedDescription
                problem = text.localizedCaseInsensitiveContains("14 days")
                    ? text
                    : "Couldn't save that name"
            }
            busy = false
        }
    }

    private func pickPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .webP, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a profile photo"
        // An agent app is never frontmost; without this the picker can open behind
        // whatever the person is working in.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        problem = nil
        Task {
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "image/jpeg"
                if let jpeg = Self.prepare(data) {
                    try await hallway.setAvatar(jpegOrPng: jpeg, contentType: "image/jpeg")
                } else {
                    try await hallway.setAvatar(jpegOrPng: data, contentType: type)
                }
            } catch {
                problem = "Couldn't use that photo"
            }
            busy = false
        }
    }

    private func removePhoto() {
        busy = true
        problem = nil
        Task {
            do { try await hallway.clearAvatar() }
            catch { problem = "Couldn't remove that photo" }
            busy = false
        }
    }

    /// Downscale and re-encode as JPEG so Convex storage stays light.
    private static func prepare(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 512 ? 512 / longest : 1
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

/// The glass at peephole size: a circle for Round, a wide rect for Wide.
/// Selected glass takes the utility accent.
private struct GlassSwatch: View {
    let style: PeepholeStyle
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            switch style {
            case .eyehole:
                Circle()
                    .strokeBorder(rim, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
            case .rectangle:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(rim, lineWidth: 1.5)
                    .frame(width: 30, height: 18)
            }
        }
        .background(Circle().fill(DesignTokens.utility.opacity(selected ? 0.12 : 0)))
        .frame(width: 34, height: 26)
        .onHover { hovering = $0 }
    }

    private var rim: Color {
        selected ? DesignTokens.utility
            : (hovering ? DesignTokens.inkSecondary : DesignTokens.inkTertiary)
    }
}

private struct FreshRingRow: View {
    @ObservedObject private var freshRingStatus = FreshRing.shared
    @Binding var freshRing: Bool

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(title: "Version") {
                Text(freshRingStatus.currentVersion)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(freshRingStatus.currentVersion)
            }
            Divider().overlay(DesignTokens.hairline)
            SettingRow(title: "Fresh Ring") {
                Toggle("Automatic updates", isOn: $freshRing)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!freshRingStatus.supportsAutomaticUpdates || freshRingStatus.phase == .applying)
                    .help("Checks for updates when Doorbell opens. Restarts only when your door is free.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Automatic updates, once each launch. Calls and knocks come first.")
                    .foregroundStyle(DesignTokens.inkSecondary)
                Text("Your account, friends and preferences stay saved.")
                    .foregroundStyle(DesignTokens.inkSecondary)
                if !freshRingStatus.supportsAutomaticUpdates {
                    Text(freshRingStatus.unavailableReason ?? "Updates are available in the installed app.")
                        .foregroundStyle(DesignTokens.inkSecondary)
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        if isWorking {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel(status)
                        }
                        Text(status)
                            .foregroundStyle(isFailed ? DesignTokens.social : DesignTokens.inkSecondary)
                        Spacer(minLength: 0)
                        action
                    }
                    if freshRingStatus.phase == .ready, let tag = freshRingStatus.latestTag {
                        Text("New build · \(tag)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(DesignTokens.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(tag)
                    }
                }
            }
            .font(.system(size: 10))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
        }
        .onChange(of: freshRing) { _, _ in freshRingStatus.preferenceChanged() }
        .task {
            while !Task.isCancelled {
                freshRingStatus.refreshBusyState()
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { break }
            }
        }
    }

    private var isWorking: Bool {
        freshRingStatus.phase == .checking || freshRingStatus.phase == .downloading || freshRingStatus.phase == .applying
    }

    private var isFailed: Bool {
        if case .failed = freshRingStatus.phase { return true }
        return false
    }

    private var status: String {
        switch freshRingStatus.phase {
        case .idle: return freshRing ? "Ready to check for updates." : "Automatic updates are off."
        case .checking: return "Checking for an update…"
        case .downloading: return "Downloading and verifying…"
        case .ready:
            return freshRingStatus.isBusyNow ? "Downloaded. Waiting until your door is free." : "Downloaded. Ready to install."
        case .applying: return "Checking the update before restarting…"
        case .upToDate: return "You’re up to date."
        case .failed(let why): return why
        }
    }

    @ViewBuilder private var action: some View {
        switch freshRingStatus.phase {
        case .ready:
            PillButton(title: "Restart to update", prominent: true) { freshRingStatus.installNow() }
                .disabled(!freshRingStatus.canInstallNow)
                .help(freshRingStatus.isBusyNow ? "Finish your call or knock before restarting." : "Install the verified update and reopen Doorbell.")
        case .idle, .upToDate:
            PillButton(title: "Check now") { freshRingStatus.checkAgain() }
        case .failed:
            PillButton(title: "Retry") { freshRingStatus.checkAgain() }
        case .checking, .downloading, .applying:
            EmptyView()
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.ink)
            Spacer(minLength: 8)
            control
        }
        .frame(height: 36)
    }
}
