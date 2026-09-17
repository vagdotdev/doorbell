import SwiftUI

/// Single source of truth shared by the notch and the app window.
@MainActor
final class HallwayStore: ObservableObject {
    @Published private(set) var account: AccountState = .loading
    @Published private(set) var me: Profile?
    @Published private(set) var doors: [Door] = []
    @Published private(set) var followers: [Door] = []
    @Published private(set) var requests: [Profile] = []
    @Published private(set) var outgoing: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var busy = false
    @Published private(set) var isSigningOut = false
    @Published var problem: String?
    var beforeSignOut: (() async -> Void)?
    var openWindow: (() -> Void)?

    private let backend: any DoorbellBackend
    private var listener: Task<Void, Never>?
    private var revision = 0

    init(backend: any DoorbellBackend) {
        self.backend = backend
        listener = Task { [weak self] in
            for await _ in backend.updates { await self?.refresh() }
        }
        Task { await refresh() }
    }

    deinit { listener?.cancel() }

    func refresh() async {
        guard !isSigningOut else { return }
        revision += 1
        let ticket = revision
        isRefreshing = true
        defer { if ticket == revision { isRefreshing = false } }
        do {
            let next = try await backend.accountState()
            guard ticket == revision, !isSigningOut else { return }
            if next != .ready {
                let hadAccount = me != nil
                clearGraph()
                account = next
                if hadAccount { await beforeSignOut?() }
                return
            }
            let snap = try await backend.hallway()
            guard ticket == revision, !isSigningOut else { return }
            me = snap.me
            doors = snap.doors.sorted { $0.profile.handle < $1.profile.handle }
            followers = snap.followers.sorted { $0.profile.handle < $1.profile.handle }
            requests = snap.requests.sorted { $0.handle < $1.handle }
            outgoing = snap.outgoing
            account = .ready
            problem = nil
        } catch is CancellationError {
        } catch {
            guard ticket == revision, !isSigningOut else { return }
            let message = "Couldn't load your door. Check your connection and try again."
            if me == nil { account = .unavailable(message) }
            problem = message
        }
    }

    private func clearGraph() {
        me = nil; doors = []; followers = []; requests = []; outgoing = []
    }

    func signIn(email: String, password: String) async throws {
        try await backend.signIn(email: email, password: password)
        await refresh()
    }
    func signUp(email: String, password: String) async throws {
        try await backend.signUp(email: email, password: password)
        await refresh()
    }
    func signIn(provider: AccountProvider) async throws {
        try await backend.signIn(provider: provider)
        await refresh()
    }
    func sendMagicLink(email: String) async throws { try await backend.sendMagicLink(email: email) }
    func handleAuthCallback(_ url: URL) {
        guard AppConfig.acceptsAuthCallback(url), !isSigningOut else { return }
        Task {
            do { try await backend.handleAuthCallback(url); await refresh() }
            catch { problem = "That sign-in link couldn't be verified. Request a new link and try again." }
            openWindow?()
        }
    }
    func claimHandle(_ handle: String, displayName: String) async throws {
        try await backend.claimHandle(handle, displayName: displayName)
        await refresh()
    }
    func isHandleAvailable(_ handle: String) async throws -> Bool {
        try await backend.isHandleAvailable(handle)
    }
    func signOut() {
        guard !busy, !isSigningOut else { return }
        isSigningOut = true
        revision += 1
        account = .loading
        clearGraph()
        busy = true
        Task {
            await beforeSignOut?()
            await backend.signOut()
            isSigningOut = false
            busy = false
            problem = nil
            await refresh()
            openWindow?()
        }
    }

    func search(_ query: String) async -> [Profile] {
        do { return try await backend.search(query) }
        catch { problem = "Search couldn't connect. Try again."; return [] }
    }
    func relationship(to profile: Profile) -> Relationship {
        if doors.contains(where: { $0.id == profile.id }) { return .following }
        if outgoing.contains(profile.id) { return .requested }
        return .none
    }
    func request(_ profile: Profile) { perform { try await $0.request(profile.id) } }
    func accept(_ profile: Profile) { perform { try await $0.accept(profile.id) } }
    func ignore(_ profile: Profile) { perform { try await $0.ignore(profile.id) } }
    func unfollow(_ profile: Profile) { perform { try await $0.unfollow(profile.id) } }
    func removeFollower(_ profile: Profile) { perform { try await $0.removeFollower(profile.id) } }
    func setCloseFriend(_ profile: Profile, _ on: Bool) {
        perform { try await $0.setCloseFriend(profile.id, on) }
    }
    func updateDisplayName(_ name: String) { perform { try await $0.updateDisplayName(name) } }

    private func perform(_ op: @escaping @Sendable (any DoorbellBackend) async throws -> Void) {
        guard !busy, account == .ready else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do { try await op(backend); await refresh() }
            catch { problem = "That change didn't save. Check your connection and try again." }
        }
    }
    enum Relationship { case none, requested, following }
}
