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
/// Credentials live in Keychain, scoped to the profile and deployment.
actor ConvexPasswordAuth: AuthProvider {
    typealias T = ConvexSession

    private let deploymentURL: URL
    private let storage: MigratingAuthStorage
    private let key = "convex-session"
    private var generation = 0
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private var pending: (email: String, password: String, flow: String)?
    /// One refresh at a time. A refresh token is single-use; two callers racing to
    /// refresh (every query re-runs on expiry) would present it twice and, outside
    /// Convex Auth's 10 s reuse window, end the whole session.
    private var refreshing: Task<ConvexSession, Error>?

    init(deploymentURL: URL, directory: URL, profile: String = "default",
         transport: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
             return (data, http)
         }) {
        self.deploymentURL = deploymentURL
        storage = MigratingAuthStorage(directory: directory, profile: "convex-\(profile)-\(deploymentURL.host ?? "local")")
        self.transport = transport
    }

    /// Hand over what the next `login()` should use.
    func prepare(email: String, password: String, create: Bool) {
        pending = (email.trimmingCharacters(in: .whitespaces), password, create ? "signUp" : "signIn")
    }

    var hasSession: Bool { (try? load()) != nil }

    // MARK: AuthProvider

    func login(onIdToken _: @Sendable @escaping (String?) -> Void) async throws -> ConvexSession {
        guard let p = pending else { throw ConvexAuthError.noCredentials }
        pending = nil
        generation += 1
        let ticket = generation
        let session = try await signIn([
            "provider": "password",
            "params": ["email": p.email, "password": p.password, "flow": p.flow],
        ])
        guard ticket == generation, !Task.isCancelled else { throw CancellationError() }
        try save(session)
        return session
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> ConvexSession {
        if let refreshing { return try await refreshing.value }
        guard let saved = try load() else { throw ConvexAuthError.noSession }
        let ticket = generation
        let task = Task<ConvexSession, Error> {
            do {
                let session = try await signIn(["refreshToken": saved.refreshToken])
                guard ticket == generation, !Task.isCancelled else { throw CancellationError() }
                try save(session)
                return session
            } catch ConvexAuthError.noSession {
                if ticket == generation {
                    try clear()
                    onIdToken(nil)
                }
                throw ConvexAuthError.noSession
            }
        }
        refreshing = task
        defer { if ticket == generation { refreshing = nil } }
        return try await task.value
    }

    func logout() async throws {
        generation += 1
        pending = nil
        refreshing?.cancel()
        refreshing = nil
        try clear()
    }

    func accessTokenForRevocation() -> String? { try? load()?.token }

    /// Best effort after local logout. Network failure cannot hold the UI signed in.
    func revoke(_ token: String) async {
        var request = URLRequest(url: deploymentURL.appendingPathComponent("api/action"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": "auth:signOut", "args": [:], "format": "json"])
        _ = try? await transport(request)
    }

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
        request.timeoutInterval = 20
        let (data, http) = try await transport(request)
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let response = try JSONDecoder().decode(ActionResponse.self, from: data)
        if response.status == "success", response.value?.tokens == nil, args["refreshToken"] != nil {
            throw ConvexAuthError.noSession
        }
        guard response.status == "success", let tokens = response.value?.tokens else {
            throw ConvexAuthError.rejected(response.errorMessage ?? "Sign-in failed.")
        }
        return tokens
    }

    // MARK: Keychain (one-time migration removes the legacy file after a successful write)

    private func load() throws -> ConvexSession? {
        guard let data = try storage.retrieve(key: key) else { return nil }
        return try JSONDecoder().decode(ConvexSession.self, from: data)
    }

    private func save(_ session: ConvexSession) throws {
        try storage.store(key: key, value: JSONEncoder().encode(session))
    }

    private func clear() throws { try storage.remove(key: key) }
}
