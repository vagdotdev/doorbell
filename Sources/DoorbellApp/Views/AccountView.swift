import SwiftUI
import Supabase

struct AccountView: View {
    @EnvironmentObject private var hallway: HallwayStore
    var body: some View {
        Group {
            switch hallway.account {
            case .loading:
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Signing in…").foregroundStyle(.secondary) }
            case .unavailable(let message):
                VStack(alignment: .leading, spacing: 18) {
                    PageHeading(title: "Let's reconnect.", subtitle: message)
                    Button("Try Again") { Task { await hallway.refresh() } }.buttonStyle(.borderedProminent)
                    Button("Sign Out") { hallway.signOut() }.disabled(hallway.busy)
                }
            case .signedOut:
                if AppConfig.current.isLocalBackend { SignInForm() } else { ProviderSignInForm() }
            case .needsHandle: HandleForm()
            case .ready: EmptyView()
            }
        }
    }
}

private struct SignInForm: View {
    @EnvironmentObject private var hallway: HallwayStore
    @State private var email = ""
    @State private var password = ""
    @State private var create = false
    @State private var busy = false
    @State private var message: String?
    @FocusState private var focus: Field?
    private enum Field { case email, password }
    private var valid: Bool {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.contains("@") && !email.contains(" ") && !password.isEmpty && (!create || password.count >= 8)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: create ? "Create your account." : "Welcome back.",
                        subtitle: create ? "Then choose the handle your friends will find you by." : "Sign in to find your friends.")
            VStack(alignment: .leading, spacing: 8) {
                Text("Email").font(.callout)
                TextField("you@example.com", text: $email).textContentType(.emailAddress)
                    .focused($focus, equals: .email).onSubmit { focus = .password }
                Text("Password").font(.callout).padding(.top, 8)
                SecureField(create ? "At least 8 characters" : "Your password", text: $password)
                    .textContentType(create ? .newPassword : .password)
                    .focused($focus, equals: .password).onSubmit(go)
            }.textFieldStyle(.roundedBorder).controlSize(.large).disabled(busy)
            if let message {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                Button(busy ? "One moment…" : create ? "Create Account" : "Sign In", action: go)
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy || !valid)
                Button(create ? "I Have an Account" : "Create an Account") { create.toggle(); message = nil }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy)
            }
        }.onAppear { focus = .email }
    }
    private func go() {
        guard !busy, valid else { return }
        busy = true
        message = nil
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                if create { try await hallway.signUp(email: email, password: password) }
                else { try await hallway.signIn(email: email, password: password) }
                password = ""
            } catch BackendError.confirmEmail {
                message = BackendError.confirmEmail.localizedDescription
                create = false
                password = ""
            } catch let error as AuthError {
                message = error.message
            } catch {
                message = "Couldn't reach your account. Check your connection and try again."
            }
        }
    }
}

private struct HandleForm: View {
    @EnvironmentObject private var hallway: HallwayStore
    @State private var name = ""
    @State private var handle = ""
    @State private var busy = false
    @State private var checking = false
    @State private var available: Bool?
    @State private var message: String?
    private var cleaned: String { handle.lowercased() }
    private var valid: Bool { ProfileValidation.validHandle(cleaned) && ProfileValidation.validName(name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "Your name and handle.", subtitle: "Friends find you by your handle. Choose one you'll keep.")
            VStack(alignment: .leading, spacing: 8) {
                Text("Your name").font(.callout)
                TextField("Name", text: $name).textContentType(.name)
                Text("Handle").font(.callout).padding(.top, 8)
                TextField("e.g. alex_chen", text: $handle).onSubmit(claim)
                Text("3–20 characters · a–z, 0–9, underscore").font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).controlSize(.large).disabled(busy)
            Text(message ?? (checking ? "Checking handle…" : available == true ? "@\(cleaned) is available" : available == false ? "That handle is taken. Try another." : " "))
                .font(.callout).foregroundStyle(message != nil || available == false ? .orange : DesignTokens.utility)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Button(busy ? "Saving…" : "Continue", action: claim).buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(busy || !valid || checking || available == false)
                Button("Sign Out") { hallway.signOut() }.disabled(busy || hallway.busy)
            }
        }
        .task(id: cleaned) {
            available = nil; message = nil; checking = false
            guard ProfileValidation.validHandle(cleaned) else { return }
            let query = cleaned
            checking = true
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await hallway.isHandleAvailable(query)
                guard !Task.isCancelled, query == cleaned else { return }
                available = result; checking = false
            } catch {
                guard !Task.isCancelled, query == cleaned else { return }
                checking = false
                message = "Couldn't check availability. You can try saving again."
            }
        }
    }
    private func claim() {
        guard !busy, valid, !checking, available != false else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { try await hallway.claimHandle(cleaned, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch let error as PostgrestError where error.code == "23505" { message = "That handle was just taken. Try another."; available = false }
            catch { message = "Couldn't save your profile. Check your connection and try again." }
        }
    }
}

private struct ProviderSignInForm: View {
    @EnvironmentObject private var hallway: HallwayStore
    @State private var email = ""
    @State private var showEmail = false
    @State private var busy = false
    @State private var message: String?
    @State private var linkSent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "Sign in.", subtitle: "Then choose a handle and find your friends.")
            Button { authenticate(.apple) } label: {
                Label("Continue with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
            Button { authenticate(.google) } label: {
                Text("Continue with Google").frame(maxWidth: .infinity)
            }.controlSize(.large).disabled(busy)
            Button("Use an Email Link") { showEmail.toggle(); message = nil }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy)
            if showEmail {
                TextField("you@example.com", text: $email).textFieldStyle(.roundedBorder).controlSize(.large).textContentType(.emailAddress).disabled(busy)
                Button("Send Sign-In Link", action: sendLink).disabled(busy || !email.contains("@"))
            }
            if busy { ProgressView().controlSize(.small) }
            if let message = message ?? hallway.problem {
                Text(message).font(.callout).foregroundStyle(linkSent ? DesignTokens.utility : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func authenticate(_ provider: AccountProvider) {
        guard !busy else { return }
        busy = true; message = nil; linkSent = false
        Task {
            defer { busy = false }
            do { try await hallway.signIn(provider: provider) }
            catch { message = "Sign-in didn't finish. Try again or use an email link." }
        }
    }
    private func sendLink() {
        guard !busy else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), !address.contains(" ") else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await hallway.sendMagicLink(email: address)
                linkSent = true
                message = "Check your email. Open the sign-in link on this Mac to continue."
            } catch { linkSent = false; message = "Couldn't send the link. Check your email address and try again shortly." }
        }
    }
}
