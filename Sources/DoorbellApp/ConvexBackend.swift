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
    /// The first `profiles:account` answer has arrived (or we gave up waiting).
    private var accountKnown = false
    private var snapshot: HallwaySnapshot?
    /// Handles for ids seen in the hallway, search or at the door, so a visit needs no
    /// extra round trip.
    private var known: [Profile.ID: Profile] = [:]
    /// Event ids already handed to the app; the row stays until our `ack` lands.
    private var delivered: Set<String> = []
    /// Stable visit IDs for Convex event rows (document ids are not UUIDs).
    private var visitIDs: [String: UUID] = [:]
    private var watchers: [Task<Void, Never>] = []

    init(url: URL, config: AppConfig) {
        (updates, updatesOut) = AsyncStream<Void>.makeStream()
        (events, eventsOut) = AsyncStream<DoorEvent>.makeStream()
        auth = ConvexPasswordAuth(deploymentURL: url, directory: config.supportDirectory)
        client = ConvexClientWithAuth(deploymentUrl: url.absoluteString, authProvider: auth)
        Task { await start() }
    }

    private func start() async {
        if await auth.hasSession {
            if case .failure(let error) = await client.loginFromCache() {
                NSLog("convex: could not resume the session: \(error.localizedDescription)")
            }
        }
        watchers = [
            watch("profiles:account", as: AccountRow.self) { await self.account($0) },
            watch("graph:hallway", as: HallwayRow?.self) { await self.hallway($0) },
            watch("doors:events", as: [EventRow].self) { await self.arrived($0) },
        ]
    }

    // MARK: Account

    func accountState() async -> AccountState {
        await settle(upTo: .seconds(6)) { self.accountKnown }
        return state
    }

    func accountEmail() async -> String? {
        await settle(upTo: .seconds(6)) { self.accountKnown }
        return email
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
        await settle(upTo: .seconds(4)) { self.state != .signedOut }
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

    func setAvatar(jpegOrPng: Data, contentType: String) async throws {
        guard !jpegOrPng.isEmpty else { throw BackendError.badAvatar }
        let uploadURL: String = try await client.mutation("profiles:generateUploadUrl", with: [:])
        guard let url = URL(string: uploadURL) else { throw BackendError.badAvatar }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegOrPng
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let storageId = json["storageId"] as? String else {
            throw BackendError.badAvatar
        }
        let row: ProfileRow = try await client.mutation(
            "profiles:setAvatar", with: ["storageId": storageId])
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
        try? await client.action("auth:signOut")
        await client.logout()
        state = .signedOut
        email = nil
        snapshot = nil
        updatesOut.yield()
    }

    private func account(_ row: AccountRow) {
        accountKnown = true
        email = row.email
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
        // visitID is correlated on the Mac side; Convex still decides knock vs walk-in.
        let seat: SeatRow = try await client.action("doorActions:visit", with: ["door": door])
        return Visit(mode: seat.mode == "walk_in" ? .walkIn : .knock, grant: seat.grant)
    }

    func announceVisit(_ id: Profile.ID, visitID: UUID) async throws {}

    func leaveVisit(_ id: Profile.ID, visitID: UUID) async {
        guard let door = try? handle(for: id) else { return }
        try? await client.action("doorActions:leave", with: ["door": door])
    }

    func answer(hidden: Bool, visitID: UUID?) async throws -> MediaGrant? {
        let seat: SeatRow = try await client.action("doorActions:answer", with: ["hidden": hidden])
        return seat.grant
    }

    func admit(_ id: Profile.ID, visitID: UUID, into room: String?) async throws {
        var args: [String: ConvexEncodable?] = ["guest": try handle(for: id)]
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
        visitIDs = visitIDs.filter { present.contains($0.key) }
        for row in rows {
            let visitID = visitIDs[row.id] ?? {
                let id = UUID(); visitIDs[row.id] = id; return id
            }()
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
        Task {
            while !Task.isCancelled {
                do {
                    for try await value in client.subscribe(to: name, yielding: type).values {
                        await handle(value)
                    }
                } catch {
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
        while !done(), ContinuousClock.now < deadline {
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

    var profile: Profile {
        Profile(id: id, handle: handle, displayName: displayName, avatarURL: avatarUrl.flatMap(URL.init(string:)))
    }
}

private struct AccountRow: Decodable, Sendable {
    let state: String
    let me: ProfileRow?
    let email: String?
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
