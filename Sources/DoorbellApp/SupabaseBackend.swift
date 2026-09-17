import Foundation
import Supabase

/// The real graph. Postgres holds the follow edges and close-friends lists (RLS is the
/// permission system); the `door-token` function mints LiveKit seats; a private
/// Realtime channel per door carries the knock. Nothing here writes presence.
actor SupabaseBackend: DoorbellBackend {
    nonisolated let updates: AsyncStream<Void>
    private nonisolated let updatesOut: AsyncStream<Void>.Continuation
    nonisolated let events: AsyncStream<DoorEvent>
    private nonisolated let eventsOut: AsyncStream<DoorEvent>.Continuation

    private let client: SupabaseClient
    private var me: Profile?
    private var sessionVersion = 0
    private var signingOut = false
    private var currentUserID: String? { client.auth.currentSession?.user.id.uuidString.lowercased() }
    private let subscribe: @Sendable (RealtimeChannelV2) async throws -> Void
    /// Handles for ids seen in the last hallway, so a visit needs no extra round trip.
    private var known: [Profile.ID: Profile] = [:]
    private var door: RealtimeChannelV2?
    private var doorOwnerID: String?
    private var doorListener: Task<Void, Never>?

    init(url: URL, anonKey: String, config: AppConfig) {
        self.init(client: SupabaseClient(
            supabaseURL: url, supabaseKey: anonKey,
            options: .init(auth: .init(
                storage: MigratingAuthStorage(directory: config.supportDirectory, profile: config.profile),
                emitLocalSessionAsInitialSession: true
            ))
        ))
    }

    init(client: SupabaseClient, subscribe: @escaping @Sendable (RealtimeChannelV2) async throws -> Void = { try await $0.subscribeWithError() }) {
        (updates, updatesOut) = AsyncStream<Void>.makeStream()
        (events, eventsOut) = AsyncStream<DoorEvent>.makeStream()
        self.client = client
        self.subscribe = subscribe
        Task { await watchAuth() }
    }

    // MARK: Account

    func accountState() async -> AccountState {
        guard !signingOut, currentUserID != nil else { return .signedOut }
        do {
            guard try await fetchMe() != nil else { return .needsHandle }
            try await listenAtMyDoor()
            return .ready
        } catch { return currentUserID == nil ? .signedOut : .unavailable }
    }

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
        updatesOut.yield()
    }

    func signUp(email: String, password: String) async throws {
        try await client.auth.signUp(email: email, password: password)
        updatesOut.yield()
    }

    func claimHandle(_ handle: String, displayName: String) async throws {
        let uid = try await client.auth.session.user.id.uuidString.lowercased()
        let version = sessionVersion
        let row = ProfileRow(id: uid, handle: handle.lowercased(), displayName: displayName, avatarURL: nil)
        try await client.from("profiles").insert(row).execute()
        try checkSession(uid, version)
        me = row.profile
        try await listenAtMyDoor()
        updatesOut.yield()
    }

    func accountEmail() async -> String? {
        try? await client.auth.session.user.email
    }

    func updateProfile(displayName: String) async throws {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let id = me?.id else { throw BackendError.noProfile }
        try await client.from("profiles").update(["display_name": name]).eq("id", value: id).execute()
        me?.displayName = name
        updatesOut.yield()
    }

    func setAvatar(jpegOrPng: Data, contentType: String) async throws {
        // Photos live on Convex. The Supabase stack stays name-only until it is removed.
        throw BackendError.badAvatar
    }

    func clearAvatar() async throws {
        throw BackendError.badAvatar
    }

    func signOut() async {
        signingOut = true; sessionVersion += 1
        me = nil; known = [:]
        await stopListening()
        try? await client.auth.signOut()
        signingOut = false
        updatesOut.yield()
    }

    private func watchAuth() async {
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession:
                updatesOut.yield()
            case .signedIn:
                guard session?.user.id.uuidString.lowercased() == currentUserID else { continue }
                sessionVersion += 1
                me = nil; known = [:]
                await stopListening()
                updatesOut.yield()
            case .signedOut:
                // Ignore an old sign-out notification delivered after another sign-in.
                guard currentUserID == nil else { continue }
                sessionVersion += 1
                me = nil; known = [:]
                await stopListening()
                updatesOut.yield()
            default: break
            }
        }
    }

    private func checkSession(_ id: String, _ version: Int) throws {
        guard !signingOut, currentUserID == id, sessionVersion == version else { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func fetchMe() async throws -> Profile? {
        let uid = try await client.auth.session.user.id.uuidString.lowercased()
        let version = sessionVersion
        try checkSession(uid, version)
        if let me, me.id == uid { return me }
        let rows: [ProfileRow] = try await client.from("profiles").select().eq("id", value: uid).execute().value
        try checkSession(uid, version)
        me = rows.first?.profile
        return me
    }

    // MARK: Graph

    func hallway() async throws -> HallwaySnapshot {
        guard let me = try await fetchMe() else { throw BackendError.noProfile }
        let version = sessionVersion

        async let followingRows: [EdgeRow] = client.from("follows")
            .select("status, who:profiles!followee_id(id, handle, display_name, avatar_url)")
            .eq("follower_id", value: me.id).execute().value
        async let followerRows: [EdgeRow] = client.from("follows")
            .select("status, who:profiles!follower_id(id, handle, display_name, avatar_url)")
            .eq("followee_id", value: me.id).execute().value
        async let closeRows: [MemberRow] = client.from("close_friends")
            .select("member_id").eq("owner_id", value: me.id).execute().value

        let following = try await followingRows
        let followers = try await followerRows
        let close = Set(try await closeRows.map(\.memberID))
        let followsMe = Set(followers.filter { $0.status == "accepted" }.map(\.who.id))

        let doors = following.filter { $0.status == "accepted" }.map {
            Door(profile: $0.who.profile,
                 followsMe: followsMe.contains($0.who.id),
                 isCloseFriend: close.contains($0.who.id))
        }
        let requests = followers.filter { $0.status == "pending" }.map(\.who.profile)
        let outgoing = Set(following.filter { $0.status == "pending" }.map(\.who.id))

        try checkSession(me.id, version)
        for edge in following + followers { known[edge.who.id] = edge.who.profile }
        known[me.id] = me
        return HallwaySnapshot(me: me, doors: doors, requests: requests, outgoing: outgoing)
    }

    func search(_ query: String) async throws -> [Profile] {
        let rows: [ProfileRow] = try await client.rpc("search_profiles", params: ["q": query]).execute().value
        for r in rows { known[r.id] = r.profile }
        return rows.map(\.profile)
    }

    func request(_ id: Profile.ID) async throws {
        guard let me else { throw BackendError.noProfile }
        try await client.from("follows")
            .insert(["follower_id": me.id, "followee_id": id, "status": "pending"]).execute()
        updatesOut.yield()
    }

    func accept(_ id: Profile.ID) async throws {
        try await client.rpc("accept_friend", params: ["p_profile_id": id]).execute()
        updatesOut.yield()
    }

    func ignore(_ id: Profile.ID) async throws {
        guard let me else { throw BackendError.noProfile }
        try await client.from("follows").delete()
            .eq("follower_id", value: id).eq("followee_id", value: me.id)
            .eq("status", value: "pending").execute()
        updatesOut.yield()
    }

    func removeFollower(_ id: Profile.ID) async throws {
        guard let me else { throw BackendError.noProfile }
        _ = try await token(door: me.handle, intent: "revoke", guest: handle(for: id))
        updatesOut.yield()
    }
    func unfollow(_ id: Profile.ID) async throws {
        try await client.rpc("remove_friend", params: ["p_profile_id": id]).execute()
        updatesOut.yield()
    }

    func setCloseFriend(_ id: Profile.ID, _ on: Bool) async throws {
        guard let me else { throw BackendError.noProfile }
        if on {
            try await client.from("close_friends").insert(["owner_id": me.id, "member_id": id]).execute()
        } else {
            try await client.from("close_friends").delete()
                .eq("owner_id", value: me.id).eq("member_id", value: id).execute()
        }
        updatesOut.yield()
    }

    // MARK: Doors

    func visit(_ id: Profile.ID, visitID: UUID) async throws -> Visit {
        guard me != nil else { throw BackendError.noProfile }
        let door = try await handle(for: id)
        let seat = try await token(door: door, intent: "visit", visitID: visitID)
        // The function rang the door for us; only it may write to that channel.
        let mode: VisitMode = seat.mode == "walk_in" ? .walkIn : .knock
        guard let grant = seat.grant else { throw BackendError.noSuchDoor }
        return Visit(mode: mode, grant: grant)
    }

    func announceVisit(_ id: Profile.ID, visitID: UUID) async throws {
        _ = try await token(door: handle(for: id), intent: "ring", visitID: visitID)
    }

    func leaveVisit(_ id: Profile.ID, visitID: UUID) async {
        guard let door = try? await handle(for: id) else { return }
        _ = try? await token(door: door, intent: "leave", visitID: visitID)
    }

    func answer(hidden: Bool, visitID: UUID?) async throws -> MediaGrant? {
        guard let me else { throw BackendError.noProfile }
        return try await token(door: me.handle, intent: "answer", hidden: hidden, visitID: visitID).grant
    }

    func admit(_ id: Profile.ID, visitID: UUID, into room: String?) async throws {
        guard let me else { throw BackendError.noProfile }
        _ = try await token(door: me.handle, intent: "admit", guest: try await handle(for: id), room: room, visitID: visitID)
    }

    private func token(door: String, intent: String, hidden: Bool? = nil,
                       guest: String? = nil, room: String? = nil, visitID: UUID? = nil) async throws -> Seat {
        var body: [String: AnyJSON] = ["version": .integer(2), "door": .string(door), "intent": .string(intent)]
        if let visitID { body["visit"] = .string(visitID.uuidString.lowercased()) }
        if let hidden { body["hidden"] = .bool(hidden) }
        if let guest { body["guest"] = .string(guest) }
        if let room { body["room"] = .string(room) }
        return try await client.functions.invoke("door-token", options: .init(body: body))
    }

    private func handle(for id: Profile.ID) async throws -> String {
        if let p = known[id] { return p.handle }
        let rows: [ProfileRow] = try await client.from("profiles").select().eq("id", value: id).execute().value
        guard let row = rows.first else { throw BackendError.noSuchDoor }
        known[id] = row.profile
        return row.handle
    }

    // MARK: My door

    private func listenAtMyDoor() async throws {
        guard let me else { return }
        let version = sessionVersion
        try checkSession(me.id, version)
        if let door, doorOwnerID == me.id {
            try await subscribe(door)
            try checkSession(me.id, version)
            return
        }
        await stopListening()
        try checkSession(me.id, version)
        let channel = client.channel("door:\(me.handle)") { $0.isPrivate = true }
        door = channel; doorOwnerID = me.id
        let knocks = channel.broadcastStream(event: "knock")
        let walkIns = channel.broadcastStream(event: "walk_in")
        let lefts = channel.broadcastStream(event: "left")
        let admits = channel.broadcastStream(event: "admitted")
        doorListener = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await m in knocks { await self?.arrived(m, .knock, accountID: me.id) } }
                group.addTask { for await m in walkIns { await self?.arrived(m, .walkIn, accountID: me.id) } }
                group.addTask { for await m in lefts { await self?.arrived(m, .left, accountID: me.id) } }
                group.addTask { for await m in admits { await self?.arrived(m, .admitted, accountID: me.id) } }
            }
        }
        try await subscribe(channel)
        try checkSession(me.id, version)
    }

    private func stopListening() async {
        doorListener?.cancel()
        doorListener = nil
        let oldDoor = door
        door = nil; doorOwnerID = nil
        if let oldDoor { await client.removeChannel(oldDoor) }
    }

    private enum Arrival { case knock, walkIn, left, admitted }

    private func arrived(_ message: JSONObject, _ kind: Arrival, accountID: String) async {
        let version = sessionVersion
        guard !signingOut, !Task.isCancelled, currentUserID == accountID else { return }
        // The stream hands over the whole envelope: { type, event, payload: { from, … } }.
        guard case .object(let payload)? = message["payload"],
              case .string(let from)? = payload["from"],
              case .string(let rawVisit)? = payload["visit"], let visitID = UUID(uuidString: rawVisit) else { return }
        guard let who = await profile(handle: from),
              !Task.isCancelled, !signingOut, currentUserID == accountID, sessionVersion == version else { return }
        switch kind {
        case .knock: eventsOut.yield(.knock(who, visitID: visitID))
        case .walkIn: eventsOut.yield(.walkIn(who, visitID: visitID))
        case .left: eventsOut.yield(.visitorLeft(who, visitID: visitID))
        case .admitted:
            // My seat rides along: this channel is private to me, written only by the server.
            guard case .string(let url)? = payload["url"], case .string(let token)? = payload["token"],
                  case .string(let room)? = payload["room"] else { return }
            eventsOut.yield(.admitted(who, MediaGrant(url: url, token: token, room: room), visitID: visitID))
        }
    }

    private func profile(handle: String) async -> Profile? {
        if let p = known.values.first(where: { $0.handle == handle }) { return p }
        let rows: [ProfileRow]? = try? await client.from("profiles").select().eq("handle", value: handle).execute().value
        guard let row = rows?.first else { return nil }
        known[row.id] = row.profile
        return row.profile
    }
}

enum BackendError: Error {
    case noProfile, noSuchDoor, badAvatar
}

// MARK: - Rows

private struct ProfileRow: Codable {
    let id: String
    let handle: String
    let displayName: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, handle
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }

    var profile: Profile {
        Profile(id: id, handle: handle, displayName: displayName, avatarURL: avatarURL.flatMap(URL.init(string:)))
    }
}

private struct EdgeRow: Decodable {
    let status: String
    let who: ProfileRow
}

private struct MemberRow: Decodable {
    let memberID: String
    enum CodingKeys: String, CodingKey { case memberID = "member_id" }
}

private struct Seat: Decodable {
    let token: String?
    let url: String?
    let room: String?
    let mode: String

    var grant: MediaGrant? {
        guard let token, let url, let room else { return nil }
        return MediaGrant(url: url, token: token, room: room)
    }
}
