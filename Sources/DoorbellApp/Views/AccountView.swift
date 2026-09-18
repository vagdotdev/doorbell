import SwiftUI

/// Name yourself and walk in. No email, no password on screen — friends pick a
/// name and an @handle. Under the hood the app uses `{handle}@doorbell.local`
/// plus `DOORBELL_JOIN_SECRET` so the same handle works on another Mac.
struct AccountView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var state: NotchState

    var body: some View {
        Group {
            switch hallway.account {
            case .signedOut, .needsHandle:
                JoinForm()
            case .ready:
                EmptyView()
            case .unavailable:
                VStack(spacing: 12) {
                    Text("Doorbell can’t connect right now.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignTokens.ink)
                    PillButton(title: "Try Again", prominent: true) { Task { await hallway.refresh() } }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .onTapGesture { state.mode = .account }
    }
}

private struct JoinForm: View {
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
        VStack(alignment: .leading, spacing: 10) {
            Text(hallway.account == .needsHandle ? "Almost — pick your name" : "Who are you?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            HStack(spacing: 8) {
                ShellField("Your name", text: $name)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .handle }
                ShellField("handle", text: $handle, prefix: "@")
                    .focused($focus, equals: .handle)
                    .onSubmit(join)
            }
            HStack(spacing: 8) {
                PillButton(title: "Join", prominent: true, action: join)
                    .disabled(busy || !valid)
                Spacer()
                Text(problem ?? (busy ? "One moment" : "Friends find you by @\(cleaned.isEmpty ? "handle" : cleaned)"))
                    .font(.system(size: 11))
                    .foregroundStyle(problem == nil ? DesignTokens.inkTertiary : DesignTokens.social)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .onAppear { focus = .name }
    }

    private func join() {
        guard valid else { return }
        busy = true
        problem = nil
        let display = name.trimmingCharacters(in: .whitespaces)
        Task {
            do { try await hallway.join(handle: cleaned, displayName: display) }
            catch {
                let text = error.localizedDescription
                if text.localizedCaseInsensitiveContains("taken") {
                    problem = "@\(cleaned) is taken"
                } else {
                    problem = "Couldn’t connect. Try again in a moment."
                }
            }
            busy = false
        }
    }
}

/// A text field in the shell's raised capsule.
private struct ShellField: View {
    let title: String
    @Binding var text: String
    var secure = false
    var prefix: String?

    init(_ title: String, text: Binding<String>, secure: Bool = false, prefix: String? = nil) {
        self.title = title
        _text = text
        self.secure = secure
        self.prefix = prefix
    }

    var body: some View {
        HStack(spacing: 6) {
            if let prefix {
                Text(prefix)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
            Group {
                if secure { SecureField(title, text: $text) } else { TextField(title, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DesignTokens.ink)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(DesignTokens.raised))
    }
}
