import Foundation

/// In-memory graph with a handful of fake people, persisted to UserDefaults so the
/// hallway survives relaunch. `DOORBELL_MOCK_RESET=1` starts fresh.
actor MockBackend: DoorbellBackend {
    private struct Graph: Codable {
        var me: Profile
        var people: [Profile]
        var following: [String: FollowStatus]   // me → them
        var followers: [String: FollowStatus]   // them → me
        var closeFriends: Set<String>
    }

    nonisolated let updates: AsyncStream<Void>
    private nonisolated let continuation: AsyncStream<Void>.Continuation
    nonisolated let events: AsyncStream<DoorEvent>
    private nonisolated let eventsContinuation: AsyncStream<DoorEvent>.Continuation

    private var graph: Graph
    private let storageKey = "mock.graph.v1"
    /// In memory only: statuses are short-lived anyway. One friend has one, to show it.
    private var myStatus: DoorStatus?
    private var statuses = ["priya": DoorStatus(text: "library till 9 📚", expiresAt: Date() + DoorStatus.lifetime)]

    init() {
        (updates, continuation) = AsyncStream<Void>.makeStream()
        (events, eventsContinuation) = AsyncStream<DoorEvent>.makeStream()
        let env = ProcessInfo.processInfo.environment
        if env["DOORBELL_MOCK_RESET"] == nil,
           let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Graph.self, from: data) {
            graph = saved
        } else {
            graph = Self.seed()
        }
        // DOORBELL_SIMULATE=knock:arjun | walkin:arjun — fires two seconds after launch.
        if let sim = env["DOORBELL_SIMULATE"] {
            let parts = sim.split(separator: ":").map(String.init)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard parts.count == 2, let self, let who = await self.person(parts[1]) else { return }
                await self.simulate(parts[0] == "walkin" ? .walkIn(who) : .knock(who))
            }
        }
    }

    private func person(_ handle: String) -> Profile? {
        graph.people.first { $0.handle == handle }
    }

    // MARK: DoorbellBackend

    func updateProfile(displayName: String) async throws {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        graph.me.displayName = name
        save()
    }

    func setOpenDoorPolicy(_ enabled: Bool) async throws {
        graph.me.openDoorPolicy = enabled
        save()
    }

    func setAvatar(jpegOrPng: Data, contentType: String) async throws {
        guard !jpegOrPng.isEmpty else { throw BackendError.badAvatar }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doorbell/mock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = contentType.contains("png") ? "png" : "jpg"
        let file = dir.appendingPathComponent("avatar.\(ext)")
        try jpegOrPng.write(to: file, options: .atomic)
        graph.me.avatarURL = file
        save()
    }

    func clearAvatar() async throws {
        if let url = graph.me.avatarURL { try? FileManager.default.removeItem(at: url) }
        graph.me.avatarURL = nil
        save()
    }

    func hallway() async throws -> HallwaySnapshot {
        let doors = graph.people
            .filter { graph.following[$0.id] == .accepted }
            .map { p in
                Door(profile: p,
                     followsMe: graph.followers[p.id] == .accepted,
                     isCloseFriend: graph.closeFriends.contains(p.id),
                     status: statuses[p.id])
            }
        let requests = graph.people.filter { graph.followers[$0.id] == .pending }
        let outgoing = Set(graph.following.filter { $0.value == .pending }.map(\.key))
        return HallwaySnapshot(me: graph.me, doors: doors, requests: requests, outgoing: outgoing, myStatus: myStatus)
    }

    func setStatus(_ text: String) async throws -> DoorStatus {
        let status = DoorStatus(text: String(text.prefix(DoorStatus.maxLength)), expiresAt: Date() + DoorStatus.lifetime)
        myStatus = status
        continuation.yield()
        return status
    }

    func clearStatus() async throws {
        myStatus = nil
        continuation.yield()
    }

    func transcribeSpeech(wav: Data, speaker: String) async throws -> String {
        "\(speaker): telusa"
    }

    func writeMeetingNotes(host: String, people: [String], transcript: String) async throws -> MeetingNotes {
        let names = people.joined(separator: ", ")
        return MeetingNotes(
            text: "With \(names)\n\n\(transcript) (do you know?)",
            url: URL(string: "https://example.test/n?t=mock")!,
            inboxURL: URL(string: "https://example.test/n/feed?t=mock")!
        )
    }

    func search(_ query: String) async throws -> [Profile] {
        let q = query.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard q.count >= 2 else { return [] }
        return graph.people.filter { $0.handle.hasPrefix(q) }.sorted { $0.handle < $1.handle }
    }

    func request(_ id: Profile.ID) async throws {
        guard graph.following[id] == nil else { return }
        graph.following[id] = .pending
        save()
        // Fake people are friendly: they accept after a moment.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.autoAccept(id)
        }
    }

    func accept(_ id: Profile.ID) async throws {
        guard graph.followers[id] != nil else { return }
        graph.followers[id] = .accepted
        graph.following[id] = .accepted
        save()
    }

    func ignore(_ id: Profile.ID) async throws {
        guard graph.followers[id] == .pending else { return }
        graph.followers.removeValue(forKey: id)
        save()
    }

    func unfollow(_ id: Profile.ID) async throws {
        graph.following.removeValue(forKey: id)
        graph.followers.removeValue(forKey: id)
        graph.closeFriends.remove(id)
        save()
    }

    func setCloseFriend(_ id: Profile.ID, _ on: Bool) async throws {
        guard graph.followers[id] == .accepted else { return }
        if on { graph.closeFriends.insert(id) } else { graph.closeFriends.remove(id) }
        save()
    }

    // The mock has no second user, so it treats close friendship as mutual:
    // if they're on my list, pretend I'm on theirs.
    func visit(_ id: Profile.ID, visitID: UUID) async throws -> Visit {
        guard graph.following[id] == .accepted else { throw BackendError.noSuchDoor }
        return Visit(mode: (graph.closeFriends.contains(id) || graph.people.first(where: { $0.id == id })?.openDoorPolicy == true) ? .walkIn : .knock, grant: nil)
    }

    func leaveVisit(_ id: Profile.ID, visitID: UUID) async {}

    func simulate(_ event: DoorEvent) async {
        eventsContinuation.yield(event)
    }

    // MARK: -

    private func autoAccept(_ id: Profile.ID) {
        guard graph.following[id] == .pending else { return }
        graph.following[id] = .accepted
        graph.followers[id] = .accepted
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(graph) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        continuation.yield()
    }

    private static func seed() -> Graph {
        func p(_ handle: String, _ name: String) -> Profile {
            Profile(id: handle, handle: handle, displayName: name, avatarURL: nil)
        }
        let people = [
            p("arjun", "Arjun Mehta"), p("priya", "Priya Nair"), p("rohan", "Rohan Das"),
            p("ananya", "Ananya Iyer"), p("kabir", "Kabir Shah"), p("meera", "Meera Pillai"),
            p("dev", "Dev Kapoor"), p("sara", "Sara Khan"), p("ishaan", "Ishaan Rao"),
            p("zoya", "Zoya Ali"),
        ]
        return Graph(
            me: p("vagdev", "Vagdev"),
            people: people,
            following: ["arjun": .accepted, "priya": .accepted, "rohan": .accepted, "kabir": .pending],
            followers: ["arjun": .accepted, "priya": .accepted, "rohan": .accepted, "ananya": .pending],
            closeFriends: ["arjun"]
        )
    }
}
