import Foundation
import Supabase
import Testing
@testable import DoorbellApp

private let firstID = "00000000-0000-0000-0000-000000000011"
private let secondID = "00000000-0000-0000-0000-000000000012"

private final class TestAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}
private actor AuthResponses {
    var identity = firstID
    var holdFirst = false
    var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func reset() { identity = firstID; holdFirst = true; pending = 0 }
    func useSecondAccount() { identity = secondID }
    func releaseFirst() { holdFirst = false; for waiter in waiters { waiter.resume() }; waiters = [] }
    func response(_ url: URL) async -> Data {
        let object: Any
        if url.path.hasSuffix("/token") {
            func base64(_ value: [String: Any]) -> String {
                (try! JSONSerialization.data(withJSONObject: value)).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            let expiry = Int(Date().timeIntervalSince1970) + 3600
            let jwt = base64(["alg":"HS256","typ":"JWT"]) + "." + base64(["sub":identity,"exp":expiry,"role":"authenticated"]) + ".test"
            object = ["access_token":jwt,"refresh_token":"local-test-refresh","token_type":"bearer","expires_in":3600,"expires_at":expiry,
                      "user":["id":identity,"aud":"authenticated","role":"authenticated","email":"test@example.invalid",
                              "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","app_metadata":[:],"user_metadata":[:]]]
        } else if url.path.hasSuffix("/profiles") {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value?.replacingOccurrences(of: "eq.", with: "") ?? identity
            if id == firstID, holdFirst {
                pending += 1
                await withCheckedContinuation { waiters.append($0) }
            }
            object = [["id":id,"handle":id == firstID ? "first" : "second","display_name":id == firstID ? "First" : "Second"]]
        } else if url.path.contains("/rest/") { object = [] }
        else { object = [:] }
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
private final class AuthURLProtocol: URLProtocol, @unchecked Sendable {
    static let responses = AuthResponses()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "doorbell-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Task {
            let data = await Self.responses.response(url)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    // Deliberately deliver held responses even if the caller cancels.
    override func stopLoading() {}
}

@Suite(.serialized) struct SupabaseSessionTests {
    @Test func oldProfileResponseCannotPoisonNextAccount() async throws {
        await AuthURLProtocol.responses.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://doorbell-test.invalid")!, supabaseKey: "public-test-key",
            options: .init(auth: .init(storage: TestAuthStorage(), emitLocalSessionAsInitialSession: true), global: .init(session: session)))
        // Keep real Auth/PostgREST and actor caching; replace only socket subscription.
        let backend = SupabaseBackend(client: client, subscribe: { _ in })
        try await backend.signIn(email: "first@example.invalid", password: "local-test-password")
        let oldLoad = Task { await backend.accountState() }
        for _ in 0..<200 { if await AuthURLProtocol.responses.pending > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await AuthURLProtocol.responses.pending > 0)
        await backend.signOut()
        await AuthURLProtocol.responses.useSecondAccount()
        try await backend.signIn(email: "second@example.invalid", password: "local-test-password")
        await AuthURLProtocol.responses.releaseFirst()
        _ = await oldLoad.value
        for _ in 0..<200 { if await backend.accountState() == .ready { break }; try await Task.sleep(for: .milliseconds(5)) }
        let snapshot = try await backend.hallway()
        #expect(snapshot.me.id == secondID && snapshot.me.handle == "second")
        await backend.signOut()
        #expect(await backend.accountState() == .signedOut)
    }
}
