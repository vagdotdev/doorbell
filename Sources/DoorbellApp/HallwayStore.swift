import SwiftUI

/// Observable view of the graph. Talks to whichever backend it was given.
@MainActor
final class HallwayStore: ObservableObject {
    @Published private(set) var account: AccountState = .ready
    @Published private(set) var me: Profile?
    @Published private(set) var doors: [Door] = []
    @Published private(set) var requests: [Profile] = []
    @Published private(set) var outgoing: Set<String> = []

    var beforeSignOut: (() async -> Void)?
    @Published private(set) var isSigningOut = false
    @Published var problem: String?
    private let backend: any DoorbellBackend
    private var listener: Task<Void, Never>?
    private var refreshVersion = 0

    init(backend: any DoorbellBackend) {
        self.backend = backend
        listener = Task { [weak self] in
            for await _ in backend.updates {
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isSigningOut else { return }
        refreshVersion += 1
        let version = refreshVersion
        let next = await backend.accountState()
        guard version == refreshVersion, !isSigningOut else { return }
        guard next == .ready else {
            account = next
            me = nil; doors = []; requests = []; outgoing = []
            return
        }
        do {
            let snap = try await backend.hallway()
            guard version == refreshVersion, !isSigningOut else { return }
            account = .ready
            me = snap.me; doors = snap.doors; requests = snap.requests; outgoing = snap.outgoing
        } catch {
            guard version == refreshVersion, !isSigningOut else { return }
            account = .unavailable
        }
    }

    // MARK: Account

    func signIn(email: String, password: String) async throws {
        try await backend.signIn(email: email, password: password)
        await refresh()
    }

    func signUp(email: String, password: String) async throws {
        try await backend.signUp(email: email, password: password)
        await refresh()
    }

    func claimHandle(_ handle: String, displayName: String) async throws {
        try await backend.claimHandle(handle, displayName: displayName)
        await refresh()
    }

    func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        refreshVersion += 1
        Task {
            await beforeSignOut?()
            await backend.signOut()
            isSigningOut = false
            await refresh()
        }
    }

    // MARK: Graph

    func search(_ query: String) async -> [Profile] {
        (try? await backend.search(query)) ?? []
    }

    func relationship(to profile: Profile) -> Relationship {
        if doors.contains(where: { $0.id == profile.id }) { return .following }
        if outgoing.contains(profile.id) { return .requested }
        return .none
    }

    func request(_ profile: Profile) { perform { try await $0.request(profile.id) } }
    func accept(_ profile: Profile) { perform { try await $0.accept(profile.id) } }
    func ignore(_ profile: Profile) { perform { try await $0.ignore(profile.id) } }
    func removeFollower(_ profile: Profile) { perform { try await $0.removeFollower(profile.id) } }
    func unfollow(_ profile: Profile) { perform { try await $0.unfollow(profile.id) } }
    func setCloseFriend(_ profile: Profile, _ on: Bool) {
        perform { try await $0.setCloseFriend(profile.id, on) }
    }

    private func perform(_ op: @escaping @Sendable (any DoorbellBackend) async throws -> Void) {
        Task {
            do { try await op(backend); problem = nil }
            catch { problem = "Couldn’t save that. Try again." }
            await refresh()
        }
    }

    enum Relationship { case none, requested, following }
}
