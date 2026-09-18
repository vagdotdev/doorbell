import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var door: DoorController
    @AppStorage(SettingsKey.peepholeStyle) private var peephole: PeepholeStyle = .eyehole
    @AppStorage(SettingsKey.soundsEnabled) private var sounds = true
    @StateObject private var mic = MicrophoneMode()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubHeader("Settings")

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if hallway.me != nil {
                        ProfileCard()
                    }

                    VStack(spacing: 0) {
                        SettingRow(title: "Quiet door") {
                            Toggle("Quiet door", isOn: $door.quiet)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .help("No automatic walk-ins or door audio. You choose when to answer.")
                        }
                        Divider().overlay(DesignTokens.hairline)
                        SettingRow(title: "Glass") {
                            SegmentedPills(options: PeepholeStyle.allCases, selection: $peephole) { $0.label }
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
                        SettingRow(title: "Microphone") {
                            PillButton(title: mic.label) { MicrophoneMode.choose() }
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DesignTokens.raised)
                    )
                }
                .padding(.bottom, 4)
            }

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
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
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
                    .frame(maxWidth: 180)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }
            .frame(height: 36)

            Divider().overlay(DesignTokens.hairline)

            SettingRow(title: "Handle") {
                if let me = hallway.me {
                    Text("@\(me.handle)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.social)
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

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !busy, !trimmed.isEmpty, trimmed != hallway.me?.displayName else { return }
        busy = true
        problem = nil
        Task {
            do { try await hallway.updateProfile(displayName: trimmed) }
            catch { problem = "Couldn't save that name" }
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
