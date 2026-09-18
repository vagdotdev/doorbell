import Foundation
import Testing
@testable import DoorbellApp

private actor RefreshGate {
    var started = false
    var pending: CheckedContinuation<Void, Never>?
    func hold() async { started = true; await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(); pending = nil }
}
struct ConvexAuthTests {
    let url = URL(string: "https://auth-test.convex.cloud")!
    func fixture() throws -> (URL, String, MigratingAuthStorage) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let profile = "test-\(UUID())"
        return (folder, profile, MigratingAuthStorage(directory: folder, profile: "convex-\(profile)-auth-test.convex.cloud"))
    }
    @Test func logoutWhileRefreshingCannotResurrectSession() async throws {
        let (folder, profile, storage) = try fixture()
        defer { try? storage.remove(key: "convex-session"); try? FileManager.default.removeItem(at: folder) }
        try storage.store(key: "convex-session", value: JSONEncoder().encode(ConvexSession(token: "old", refreshToken: "old-refresh")))
        let gate = RefreshGate()
        let auth = ConvexPasswordAuth(deploymentURL: url, directory: folder, profile: profile) { request in
            await gate.hold()
            return (Data(#"{"status":"success","value":{"tokens":{"token":"new","refreshToken":"new-refresh"}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let refresh = Task { try await auth.loginFromCache { _ in } }
        for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.started)
        try await auth.logout()
        await gate.release()
        do { _ = try await refresh.value; Issue.record("Late refresh succeeded after logout") } catch {}
        #expect(try storage.retrieve(key: "convex-session") == nil)
    }
    @Test func transientServerFailurePreservesCachedLogin() async throws {
        let (folder, profile, storage) = try fixture()
        defer { try? storage.remove(key: "convex-session"); try? FileManager.default.removeItem(at: folder) }
        let saved = try JSONEncoder().encode(ConvexSession(token: "old", refreshToken: "refresh"))
        try storage.store(key: "convex-session", value: saved)
        let auth = ConvexPasswordAuth(deploymentURL: url, directory: folder, profile: profile) { request in
            (Data(#"{"status":"error","errorMessage":"temporarily unavailable"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await auth.loginFromCache { _ in }; Issue.record("503 succeeded") } catch {}
        #expect(try storage.retrieve(key: "convex-session") == saved)
    }
    @Test func revokedRefreshDeletesSession() async throws {
        let (folder, profile, storage) = try fixture()
        defer { try? storage.remove(key: "convex-session"); try? FileManager.default.removeItem(at: folder) }
        try storage.store(key: "convex-session", value: JSONEncoder().encode(ConvexSession(token: "old", refreshToken: "revoked")))
        let auth = ConvexPasswordAuth(deploymentURL: url, directory: folder, profile: profile) { request in
            (Data(#"{"status":"success","value":{"tokens":null}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await auth.loginFromCache { _ in }; Issue.record("Revoked token succeeded") } catch {}
        #expect(try storage.retrieve(key: "convex-session") == nil)
    }
    @Test func signInUsesPasswordProviderAndStoresInKeychain() async throws {
        let (folder, profile, storage) = try fixture()
        defer { try? storage.remove(key: "convex-session"); try? FileManager.default.removeItem(at: folder) }
        let auth = ConvexPasswordAuth(deploymentURL: url, directory: folder, profile: profile) { request in
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let args = try #require(body["args"] as? [String: Any])
            #expect(args["provider"] as? String == "password")
            return (Data(#"{"status":"success","value":{"tokens":{"token":"test","refreshToken":"test-refresh"}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await auth.prepare(email: "alice@doorbell.local", password: "personal-only-password", create: true)
        _ = try await auth.login { _ in }
        #expect(try storage.retrieve(key: "convex-session") != nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("convex-session.json").path))
    }
    @Test func legacyUpgradeAndSubsequentRelaunchResumeWithoutPassword() async throws {
        let (folder, profile, storage) = try fixture()
        defer { try? storage.remove(key: "convex-session"); try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("convex-session.json")
        try JSONEncoder().encode(ConvexSession(token: "legacy-access", refreshToken: "legacy-refresh")).write(to: legacy)
        // Older installations have no URL marker and no Keychain entry yet.
        AppConfig.prepareLegacySession(for: url, directory: folder)
        let upgraded = ConvexPasswordAuth(deploymentURL: url, directory: folder, profile: profile) { request in
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let args = try #require(body["args"] as? [String: Any])
            #expect(args["refreshToken"] as? String == "legacy-refresh")
            #expect(args["params"] == nil && args["provider"] == nil)
            return (Data(#"{"status":"success","value":{"tokens":{"token":"upgraded-access","refreshToken":"upgraded-refresh"}}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await upgraded.hasSession)
        let first = try await upgraded.loginFromCache { _ in }
        #expect(first.token == "upgraded-access")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // A new auth instance represents the next app binary/process. Its session
        // identity uses deployment/profile, never the app's build number or path.
        AppConfig.prepareLegacySession(for: url, directory: folder)
        let relaunched = ConvexPasswordAuth(deploymentURL: url, directory: folder, profile: profile) { request in
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let args = try #require(body["args"] as? [String: Any])
            #expect(args["refreshToken"] as? String == "upgraded-refresh")
            #expect(args["params"] == nil && args["provider"] == nil)
            return (Data(#"{"status":"success","value":{"tokens":{"token":"relaunch-access","refreshToken":"relaunch-refresh"}}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await relaunched.hasSession)
        let next = try await relaunched.loginFromCache { _ in }
        #expect(next.token == "relaunch-access")
        let blob = try storage.retrieve(key: "convex-session")
        let persisted = try JSONDecoder().decode(ConvexSession.self, from: try #require(blob))
        #expect(persisted.refreshToken == "relaunch-refresh")
    }

}
