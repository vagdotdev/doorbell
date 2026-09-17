import ConvexMobile
import Foundation

/// A Convex Auth session: the JWT the client presents, and the refresh token that buys
/// the next one.
struct ConvexSession: Codable, Sendable {
    let token: String
    let refreshToken: String
}

enum ConvexAuthError: Error, LocalizedError {
    case noCredentials
    case noSession
    /// The server said no (wrong password, expired refresh token, invalid email).
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials: "No email and password to sign in with."
        case .noSession: "Not signed in."
        case .rejected(let why): why
        }
    }
}

/// Email + password against `auth:signIn`, the way Convex Auth's own clients do it —
/// over the deployment's HTTP action API, so the socket client never carries a password.
/// The session lives in one file under Application Support, per profile, which lets two
/// accounts run on one Mac for development.
actor ConvexPasswordAuth: AuthProvider {
    typealias T = ConvexSession

    private let deploymentURL: URL
    private let file: URL
    private var pending: (email: String, password: String, flow: String)?
    /// One refresh at a time. A refresh token is single-use; two callers racing to
    /// refresh (every query re-runs on expiry) would present it twice and, outside
    /// Convex Auth's 10 s reuse window, end the whole session.
    private var refreshing: Task<ConvexSession, Error>?

    init(deploymentURL: URL, directory: URL) {
        self.deploymentURL = deploymentURL
        file = directory.appendingPathComponent("convex-session.json")
    }

    /// Hand over what the next `login()` should use.
    func prepare(email: String, password: String, create: Bool) {
        pending = (email.trimmingCharacters(in: .whitespaces), password, create ? "signUp" : "signIn")
    }

    var hasSession: Bool { load() != nil }

    // MARK: AuthProvider

    func login(onIdToken _: @Sendable @escaping (String?) -> Void) async throws -> ConvexSession {
        guard let p = pending else { throw ConvexAuthError.noCredentials }
        pending = nil
        let session = try await signIn([
            "provider": "password",
            "params": ["email": p.email, "password": p.password, "flow": p.flow],
        ])
        save(session)
        return session
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> ConvexSession {
        if let refreshing { return try await refreshing.value }
        guard let saved = load() else { throw ConvexAuthError.noSession }
        let task = Task<ConvexSession, Error> {
            do {
                let session = try await signIn(["refreshToken": saved.refreshToken])
                save(session)
                return session
            } catch let error as ConvexAuthError {
                // The server refused the refresh token: this session is over. Say so, so
                // the client drops the old JWT and the account query re-runs signed out.
                // A network error, by contrast, keeps the file — we try again next time.
                clear()
                onIdToken(nil)
                throw error
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    func logout() async throws { clear() }

    nonisolated func extractIdToken(from session: ConvexSession) -> String { session.token }

    // MARK: Wire

    private struct ActionResponse: Decodable {
        struct Value: Decodable { let tokens: ConvexSession? }
        let status: String
        let value: Value?
        let errorMessage: String?
    }

    private func signIn(_ args: [String: Any]) async throws -> ConvexSession {
        var request = URLRequest(url: deploymentURL.appendingPathComponent("api/action"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": "auth:signIn", "args": args, "format": "json",
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(ActionResponse.self, from: data)
        guard response.status == "success", let tokens = response.value?.tokens else {
            throw ConvexAuthError.rejected(response.errorMessage ?? "Sign-in failed.")
        }
        return tokens
    }

    // MARK: Disk

    private func load() -> ConvexSession? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ConvexSession.self, from: data)
    }

    private func save(_ session: ConvexSession) {
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }

    private func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
