import Combine
import ConvexMobile
import Foundation

/// The client is a thin wrapper over a Rust object that is `Send + Sync`; Swift just
/// isn't told. Calls from this actor and from the client's own callbacks are safe.
extension ConvexClientWithAuth: @retroactive @unchecked Sendable {}

/// The real graph, on Convex. Every function checks the caller on the server (there is
/// no client-side permission logic here). Three live subscriptions do the work: the
/// account, the hallway, and the events at my door. Actions in `doorActions` mint LiveKit
/// seats and ring doors. Nothing here writes presence.
actor ConvexBackend: DoorbellBackend {
    nonisolated let updates: AsyncStream<Void>
    private nonisolated let updatesOut: AsyncStream<Void>.Continuation
    nonisolated let events: AsyncStream<DoorEvent>
    private nonisolated let eventsOut: AsyncStream<DoorEvent>.Continuation

    private let client: ConvexClientWithAuth<ConvexSession>
    private let auth: ConvexPasswordAuth

    private var state: AccountState = .signedOut
    /// Sign-in email from the account subscription.
    private var email: String?
    private var nameQuota = NameQuota.fresh
    /// The first `profiles:account` answer has arrived (or we gave up waiting).
    private var accountKnown = false
    private var restorePending = false
    private var retryingRestore = false
    private var logoutVersion = 0
    private var snapshot: HallwaySnapshot?
    /// Handles for ids seen in the hallway, search or at the door, so a visit needs no
    /// extra round trip.
    private var known: [Profile.ID: Profile] = [:]
    /// Event ids already handed to the app; the row stays until our `ack` lands.
    private var delivered: Set<String> = []
    private var watchers: [Task<Void, Never>] = []

    init(url: URL, config: AppConfig) {
        self.init(url: url, directory: config.supportDirectory, profile: config.profile)
    }

    init(url: URL, directory: URL, profile: String) {
        (updates, updatesOut) = AsyncStream<Void>.makeStream()
        (events, eventsOut) = AsyncStream<DoorEvent>.makeStream()
        auth = ConvexPasswordAuth(deploymentURL: url, directory: directory, profile: profile)
        client = ConvexClientWithAuth(deploymentUrl: url.absoluteString, authProvider: auth)
        Task { await start() }
    }

    private func start() async {
        let version = logoutVersion
        if await auth.hasSession {
            if case .failure(let error) = await client.loginFromCache() {
                NSLog("convex: could not resume the session: \(error.localizedDescription)")
                restorePending = await auth.hasSession
                if restorePending { state = .unavailable; accountKnown = true }
            }
        }
        guard version == logoutVersion else { return }
        startWatchers()
    }

    private func startWatchers() {
        watchers.forEach { $0.cancel() }
        watchers = [
            watch("profiles:account", as: AccountRow.self) { await self.account($0) },
            watch("graph:hallway", as: HallwayRow?.self) { await self.hallway($0) },
            watch("doors:events", as: [EventRow].self) { await self.arrived($0) },
        ]
    }

    // MARK: Account

    func accountState() async -> AccountState {
        if restorePending, !retryingRestore {
            retryingRestore = true
            if case .success = await client.loginFromCache() { restorePending = false }
            else { restorePending = await auth.hasSession }
            retryingRestore = false
        }
        await settle(upTo: .seconds(6)) { self.accountKnown }
        return state
    }

    func accountEmail() async -> String? {
        await settle(upTo: .seconds(6)) { self.accountKnown }
        return email
    }

    func accountNameQuota() async -> NameQuota? {
        await settle(upTo: .seconds(6)) { self.accountKnown }
        return nameQuota
    }

    func signIn(email: String, password: String) async throws {
        try await login(email: email, password: password, create: false)
    }

    func signUp(email: String, password: String) async throws {
        try await login(email: email, password: password, create: true)
    }

    private func login(email: String, password: String, create: Bool) async throws {
        await auth.prepare(email: email, password: password, create: create)
        if case .failure(let error) = await client.login() { throw error }
        // The account subscription re-runs with the new identity; give it a moment so the
        // caller's refresh sees the signed-in state.
        await settle(upTo: .seconds(4)) { self.email == email && (self.state == .ready || self.state == .needsHandle) }
        updatesOut.yield()
    }

    func claimHandle(_ handle: String, displayName: String) async throws {
        let row: ProfileRow = try await client.mutation(
            "profiles:claimHandle", with: ["handle": handle, "displayName": displayName])
        known[row.id] = row.profile
        await settle(upTo: .seconds(4)) { self.state == .ready }
        updatesOut.yield()
    }

    func updateProfile(displayName: String) async throws {
        let row: ProfileRow = try await client.mutation(
            "profiles:update", with: ["displayName": displayName])
        known[row.id] = row.profile
        if var snap = snapshot { snap.me = row.profile; snapshot = snap }
        updatesOut.yield()
    }

    func setOpenDoorPolicy(_ enabled: Bool) async throws {
        let row: ProfileRow = try await client.mutation("profiles:setOpenDoorPolicy", with: ["enabled": enabled])
        known[row.id] = row.profile
        snapshot?.me = row.profile
        updatesOut.yield()
    }

    func setAvatar(jpegOrPng: Data, contentType: String) async throws {
        guard !jpegOrPng.isEmpty, jpegOrPng.count <= 512 * 1024 else { throw BackendError.badAvatar }
        let row: ProfileRow = try await client.action("profiles:uploadAvatar",
            with: ["bytes": ConvexBytes(data: jpegOrPng), "contentType": contentType])
        known[row.id] = row.profile
        if var snap = snapshot { snap.me = row.profile; snapshot = snap }
        updatesOut.yield()
    }

    func clearAvatar() async throws {
        let row: ProfileRow = try await client.mutation("profiles:clearAvatar", with: [:])
        known[row.id] = row.profile
        if var snap = snapshot { snap.me = row.profile; snapshot = snap }
        updatesOut.yield()
    }

    func signOut() async {
        logoutVersion += 1
        watchers.forEach { $0.cancel() }
        watchers = []
        let token = await auth.accessTokenForRevocation()
        await client.logout()
        restorePending = false
        accountKnown = true
        state = .signedOut
        email = nil
        snapshot = nil
        known = [:]
        delivered = []
        updatesOut.yield()
        startWatchers()
        if let token { Task { await auth.revoke(token) } }
    }

    private func account(_ row: AccountRow) {
        if restorePending, row.state == "signedOut" { return }
        if row.state != "signedOut" { restorePending = false }
        accountKnown = true
        email = row.email
        nameQuota = row.nameQuota.quota
        let next: AccountState = switch row.state {
        case "ready": .ready
        case "needsHandle": .needsHandle
        default: .signedOut
        }
        if let me = row.me?.profile { known[me.id] = me }
        if next != .ready { snapshot = nil }
        if next != state {
            state = next
            updatesOut.yield()
        } else if next == .ready {
            // Name / avatar can change without a state transition.
            updatesOut.yield()
        }
    }

    // MARK: Graph

    func hallway() async throws -> HallwaySnapshot {
        await settle(upTo: .seconds(6)) { self.snapshot != nil || self.state != .ready }
        guard let snapshot else { throw BackendError.noProfile }
        return snapshot
    }

    private func hallway(_ row: HallwayRow?) {
        guard let row else {
            if snapshot != nil { snapshot = nil; updatesOut.yield() }
            return
        }
        for p in [row.me] + row.doors.map(\.profile) + row.requests { known[p.id] = p.profile }
        snapshot = HallwaySnapshot(
            me: row.me.profile,
            doors: row.doors.map { Door(profile: $0.profile.profile, followsMe: $0.followsMe, isCloseFriend: $0.isCloseFriend) },
            requests: row.requests.map(\.profile),
            outgoing: Set(row.outgoing))
        updatesOut.yield()
    }

    func search(_ query: String) async throws -> [Profile] {
        let rows: [ProfileRow] = try await once("profiles:search", with: ["q": query])
        for r in rows { known[r.id] = r.profile }
        return rows.map(\.profile)
    }

    func request(_ id: Profile.ID) async throws {
        try await client.mutation("graph:request", with: ["profileId": id])
    }

    func accept(_ id: Profile.ID) async throws {
        try await client.mutation("graph:accept", with: ["profileId": id])
    }

    func ignore(_ id: Profile.ID) async throws {
        try await client.mutation("graph:ignore", with: ["profileId": id])
    }

    func unfollow(_ id: Profile.ID) async throws {
        try await client.mutation("graph:unfollow", with: ["profileId": id])
    }

    func setCloseFriend(_ id: Profile.ID, _ on: Bool) async throws {
        try await client.mutation("graph:setCloseFriend", with: ["profileId": id, "on": on])
    }

    // MARK: Doors

    func visit(_ id: Profile.ID, visitID: UUID) async throws -> Visit {
        let door = try handle(for: id)
        let seat: SeatRow = try await client.action("doorActions:visit", with: ["door": door, "visitId": visitID.uuidString.lowercased()])
        return Visit(mode: seat.mode == "walk_in" ? .walkIn : .knock, grant: seat.grant)
    }

    func announceVisit(_ id: Profile.ID, visitID: UUID) async throws {
        try await client.action("doorActions:announce", with: ["door": try handle(for: id), "visitId": visitID.uuidString.lowercased()])
    }

    func leaveVisit(_ id: Profile.ID, visitID: UUID) async {
        guard let door = try? handle(for: id) else { return }
        try? await client.action("doorActions:leave", with: ["door": door, "visitId": visitID.uuidString.lowercased()])
    }

    func answer(hidden: Bool, visitID: UUID?) async throws -> MediaGrant? {
        var args: [String: ConvexEncodable?] = ["hidden": hidden]
        if let visitID { args["visitId"] = visitID.uuidString.lowercased() }
        let seat: SeatRow = try await client.action("doorActions:answer", with: args)
        return seat.grant
    }

    func admit(_ id: Profile.ID, visitID: UUID, into room: String?) async throws {
        try await admit(id, visitID: visitID, into: room, automatically: false)
    }

    func admit(_ id: Profile.ID, visitID: UUID, into room: String?, automatically: Bool) async throws {
        var args: [String: ConvexEncodable?] = ["guest": try handle(for: id), "visitId": visitID.uuidString.lowercased(), "automatically": automatically]
        if let room { args["room"] = room }
        try await client.action("doorActions:admit", with: args)
    }

    private func handle(for id: Profile.ID) throws -> String {
        guard let p = known[id] else { throw BackendError.noSuchDoor }
        return p.handle
    }

    /// The server keeps a row per event until I ack it. Hand each one to the app once;
    /// keep acking a row for as long as it is still there (an ack can fail).
    private func arrived(_ rows: [EventRow]) async {
        let present = Set(rows.map(\.id))
        delivered = delivered.intersection(present)
        for row in rows {
            guard let visitID = UUID(uuidString: row.visitId) else { continue }
            if !delivered.contains(row.id) {
                delivered.insert(row.id)
                let who = row.from.profile
                known[who.id] = who
                NSLog("door: \(who.handle) \(row.kind)")
                switch row.kind {
                case "knock": eventsOut.yield(.knock(who, visitID: visitID))
                case "walk_in": eventsOut.yield(.walkIn(who, visitID: visitID))
                case "left": eventsOut.yield(.visitorLeft(who, visitID: visitID))
                case "admitted":
                    if let grant = row.grant?.grant {
                        eventsOut.yield(.admitted(who, grant, visitID: visitID))
                    }
                default: break
                }
            }
            try? await client.mutation("doors:ack", with: ["eventId": row.id])
        }
    }

    // MARK: Plumbing

    /// A query subscription that survives disconnects. Runs on this actor.
    private func watch<T: Decodable & Sendable>(
        _ name: String, as type: T.Type, _ handle: @escaping @Sendable (T) async -> Void
    ) -> Task<Void, Never> {
        let version = logoutVersion
        return Task {
            while !Task.isCancelled {
                do {
                    for try await value in client.subscribe(to: name, yielding: type).values {
                        guard !Task.isCancelled, version == logoutVersion else { return }
                        await handle(value)
                    }
                } catch {
                    guard !Task.isCancelled, version == logoutVersion else { return }
                    if name == "profiles:account" { state = .unavailable; accountKnown = true; updatesOut.yield() }
                    NSLog("convex: \(name): \(error)")
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// One answer from a query. Convex only streams, so take the first value.
    private func once<T: Decodable & Sendable>(_ name: String, with args: [String: ConvexEncodable?]) async throws -> T {
        for try await value in client.subscribe(to: name, with: args, yielding: T.self).values {
            return value
        }
        throw BackendError.noProfile
    }

    /// Wait, briefly, for a subscription to catch up.
    private func settle(upTo limit: Duration, until done: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - Rows

private struct ProfileRow: Decodable, Sendable {
    let id: String
    let handle: String
    let displayName: String
    let avatarUrl: String?
    let openDoorPolicy: Bool?

    var profile: Profile {
        Profile(id: id, handle: handle, displayName: displayName, avatarURL: avatarUrl.flatMap(URL.init(string:)), openDoorPolicy: openDoorPolicy ?? false)
    }
}

private struct AccountRow: Decodable, Sendable {
    let state: String
    let me: ProfileRow?
    let email: String?
    let nameQuota: NameQuotaRow

    struct NameQuotaRow: Decodable, Sendable {
        let remaining: Int
        let resetsAt: Double?

        var quota: NameQuota {
            NameQuota(remaining: remaining, resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
    }
}

private struct DoorRow: Decodable, Sendable {
    let profile: ProfileRow
    let followsMe: Bool
    let isCloseFriend: Bool
}

private struct HallwayRow: Decodable, Sendable {
    let me: ProfileRow
    let doors: [DoorRow]
    let requests: [ProfileRow]
    let outgoing: [String]
}

private struct GrantRow: Decodable, Sendable {
    let url: String
    let token: String
    let room: String
    var grant: MediaGrant { MediaGrant(url: url, token: token, room: room) }
}

private struct EventRow: Decodable, Sendable {
    let id: String
    let visitId: String
    let kind: String
    let from: ProfileRow
    let grant: GrantRow?
}

private struct SeatRow: Decodable, Sendable {
    let mode: String
    let url: String
    let token: String
    let room: String
    var grant: MediaGrant { MediaGrant(url: url, token: token, room: room) }
}

struct ConvexBytes: ConvexEncodable {
    let data: Data
    func convexEncode() throws -> String {
        String(decoding: try JSONEncoder().encode(["$bytes": data.base64EncodedString()]), as: UTF8.self)
    }
}
