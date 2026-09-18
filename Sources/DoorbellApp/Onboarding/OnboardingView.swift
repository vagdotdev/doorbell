import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Splash → name and permanent @handle → camera and mic. Then the window closes.
struct OnboardingView: View {
    let done: () -> Void
    @EnvironmentObject private var hallway: HallwayStore
    @State private var step: Step = .welcome

    private static let previewMe = Profile(id: "preview", handle: "you", displayName: "You")

    private enum Step: Int, Comparable {
        case welcome, identity, permissions
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    init(done: @escaping () -> Void) {
        self.done = done
        // Capture our own setup screens without entering a real account.
        let env = ProcessInfo.processInfo.environment
        if env["DOORBELL_SNAPSHOT"] != nil {
            switch env["DOORBELL_ONBOARDING_STEP"] {
            case "identity": _step = State(initialValue: .identity)
            case "permissions": _step = State(initialValue: .permissions)
            default: break
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if step == .welcome {
                IntroPlumeView(
                    me: hallway.me ?? Self.previewMe,
                    friends: hallway.orderedDoors.map(\.profile)
                ) {
                    advance(to: .identity)
                }
                .frame(height: 200)
            } else {
                Color.black.frame(height: 96)
            }

            ZStack {
                switch step {
                case .welcome:
                    WelcomeStep { advance(to: .identity) }
                case .identity: IdentityStep()
                case .permissions: PermissionsStep(done: done)
                }
            }
            .transition(.opacity.combined(with: .offset(x: 18)))
            .id(step)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
            .padding(.horizontal, 48)

            VagdevCredit()
                .padding(.top, 28)
                .padding(.bottom, 8)
            Dots(count: 3, current: step.rawValue)
                .padding(.bottom, 20)
        }
        .frame(width: 480, height: 560)
        .background(Color.black)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: step)
        .onChange(of: hallway.account) { _, account in
            // Signed in mid-flow (e.g. env hook) — skip identity, finish permissions.
            if account == .ready, step == .identity { advance(to: .permissions) }
        }
    }

    private func advance(to next: Step) {
        withAnimation(.easeInOut(duration: 0.28)) {
            step = next == .identity && hallway.account == .ready ? .permissions : next
        }
    }
}

// MARK: - Beats

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            BigButton(title: "Continue", prominent: true, action: next)
        }
    }
}

private struct IdentityStep: View {
    @EnvironmentObject private var hallway: HallwayStore
    @State private var name = ""
    @State private var handle = ""
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var focus: Field?
    private enum Field { case name, handle }

    private var cleaned: String {
        handle.lowercased().filter { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "_" }
    }
    private var valid: Bool {
        (3...20).contains(cleaned.count) && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 14) {
            WindowField("Your name", text: $name)
                .focused($focus, equals: .name)
                .onSubmit { focus = .handle }
            WindowField("handle", text: $handle, prefix: "@")
                .focused($focus, equals: .handle)
                .onSubmit(join)
            Text(problem ?? (busy ? "One moment" : "Permanent — can't change later"))
                .font(.system(size: 11.5))
                .foregroundStyle(problem == nil ? DesignTokens.inkTertiary : DesignTokens.social)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            BigButton(title: "Join", prominent: true, enabled: valid && !busy, action: join)
                .padding(.top, 4)
        }
        .onAppear { focus = .name }
    }

    private func join() {
        guard valid, !busy else { return }
        busy = true
        problem = nil
        let display = name.trimmingCharacters(in: .whitespaces)
        Task {
            do { try await hallway.join(handle: cleaned, displayName: display) }
            catch { problem = joinProblem(handle: cleaned, error: error) }
            busy = false
        }
    }
}

private struct PermissionsStep: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                PermissionRow(symbol: "video.fill", title: "Camera", media: .video)
                Divider().overlay(DesignTokens.hairline)
                PermissionRow(symbol: "mic.fill", title: "Microphone", media: .audio)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DesignTokens.raised))
            BigButton(title: "Done", prominent: true, action: done)
                .padding(.top, 4)
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let media: AVMediaType
    @State private var status: AVAuthorizationStatus

    init(symbol: String, title: String, media: AVMediaType) {
        self.symbol = symbol
        self.title = title
        self.media = media
        _status = State(initialValue: AVCaptureDevice.authorizationStatus(for: media))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.inkSecondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.ink)
            Spacer(minLength: 8)
            switch status {
            case .authorized:
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DesignTokens.openDoor)
            case .denied, .restricted:
                BigButton(title: "Open Settings", action: openSettings)
            default:
                BigButton(title: "Allow", action: ask)
            }
        }
        .frame(height: 54)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = AVCaptureDevice.authorizationStatus(for: media)
        }
    }

    private func ask() {
        let media = media
        Task {
            _ = await AVCaptureDevice.requestAccess(for: media)
            status = AVCaptureDevice.authorizationStatus(for: media)
        }
    }

    private func openSettings() {
        let pane = media == .video ? "Privacy_Camera" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Pieces

private struct WindowField: View {
    let title: String
    @Binding var text: String
    var prefix: String?

    init(_ title: String, text: Binding<String>, prefix: String? = nil) {
        self.title = title
        _text = text
        self.prefix = prefix
    }

    var body: some View {
        HStack(spacing: 6) {
            if let prefix {
                Text(prefix)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.ink)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Capsule().fill(DesignTokens.raised))
        .overlay(Capsule().strokeBorder(DesignTokens.hairline, lineWidth: 1))
    }
}

private struct BigButton: View {
    let title: String
    var prominent = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? .black : DesignTokens.ink)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .background(
                    Capsule().fill(prominent
                                   ? DesignTokens.utility.opacity(hovering ? 1 : 0.9)
                                   : (hovering ? .white.opacity(0.12) : DesignTokens.raised))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

private struct Dots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? DesignTokens.ink.opacity(0.9) : .white.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
    }
}
