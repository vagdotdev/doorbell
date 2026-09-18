import SwiftUI

/// Observable view of the graph. Talks to whichever backend it was given.
@MainActor
final class HallwayStore: ObservableObject {
    @Published private(set) var account: AccountState = .signedOut
    @Published private(set) var me: Profile?
    /// Sign-in email, when the backend knows it. Nil on the mock.
    @Published private(set) var email: String?
    /// Display-name changes left in the rolling 14-day window.
    @Published private(set) var nameQuota: NameQuota?
    @Published private(set) var doors: [Door] = []
    @Published private(set) var requests: [Profile] = []
    @Published private(set) var outgoing: Set<String> = []
    /// Last knock, walk-in, or visit — drives left-to-right order in the building.
    private var activityAt: [Profile.ID: Date] = [:]
    /// Friends who knocked and haven't been answered yet — float left.
    private var waitingKnocks: Set<Profile.ID> = []

    /// Friend doors, most active / missed first.
    var orderedDoors: [Door] {
        doors.sorted { a, b in
            let aw = waitingKnocks.contains(a.id)
            let bw = waitingKnocks.contains(b.id)
            if aw != bw { return aw }
            let at = activityAt[a.id] ?? .distantPast
            let bt = activityAt[b.id] ?? .distantPast
            if at != bt { return at > bt }
            return a.profile.handle < b.profile.handle
        }
    }

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
        let mail = await backend.accountEmail()
        let quota = await backend.accountNameQuota()
        guard version == refreshVersion, !isSigningOut else { return }
        email = mail
        nameQuota = quota
        guard next == .ready else {
            account = next
            me = nil; doors = []; requests = []; outgoing = []
            activityAt = [:]; waitingKnocks = []
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

    /// Name-yourself join for the friend group. No email UI — the app signs in as
    /// `{handle}@doorbell.local` with the group join secret, then claims the handle.
    func join(handle: String, displayName: String) async throws {
        let email = "\(handle)@doorbell.local"
        let password = AppConfig.current.joinSecret
        do {
            try await backend.signIn(email: email, password: password)
        } catch {
            try await backend.signUp(email: email, password: password)
        }
        await refresh()
        if account == .needsHandle {
            try await backend.claimHandle(handle, displayName: displayName)
            await refresh()
        }
        guard account == .ready else {
            throw BackendError.noProfile
        }
    }

    func updateProfile(displayName: String) async throws {
        try await backend.updateProfile(displayName: displayName)
        await refresh()
    }

    func setAvatar(jpegOrPng: Data, contentType: String) async throws {
        try await backend.setAvatar(jpegOrPng: jpegOrPng, contentType: contentType)
        await refresh()
    }

    func clearAvatar() async throws {
        try await backend.clearAvatar()
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

    // MARK: Activity (door order)

    func noteKnock(from profile: Profile) {
        activityAt[profile.id] = Date()
        waitingKnocks.insert(profile.id)
    }

    func noteWalkIn(from profile: Profile) {
        activityAt[profile.id] = Date()
        waitingKnocks.insert(profile.id)
    }

    func noteVisit(to door: Door) {
        activityAt[door.id] = Date()
    }

    func clearWaiting(_ profileID: Profile.ID) {
        waitingKnocks.remove(profileID)
    }

    private func perform(_ op: @escaping @Sendable (any DoorbellBackend) async throws -> Void) {
        Task {
            do { try await op(backend); problem = nil }
            catch { problem = "Couldn’t save that change. Try again." }
            await refresh()
        }
    }

    enum Relationship { case none, requested, following }
}

/// What the Join form tells the person when joining fails. Pure so it can be tested:
/// a taken handle names the handle, anything else stays generic and offline-safe.
func joinProblem(handle: String, error: Error) -> String {
    let msg = error.localizedDescription
    if msg.localizedCaseInsensitiveContains("taken") {
        return "@\(handle) is taken"
    }
    if let auth = error as? ConvexAuthError, case .rejected(let why) = auth, !why.isEmpty {
        return why
    }
    return "Couldn’t connect. Try again in a moment."
}
