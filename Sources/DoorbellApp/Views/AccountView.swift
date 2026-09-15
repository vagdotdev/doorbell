import SwiftUI

/// The front door of the app itself: sign in, then take a handle. Two quiet screens
/// in the board; no window, no wizard.
struct AccountView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var state: NotchState

    var body: some View {
        Group {
            switch hallway.account {
            case .signedOut: SignInForm()
            case .needsHandle: HandleForm()
            case .ready: EmptyView()
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        // Clicking into the form pins the shell open; clicking elsewhere lets it go.
        .onTapGesture { state.mode = .account }
    }
}

private struct SignInForm: View {
    @EnvironmentObject private var hallway: HallwayStore
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your door")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            HStack(spacing: 8) {
                ShellField("Email", text: $email)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
                ShellField("Password", text: $password, secure: true)
                    .focused($focus, equals: .password)
                    .onSubmit { go(create: false) }
            }
            HStack(spacing: 8) {
                PillButton(title: "Sign In", prominent: true) { go(create: false) }
                PillButton(title: "Create Account") { go(create: true) }
                Spacer()
                Text(problem ?? (busy ? "One moment" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(problem == nil ? DesignTokens.inkTertiary : DesignTokens.social)
                    .lineLimit(1)
            }
            .disabled(busy || email.isEmpty || password.count < 6)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .onAppear { focus = .email }
    }

    private func go(create: Bool) {
        busy = true
        problem = nil
        Task {
            do {
                if create { try await hallway.signUp(email: email, password: password) }
                else { try await hallway.signIn(email: email, password: password) }
            } catch {
                problem = create ? "Couldn't create that account" : "That didn't match"
            }
            busy = false
        }
    }
}

private struct HandleForm: View {
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
    private var valid: Bool { (3...20).contains(cleaned.count) && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Put a name on the door")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            HStack(spacing: 8) {
                ShellField("Your name", text: $name)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .handle }
                ShellField("handle", text: $handle, prefix: "@")
                    .focused($focus, equals: .handle)
                    .onSubmit(claim)
            }
            HStack(spacing: 8) {
                PillButton(title: "Done", prominent: true, action: claim)
                    .disabled(busy || !valid)
                Spacer()
                Text(problem ?? "Friends find you by @\(cleaned.isEmpty ? "handle" : cleaned)")
                    .font(.system(size: 11))
                    .foregroundStyle(problem == nil ? DesignTokens.inkTertiary : DesignTokens.social)
                    .lineLimit(1)
                PillButton(title: "Sign Out") { hallway.signOut() }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .onAppear { focus = .name }
    }

    private func claim() {
        guard valid else { return }
        busy = true
        problem = nil
        Task {
            do { try await hallway.claimHandle(cleaned, displayName: name.trimmingCharacters(in: .whitespaces)) }
            catch { problem = "@\(cleaned) is taken" }
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
