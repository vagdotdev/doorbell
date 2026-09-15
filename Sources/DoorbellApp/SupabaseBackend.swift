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
    /// Handles for ids seen in the last hallway, so a visit needs no extra round trip.
    private var known: [Profile.ID: Profile] = [:]
    private var door: RealtimeChannelV2?
    private var doorListener: Task<Void, Never>?

    init(url: URL, anonKey: String, config: AppConfig) {
        (updates, updatesOut) = AsyncStream<Void>.makeStream()
        (events, eventsOut) = AsyncStream<DoorEvent>.makeStream()
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: .init(auth: .init(
                storage: FileAuthStorage(directory: config.supportDirectory),
                emitLocalSessionAsInitialSession: true
            ))
        )
        Task { await watchAuth() }
    }

    // MARK: Account

    func accountState() async -> AccountState {
        guard (try? await client.auth.session) != nil else { return .signedOut }
        if me == nil { me = try? await fetchMe() }
        if me != nil { await listenAtMyDoor() }
        return me == nil ? .needsHandle : .ready
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
        let row = ProfileRow(id: uid, handle: handle.lowercased(), displayName: displayName, avatarURL: nil)
        try await client.from("profiles").insert(row).execute()
        me = row.profile
        await listenAtMyDoor()
        updatesOut.yield()
    }

    func signOut() async {
        try? await client.auth.signOut()
        me = nil
        await stopListening()
        updatesOut.yield()
    }

    private func watchAuth() async {
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn:
                // `accountState()` may have fetched the profile first; either way, the
                // door listens as soon as there is a session and a handle.
                if session != nil {
                    if me == nil, let p = try? await fetchMe() { me = p }
                    await listenAtMyDoor()
                    updatesOut.yield()
                }
            case .signedOut:
                me = nil
                await stopListening()
                updatesOut.yield()
            default: break
            }
        }
    }

    private func fetchMe() async throws -> Profile? {
        let uid = try await client.auth.session.user.id.uuidString.lowercased()
        let rows: [ProfileRow] = try await client.from("profiles").select().eq("id", value: uid).execute().value
        return rows.first?.profile
    }

    // MARK: Graph

    func hallway() async throws -> HallwaySnapshot {
        if me == nil { me = try await fetchMe() }
        guard let me else { throw BackendError.noProfile }

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
        guard let me else { throw BackendError.noProfile }
        try await client.from("follows").update(["status": "accepted"])
            .eq("follower_id", value: id).eq("followee_id", value: me.id).execute()
        updatesOut.yield()
    }

    func ignore(_ id: Profile.ID) async throws {
        guard let me else { throw BackendError.noProfile }
        try await client.from("follows").delete()
            .eq("follower_id", value: id).eq("followee_id", value: me.id).execute()
        updatesOut.yield()
    }

    func unfollow(_ id: Profile.ID) async throws {
        guard let me else { throw BackendError.noProfile }
        try await client.from("follows").delete()
            .eq("follower_id", value: me.id).eq("followee_id", value: id).execute()
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

    func visit(_ id: Profile.ID) async throws -> Visit {
        guard let me else { throw BackendError.noProfile }
        let door = try await handle(for: id)
        let seat = try await token(door: door, intent: "visit")
        // The function rang the door for us; only it may write to that channel.
        let mode: VisitMode = seat.mode == "walk_in" ? .walkIn : .knock
        guard let grant = seat.grant else { throw BackendError.noSuchDoor }
        return Visit(mode: mode, grant: grant)
    }

    func leaveVisit(_ id: Profile.ID) async {
        guard let door = try? await handle(for: id) else { return }
        _ = try? await token(door: door, intent: "leave")
    }

    func answer(hidden: Bool) async throws -> MediaGrant? {
        guard let me else { throw BackendError.noProfile }
        return try await token(door: me.handle, intent: "answer", hidden: hidden).grant
    }

    func admit(_ id: Profile.ID, into room: String?) async throws {
        guard let me else { throw BackendError.noProfile }
        _ = try await token(door: me.handle, intent: "admit", guest: try await handle(for: id), room: room)
    }

    private func token(door: String, intent: String, hidden: Bool? = nil,
                       guest: String? = nil, room: String? = nil) async throws -> Seat {
        var body: [String: AnyJSON] = ["door": .string(door), "intent": .string(intent)]
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

    private func listenAtMyDoor() async {
        guard let me, door == nil else { return }
        let channel = client.channel("door:\(me.handle)") { $0.isPrivate = true }
        door = channel
        let knocks = channel.broadcastStream(event: "knock")
        let walkIns = channel.broadcastStream(event: "walk_in")
        let lefts = channel.broadcastStream(event: "left")
        let admits = channel.broadcastStream(event: "admitted")
        doorListener = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await m in knocks { await self?.arrived(m, .knock) } }
                group.addTask { for await m in walkIns { await self?.arrived(m, .walkIn) } }
                group.addTask { for await m in lefts { await self?.arrived(m, .left) } }
                group.addTask { for await m in admits { await self?.arrived(m, .admitted) } }
            }
        }
        await channel.subscribe()
    }

    private func stopListening() async {
        doorListener?.cancel()
        doorListener = nil
        if let door { await client.removeChannel(door) }
        door = nil
    }

    private enum Arrival { case knock, walkIn, left, admitted }

    private func arrived(_ message: JSONObject, _ kind: Arrival) async {
        // The stream hands over the whole envelope: { type, event, payload: { from, … } }.
        guard case .object(let payload)? = message["payload"],
              case .string(let from)? = payload["from"] else { return }
        guard let who = await profile(handle: from) else { return }
        NSLog("door: \(from) \(kind)")
        switch kind {
        case .knock: eventsOut.yield(.knock(who))
        case .walkIn: eventsOut.yield(.walkIn(who))
        case .left: eventsOut.yield(.visitorLeft(who))
        case .admitted:
            // My seat rides along: this channel is private to me, written only by the server.
            guard case .string(let url)? = payload["url"], case .string(let token)? = payload["token"],
                  case .string(let room)? = payload["room"] else { return }
            eventsOut.yield(.admitted(who, MediaGrant(url: url, token: token, room: room)))
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
    case noProfile, noSuchDoor
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

/// Session on disk under Application Support, per profile. Lets two accounts run on
/// one Mac for development and keeps a bare executable out of the keychain.
private struct FileAuthStorage: AuthLocalStorage {
    let directory: URL

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    func store(key: String, value: Data) throws { try value.write(to: url(key), options: .atomic) }
    func retrieve(key: String) throws -> Data? { try? Data(contentsOf: url(key)) }
    func remove(key: String) throws { try? FileManager.default.removeItem(at: url(key)) }
}
