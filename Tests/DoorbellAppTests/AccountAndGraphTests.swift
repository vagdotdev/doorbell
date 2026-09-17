import XCTest
@testable import DoorbellApp

final class ProfileValidationTests: XCTestCase {
    func testHandleMatchesDatabaseAlphabet() {
        for handle in ["abc", "alex_01", String(repeating: "z", count: 20)] {
            XCTAssertTrue(ProfileValidation.validHandle(handle), handle)
        }
        for handle in ["", "ab", "ABC", "a١٢", "ab３", "a-b", "ab é", String(repeating: "a", count: 21)] {
            XCTAssertFalse(ProfileValidation.validHandle(handle), handle)
        }
    }
    func testNameRejectsWhitespaceAndOversizedInput() {
        XCTAssertFalse(ProfileValidation.validName(" \n\t"))
        XCTAssertFalse(ProfileValidation.validName(String(repeating: "a", count: 61)))
        XCTAssertTrue(ProfileValidation.validName("梅"))
    }
}

final class MockGraphTests: XCTestCase {
    func testIncomingOnlyFollowerCanBecomeCloseAndBeRemoved() async throws {
        let backend = MockBackend(storageKey: "test.graph.\(UUID())")
        try await backend.accept("ananya")
        try await backend.setCloseFriend("ananya", true)
        let snapshot = try await backend.hallway()
        XCTAssertFalse(snapshot.doors.contains { $0.id == "ananya" })
        XCTAssertTrue(snapshot.followers.contains { $0.id == "ananya" && $0.isCloseFriend })
        try await backend.removeFollower("ananya")
        let after = try await backend.hallway()
        XCTAssertFalse(after.followers.contains { $0.id == "ananya" })
        do {
            try await backend.setCloseFriend("ananya", true)
            XCTFail("Removed follower must not regain walk-in without acceptance")
        } catch {}
    }
    func testRemovalEndsBothDirections() async throws {
        let backend = MockBackend(storageKey: "test.graph.\(UUID())")
        try await backend.removeFollower("arjun")
        let snapshot = try await backend.hallway()
        XCTAssertFalse(snapshot.doors.contains { $0.id == "arjun" })
        XCTAssertFalse(snapshot.followers.contains { $0.id == "arjun" })
    }
}

private actor ControlledBackend: DoorbellBackend {
    nonisolated let updates: AsyncStream<Void> = AsyncStream { _ in }
    nonisolated let events: AsyncStream<DoorEvent> = AsyncStream { _ in }
    var fail = false
    var ready = true
    var mutations = 0
    let profile = Profile(id: "me", handle: "test_user", displayName: "Test", avatarURL: nil)
    func setFailure(_ fail: Bool) { self.fail = fail }
    func accountState() async throws -> AccountState {
        if fail { throw URLError(.notConnectedToInternet) }
        return ready ? .ready : .signedOut
    }
    func hallway() async throws -> HallwaySnapshot {
        if fail { throw URLError(.notConnectedToInternet) }
        return HallwaySnapshot(me: profile, doors: [], requests: [], outgoing: [])
    }
    func search(_ query: String) async throws -> [Profile] { [] }
    func request(_ id: String) async throws {
        mutations += 1
        try await Task.sleep(for: .milliseconds(40))
        if fail { throw URLError(.notConnectedToInternet) }
    }
    func accept(_ id: String) async throws {}
    func ignore(_ id: String) async throws {}
    func unfollow(_ id: String) async throws {}
    func removeFollower(_ id: String) async throws {}
    func setCloseFriend(_ id: String, _ on: Bool) async throws { try await request(id) }
    func visit(_ id: String, visitID: UUID) async throws -> Visit { Visit(mode: .knock, grant: nil) }
    func leaveVisit(_ id: String, visitID: UUID) async {}
    func signOut() async { ready = false }
}

@MainActor
final class HallwayStoreTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("State did not settle")
    }
    func testOfflineRefreshPreservesLoadedAccount() async throws {
        let backend = ControlledBackend()
        let store = HallwayStore(backend: backend)
        try await waitUntil { store.me != nil }
        await backend.setFailure(true)
        await store.refresh()
        XCTAssertEqual(store.account, .ready)
        XCTAssertEqual(store.me?.handle, "test_user")
        XCTAssertNotNil(store.problem)
        await backend.setFailure(false)
        await store.refresh()
        XCTAssertNil(store.problem)
    }
    func testColdOfflineDoesNotAskForNewHandle() async throws {
        let backend = ControlledBackend()
        await backend.setFailure(true)
        let store = HallwayStore(backend: backend)
        try await waitUntil { store.account != .loading }
        guard case .unavailable = store.account else { return XCTFail("Offline must be recoverable, not signed out or needsHandle") }
    }
    func testDoubleToggleHasOneMutationAndFailureIsVisible() async throws {
        let backend = ControlledBackend()
        let store = HallwayStore(backend: backend)
        try await waitUntil { store.me != nil }
        await backend.setFailure(true)
        let profile = await backend.profile
        store.setCloseFriend(profile, true)
        store.setCloseFriend(profile, false)
        try await waitUntil { !store.busy }
        let mutations = await backend.mutations
        XCTAssertEqual(mutations, 1)
        XCTAssertNotNil(store.problem)
    }
    func testSignOutDrainsMediaBeforeRemovingAccount() async throws {
        let backend = ControlledBackend()
        let store = HallwayStore(backend: backend)
        try await waitUntil { store.me != nil }
        var drained = false
        store.beforeSignOut = {
            let account = try? await backend.accountState()
            XCTAssertEqual(account, .ready)
            try? await Task.sleep(for: .milliseconds(30))
            drained = true
        }
        store.signOut()
        XCTAssertNil(store.me)
        try await waitUntil { store.account == .signedOut }
        XCTAssertTrue(drained)
        XCTAssertFalse(store.busy)
    }
}

final class AuthCallbackTests: XCTestCase {
    func testOnlyCodeCallbacksForOurRouteAreAccepted() {
        XCTAssertTrue(AppConfig.acceptsAuthCallback(URL(string: "doorbell://auth?code=one-time-code")!))
        for value in ["https://auth?code=x", "doorbell://other?code=x", "doorbell://auth/other?code=x", "doorbell://auth?code=", "doorbell://auth#access_token=forged"] {
            XCTAssertFalse(AppConfig.acceptsAuthCallback(URL(string: value)!), value)
        }
    }
}

@MainActor
final class OnboardingTests: XCTestCase {
    func testResumesAndKeepsCompletionPerAccount() {
        let suite = "doorbell.onboarding.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = AppWindowModel(defaults: defaults, profile: "test")
        XCTAssertFalse(fresh.introSeen)
        fresh.next()
        let resumed = AppWindowModel(defaults: defaults, profile: "test")
        XCTAssertTrue(resumed.introSeen)
        XCTAssertFalse(resumed.completed.contains("alice"))
        resumed.complete("alice")
        let finished = AppWindowModel(defaults: defaults, profile: "test")
        XCTAssertTrue(finished.completed.contains("alice"))
        XCTAssertFalse(finished.completed.contains("bob"))
        XCTAssertFalse(AppWindowModel(defaults: defaults, profile: "other").introSeen)
    }
}
