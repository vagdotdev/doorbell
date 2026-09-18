import Foundation
import Testing
@testable import DoorbellApp

private let owner = Profile(id: "00000000-0000-0000-0000-000000000001", handle: "owner", displayName: "Owner", avatarURL: nil)
private let alice = Profile(id: "00000000-0000-0000-0000-000000000002", handle: "alice", displayName: "Alice", avatarURL: nil)
private let bob = Profile(id: "00000000-0000-0000-0000-000000000003", handle: "bob", displayName: "Bob", avatarURL: nil)
private let carol = Profile(id: "00000000-0000-0000-0000-000000000004", handle: "carol", displayName: "Carol", avatarURL: nil)
private let dave = Profile(id: "00000000-0000-0000-0000-000000000005", handle: "dave", displayName: "Dave", avatarURL: nil)
private let eve = Profile(id: "00000000-0000-0000-0000-000000000006", handle: "eve", displayName: "Eve", avatarURL: nil)
private let grant = MediaGrant(url: "ws://localhost:7880", token: "test", room: "door:owner")
private let bobRoom = "door:bob:11111111-1111-1111-1111-111111111111"

actor TestBackend: DoorbellBackend {
    nonisolated let updates: AsyncStream<Void>
    nonisolated let events: AsyncStream<DoorEvent>
    private let updateOut: AsyncStream<Void>.Continuation
    private let eventOut: AsyncStream<DoorEvent>.Continuation
    var heldAnswer = false
    var answerWaiter: CheckedContinuation<Void, Never>?
    var heldVisit = false
    var holdNextHallway = false
    var hallwayWaiter: CheckedContinuation<Void, Never>?
    var visitStarted = false
    var lastVisitID: UUID?
    var waiter: CheckedContinuation<Void, Never>?
    var admitted: [(String, UUID, String?)] = []
    var visibleAnswers = 0
    var announced = 0
    var signedOut = false
    var failAdmission = false
    var ownProfile = owner
    var failPolicy = false
    var departed: [(String, UUID)] = []
    var heldLeave = false
    var leaveWaiter: CheckedContinuation<Void, Never>?
    init() {
        (updates, updateOut) = AsyncStream.makeStream()
        (events, eventOut) = AsyncStream.makeStream()
    }
    func accountState() async -> AccountState { signedOut ? .signedOut : .ready }
    func hallway() async throws -> HallwaySnapshot {
        if holdNextHallway {
            holdNextHallway = false
            await withCheckedContinuation { hallwayWaiter = $0 }
        }
        return .init(me: ownProfile, doors: [], requests: [], outgoing: [])
    }
    func holdHallway() { holdNextHallway = true }
    func releaseHallway() { hallwayWaiter?.resume(); hallwayWaiter = nil }
    var hallwayPending: Bool { hallwayWaiter != nil }
    func search(_ query: String) async throws -> [Profile] { [] }
    func request(_ id: String) async throws {}
    func accept(_ id: String) async throws {}
    func ignore(_ id: String) async throws {}
    func unfollow(_ id: String) async throws {}
    func setCloseFriend(_ id: String, _ on: Bool) async throws {}
    func setOpenDoorPolicy(_ enabled: Bool) async throws {
        if failPolicy { throw URLError(.notConnectedToInternet) }
        ownProfile.openDoorPolicy = enabled; updateOut.yield()
    }
    func failPolicyChanges() { failPolicy = true }
    func failAdmits() { failAdmission = true }
    func holdVisit() { heldVisit = true }
    func releaseVisit() { waiter?.resume(); waiter = nil }
    func visit(_ id: String, visitID: UUID) async throws -> Visit {
        visitStarted = true
        lastVisitID = visitID
        if heldVisit { await withCheckedContinuation { waiter = $0 } }
        return Visit(mode: .knock, grant: grant)
    }
    func announceVisit(_ id: String, visitID: UUID) async throws { announced += 1 }
    func holdLeave() { heldLeave = true }
    func releaseLeave() { heldLeave = false; leaveWaiter?.resume(); leaveWaiter = nil }
    var leavePending: Bool { leaveWaiter != nil }
    func leaveVisit(_ id: String, visitID: UUID) async {
        departed.append((id, visitID))
        if heldLeave { await withCheckedContinuation { leaveWaiter = $0 } }
    }
    func holdAnswer() { heldAnswer = true }
    var answerPending: Bool { answerWaiter != nil }
    func releaseAnswer() { answerWaiter?.resume(); answerWaiter = nil }
    func answer(hidden: Bool, visitID: UUID?) async throws -> MediaGrant? {
        if !hidden { visibleAnswers += 1 }
        if !hidden && heldAnswer { await withCheckedContinuation { answerWaiter = $0 } }
        return grant
    }
    func admit(_ id: String, visitID: UUID, into room: String?) async throws {
        if failAdmission { throw URLError(.notConnectedToInternet) }
        admitted.append((id, visitID, room))
    }
    func signOut() async { signedOut = true; updateOut.yield() }
    func simulate(_ event: DoorEvent) async { eventOut.yield(event) }
}

@MainActor final class TestSeat: MediaSession {
    var connects: [(Bool, Bool)] = []
    var disconnects = 0
    var failConnect = false
    var holdNextDisconnect = false
    var disconnectWaiter: CheckedContinuation<Void, Never>?
    override func connect(_ grant: MediaGrant, microphone: Bool, camera: Bool) async throws {
        if failConnect { throw URLError(.cannotConnectToHost) }
        connects.append((microphone, camera)); phase = .connected
        micOn = microphone; camOn = camera
    }
    override func disconnect() async {
        if holdNextDisconnect {
            holdNextDisconnect = false
            await withCheckedContinuation { disconnectWaiter = $0 }
        }
        disconnects += 1; phase = .idle; micOn = false; camOn = false; peers = []
        fadePlayback(to: 0, duration: 0)
    }
    override func setMicrophone(_ on: Bool) async { micOn = on }
    func releaseDisconnect() { disconnectWaiter?.resume(); disconnectWaiter = nil }
}

@MainActor private final class AvailabilityBox { var value = Quiet.Status.available }

@MainActor private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return predicate()
}
@MainActor private func occupy(_ door: DoorController, media: TestSeat, host: String = bob.handle, room: String = bobRoom, others: [Profile] = [bob]) async {
    door.roomName = room
    door.room.start(host: host, me: owner, others: others)
    try? await media.connect(grant, microphone: true, camera: true)
    media.peers = others.map {
        MediaSession.Peer(id: $0.handle, name: $0.displayName, via: nil, video: nil, screen: nil, micOn: true, camOn: true, isSpeaking: false)
    }
}

@MainActor private func fixture(availability: @escaping @MainActor () -> Quiet.Status = { .available }, micAuthorized: @escaping @MainActor () -> Bool = { true }) async -> (TestBackend, HallwayStore, DoorController, TestSeat, TestSeat) {
    let backend = TestBackend()
    let hallway = HallwayStore(backend: backend)
    await hallway.refresh()
    #expect(await eventually { hallway.me != nil })
    let media = TestSeat(); let peep = TestSeat()
    let controller = DoorController(backend: backend, state: NotchState(), hallway: hallway, media: media, peep: peep, showsWindows: false, availabilityProbe: availability, microphoneAuthorized: micAuthorized, monitorAvailability: false, playKnock: { false })
    controller.quiet = false
    return (backend, hallway, controller, media, peep)
}

@Suite(.serialized) @MainActor struct DoorControllerTests {
    @Test func cancellationBeforeTokenPreventsConnectAndSignal() async {
        let (backend, _, door, media, _) = await fixture()
        await backend.holdVisit()
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        for _ in 0..<100 { if await backend.visitStarted { break }; await Task.yield() }
        door.leaveVisit()
        await backend.releaseVisit()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(media.connects.isEmpty)
        #expect(await backend.announced == 0)
        #expect(door.visiting == nil)
        #expect(!door.room.isActive)
        await door.shutdown()
    }
    @Test func logoutReleasesBothSeatsAndIgnoresLateAdmission() async {
        let (backend, hallway, door, media, peep) = await fixture()
        try? await media.connect(grant, microphone: true, camera: true)
        try? await peep.connect(grant, microphone: false, camera: false)
        hallway.signOut()
        #expect(await eventually { !hallway.isSigningOut })
        await backend.simulate(.admitted(alice, grant, visitID: UUID()))
        #expect(!media.micOn && !media.camOn && !peep.isConnected)
        #expect(media.disconnects > 0 && peep.disconnects > 0)
        #expect(!door.room.isActive)
    }
    @Test func logoutDoesNotWaitForVisitCancellation() async {
        let (backend, hallway, door, media, peep) = await fixture()
        await backend.holdLeave()
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        #expect(await eventually { media.isConnected })
        hallway.signOut()
        for _ in 0..<200 {
            if await backend.leavePending { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await backend.leavePending)
        #expect(await eventually { !hallway.isSigningOut })
        #expect(await backend.signedOut)
        #expect(!media.micOn && !media.camOn && !peep.isConnected)
        #expect(door.visiting == nil && !door.room.isActive)
        await backend.releaseLeave()
        await door.shutdown()
    }
    @Test func quietWalkInNeverCaptures() async {
        let (backend, _, door, media, peep) = await fixture()
        door.quiet = true
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        #expect(media.connects.isEmpty && peep.connects.isEmpty)
        #expect(await backend.admitted.isEmpty)
        await door.shutdown(); door.quiet = false
    }
    @Test func simultaneousKnocksStayOrderedAndLeftIsCorrelated() async {
        let (backend, _, door, _, _) = await fixture()
        door.quiet = true
        let first = UUID(); let second = UUID()
        await backend.simulate(.knock(alice, visitID: first))
        await backend.simulate(.knock(bob, visitID: second))
        #expect(await eventually { door.arrivals.count == 2 })
        #expect(door.visitor?.id == alice.id)
        await backend.simulate(.visitorLeft(bob, visitID: first))
        try? await Task.sleep(for: .milliseconds(10))
        #expect(door.arrivals.count == 2)
        await backend.simulate(.visitorLeft(alice, visitID: first))
        #expect(await eventually { door.visitor?.id == bob.id })
        await backend.simulate(.visitorLeft(alice, visitID: first))
        #expect(door.visitor?.id == bob.id)
        await door.shutdown(); door.quiet = false
    }
    @Test func duplicateAcceptAdmitsExactlySelectedVisit() async {
        let (backend, _, door, _, _) = await fixture()
        door.quiet = true
        let id = UUID()
        await backend.simulate(.knock(alice, visitID: id))
        #expect(await eventually { door.visitor != nil })
        door.openDoor(); door.openDoor()
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        let admits = await backend.admitted
        #expect(admits.count == 1)
        #expect(admits.first?.0 == alice.id && admits.first?.1 == id)
        await door.shutdown(); door.quiet = false
    }
    @Test func walkInDuringExistingRoomWaitsForAdmission() async {
        let (backend, _, door, media, _) = await fixture()
        door.room.start(host: "bob", me: owner, others: [bob])
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        #expect(media.connects.isEmpty)
        #expect(door.room.host == "bob")
        #expect(await backend.admitted.isEmpty)
        await door.shutdown()
    }
    @Test func occupiedKnockAddsToExistingRoomWithoutAnswering() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await occupy(door, media: media)
        let id = UUID()
        await backend.simulate(.knock(alice, visitID: id))
        #expect(await eventually { door.visitor != nil })
        door.openDoor(bringIn: .add)
        #expect(await eventually { !door.isAdmitting && door.visitor == nil })
        let admits = await backend.admitted
        #expect(admits.count == 1 && admits.first?.0 == alice.id && admits.first?.1 == id && admits.first?.2 == bobRoom)
        #expect(await backend.visibleAnswers == 0)
        #expect(door.room.host == bob.handle && door.room.isActive && door.roomName == bobRoom)
        #expect(media.connects.count == 1 && media.isConnected)
        await door.shutdown(); door.quiet = false
    }
    @Test func occupiedKnockEndVacatesThenOpensOwnRoom() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await occupy(door, media: media)
        let id = UUID()
        await backend.simulate(.knock(alice, visitID: id))
        #expect(await eventually { door.visitor != nil })
        door.openDoor(bringIn: .end)
        #expect(await eventually { door.room.isActive && !door.isAdmitting && door.visitor == nil })
        let admits = await backend.admitted
        #expect(admits.count == 1 && admits.first?.0 == alice.id && admits.first?.2 == grant.room)
        #expect(admits.first?.2 != bobRoom)
        #expect(await backend.visibleAnswers == 1)
        #expect(door.room.host == owner.handle && door.roomName == grant.room)
        #expect(media.disconnects >= 1 && media.isConnected)
        await door.shutdown(); door.quiet = false
    }
    @Test func occupiedWalkInWaitsThenAddAndEndWork() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await occupy(door, media: media)
        let addID = UUID()
        await backend.simulate(.walkIn(alice, visitID: addID))
        #expect(await eventually { door.visitor != nil })
        #expect(await backend.admitted.isEmpty)
        #expect(door.room.host == bob.handle)
        door.openDoor(bringIn: .add)
        #expect(await eventually { door.visitor == nil && !door.isAdmitting })
        #expect(await backend.admitted.first?.2 == bobRoom)
        #expect(door.room.host == bob.handle)
        let endID = UUID()
        await backend.simulate(.walkIn(carol, visitID: endID))
        #expect(await eventually { door.visitor?.id == carol.id })
        door.openDoor(bringIn: .end)
        #expect(await eventually { door.room.host == owner.handle && !door.isAdmitting })
        #expect(await backend.admitted.last?.2 == grant.room)
        await door.shutdown(); door.quiet = false
    }
    @Test func fullRoomRefusesAddButEndStillWorks() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await occupy(door, media: media, host: owner.handle, room: "door:owner:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", others: [bob, carol, dave, eve])
        #expect(await eventually { door.room.participants.count >= RoomSession.capacity })
        let id = UUID()
        await backend.simulate(.knock(alice, visitID: id))
        #expect(await eventually { door.visitor != nil })
        door.openDoor(bringIn: .add)
        #expect(door.problem == "This call is full.")
        #expect(await backend.admitted.isEmpty)
        #expect(door.room.isActive && door.visitor?.id == alice.id)
        door.problem = nil
        door.openDoor(bringIn: .end)
        #expect(await eventually { door.room.host == owner.handle && !door.isAdmitting && door.visitor == nil })
        #expect(await backend.admitted.count == 1)
        await door.shutdown(); door.quiet = false
    }
    @Test func knockerLeavingDuringEndDoesNotAdmitOrOpenPhantomRoom() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await occupy(door, media: media)
        let id = UUID()
        await backend.simulate(.knock(alice, visitID: id))
        #expect(await eventually { door.visitor != nil })
        await backend.holdAnswer()
        door.openDoor(bringIn: .end)
        for _ in 0..<200 { if await backend.answerPending { break }; await Task.yield() }
        #expect(await backend.answerPending)
        #expect(!door.room.isActive)
        await backend.simulate(.visitorLeft(alice, visitID: id))
        #expect(await eventually { door.visitor == nil })
        await backend.releaseAnswer()
        #expect(await eventually { !door.isAdmitting })
        #expect(!door.room.isActive && door.roomName == nil)
        #expect(await backend.admitted.isEmpty)
        await door.shutdown(); door.quiet = false
    }
    @Test func duplicateOccupiedAddAdmitsOnce() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await occupy(door, media: media)
        let id = UUID()
        await backend.simulate(.knock(alice, visitID: id))
        #expect(await eventually { door.visitor != nil })
        door.openDoor(bringIn: .add); door.openDoor(bringIn: .add)
        #expect(await eventually { !door.isAdmitting && door.visitor == nil })
        #expect(await backend.admitted.count == 1)
        await door.shutdown(); door.quiet = false
    }
    @Test func guestCanAddKnockerIntoHostRoom() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        let priyaRoom = "door:priya:22222222-2222-2222-2222-222222222222"
        await occupy(door, media: media, host: "priya", room: priyaRoom, others: [bob])
        let id = UUID()
        await backend.simulate(.knock(alice, visitID: id))
        #expect(await eventually { door.visitor != nil })
        door.openDoor(bringIn: .add)
        #expect(await eventually { !door.isAdmitting && door.visitor == nil })
        let admits = await backend.admitted
        #expect(admits.count == 1 && admits.first?.2 == priyaRoom)
        #expect(door.room.host == "priya" && door.room.isActive)
        #expect(await backend.visibleAnswers == 0)
        await door.shutdown(); door.quiet = false
    }
    @Test func failedAdmitAfterEndDoesNotRejoinOldRoom() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await occupy(door, media: media)
        await backend.failAdmits()
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        door.openDoor(bringIn: .end)
        #expect(await eventually { door.problem != nil && !door.isAdmitting })
        #expect(!door.room.isActive && door.roomName == nil)
        #expect(door.visitor?.id == alice.id)
        #expect(!media.isConnected)
        #expect(await backend.admitted.isEmpty)
        await door.shutdown(); door.quiet = false
    }
    @Test func occupiedOwnRoomDoesNotAutoAdmitWalkIn() async {
        let (backend, _, door, media, _) = await fixture()
        door.openDoorPolicy = true
        #expect(await eventually { !door.isUpdatingOpenDoorPolicy })
        await occupy(door, media: media, host: owner.handle, room: "door:owner:33333333-3333-3333-3333-333333333333")
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        #expect(!door.isAdmitting)
        #expect(await backend.admitted.isEmpty)
        #expect(door.room.host == owner.handle)
        await door.shutdown()
    }
    @Test func failedVisitDoesNotOpenPhantomRoom() async {
        let (_, _, door, media, _) = await fixture()
        media.failConnect = true
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        #expect(await eventually { door.problem != nil })
        #expect(!door.room.isActive && door.visiting == nil)
        await door.shutdown()
    }
    @Test func aVisitExpiresEvenWithoutLeftSignal() async {
        let backend = TestBackend(); let hallway = HallwayStore(backend: backend); await hallway.refresh()
        let door = DoorController(backend: backend, state: NotchState(), hallway: hallway, media: TestSeat(), peep: TestSeat(), showsWindows: false, timeout: .milliseconds(40), availabilityProbe: { .available }, microphoneAuthorized: { true }, monitorAvailability: false, playKnock: { false })
        #expect(await eventually { hallway.me != nil })
        door.quiet = true
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        #expect(await eventually { door.visitor == nil })
        await door.shutdown(); door.quiet = false
    }
    @Test func admissionAfterLeavingMatchingVisitCannotReopenMedia() async throws {
        let (backend, _, door, media, _) = await fixture()
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        #expect(await eventually { media.connects.count == 1 })
        let id = try #require(await backend.lastVisitID)
        door.leaveVisit()
        await backend.simulate(.admitted(alice, grant, visitID: id))
        #expect(await eventually { !media.isConnected })
        #expect(media.connects.count == 1 && !door.room.isActive)
        await door.shutdown()
    }
    @Test func admissionFailureClosesNewHostSeatAndAllowsRetry() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await backend.failAdmits()
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        door.openDoor()
        #expect(await eventually { door.problem != nil && !door.isAdmitting })
        #expect(!media.isConnected && !media.micOn && !media.camOn)
        #expect(!door.room.isActive && door.roomName == nil && door.visitor != nil)
        await door.shutdown(); door.quiet = false
    }
    @Test func acceptingInterruptsOutgoingVisitAndIgnoresItsLateAdmission() async throws {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        #expect(await eventually { media.isConnected })
        let oldVisit = try #require(await backend.lastVisitID)
        await backend.simulate(.knock(bob, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        door.openDoor()
        #expect(door.visiting == nil && door.problem == nil)
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        #expect(media.connects.count == 2 && media.isConnected)
        let departed = await backend.departed
        #expect(departed.count == 1 && departed[0].0 == alice.id && departed[0].1 == oldVisit)
        #expect(await backend.admitted.count == 1)
        await backend.simulate(.admitted(alice, grant, visitID: oldVisit))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(media.connects.count == 2 && door.room.host == owner.handle)
        await door.shutdown(); door.quiet = false
    }
    @Test func windowCloseInvalidatesBeforeImmediateNextVisit() async {
        let (_, _, door, media, _) = await fixture()
        door.room.start(host: owner.handle, me: owner, others: [])
        try? await media.connect(grant, microphone: true, camera: true)
        door.closeRoom()
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        #expect(door.visiting == nil && !door.room.isActive)
        #expect(await eventually { !media.isConnected })
        await door.shutdown()
    }

    @Test func staleHallwayResponseCannotRestoreSignedOutAccount() async {
        let (backend, hallway, door, _, _) = await fixture()
        await backend.holdHallway()
        let refreshing = Task { await hallway.refresh() }
        for _ in 0..<200 { if await backend.hallwayPending { break }; await Task.yield() }
        #expect(await backend.hallwayPending)
        hallway.signOut()
        #expect(await eventually { !hallway.isSigningOut && hallway.account == .signedOut })
        await backend.releaseHallway()
        await refreshing.value
        #expect(hallway.account == .signedOut && hallway.me == nil)
        await door.shutdown()
    }

    @Test func enablingQuietCancelsPendingAutomaticWalkIn() async {
        let (backend, _, door, media, _) = await fixture()
        await backend.holdAnswer()
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        for _ in 0..<200 { if await backend.answerPending { break }; await Task.yield() }
        #expect(await backend.answerPending)
        door.quiet = true
        await backend.releaseAnswer()
        #expect(await eventually { !door.isAdmitting })
        #expect(media.connects.isEmpty && !door.room.isActive)
        #expect(await backend.admitted.isEmpty)
        await door.shutdown(); door.quiet = false
    }

    @Test func acceptingDoesNotWaitForRemoteDeparture() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await backend.holdLeave()
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        #expect(await eventually { media.isConnected })
        await backend.simulate(.knock(bob, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        door.openDoor()
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        #expect(await backend.leavePending)
        await backend.releaseLeave()
        await door.shutdown(); door.quiet = false
    }

    @Test func acceptingWaitsForOldSeatTeardownThenKeepsNewSeat() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        #expect(await eventually { media.isConnected })
        media.holdNextDisconnect = true
        door.leaveVisit()
        #expect(await eventually { media.disconnectWaiter != nil })
        await backend.simulate(.knock(bob, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        door.openDoor()
        #expect(door.isAdmitting)
        #expect(media.connects.count == 1)
        #expect(door.blocksAutomaticUpdate)
        media.releaseDisconnect()
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        #expect(media.connects.count == 2 && media.isConnected)
        await door.shutdown(); door.quiet = false
    }

    @Test func acceptingInvalidatesOutgoingTokenStillInFlight() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        await backend.holdVisit()
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        for _ in 0..<100 { if await backend.visitStarted { break }; await Task.yield() }
        await backend.simulate(.knock(bob, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        door.openDoor()
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        await backend.releaseVisit()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(media.connects.count == 1 && door.visiting == nil)
        #expect(await backend.announced == 0)
        await door.shutdown(); door.quiet = false
    }

    @Test func doorstepSharesMicOnlyWithPermissionAndStopsForFocus() async {
        let status = AvailabilityBox()
        let (backend, _, door, _, peep) = await fixture(availability: { status.value })
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { peep.micOn })
        #expect(!peep.camOn)
        #expect(await eventually { abs(peep.playbackGain - Double(DesignTokens.doorVolume)) < 0.001 })
        door.toggleListening()
        #expect(await eventually { peep.playbackGain == 1 })
        status.value = .focusOn; door.refreshAvailability()
        #expect(await eventually { !peep.micOn && peep.playbackGain == 0 })
        door.toggleListening()
        #expect(await eventually { peep.playbackGain == 1 })
        #expect(!peep.micOn)
        #expect(door.doorstepAudioStatus == "Full volume · Your mic is off")
        door.openDoor()
        #expect(await eventually { door.room.isActive })
        await door.shutdown()
    }

    @Test func missingMicrophonePermissionNeverStartsBackgroundCapture() async {
        let (backend, _, door, _, peep) = await fixture(micAuthorized: { false })
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { peep.isConnected })
        door.toggleListening()
        #expect(await eventually { peep.playbackGain == 1 })
        #expect(!peep.micOn && door.microphoneAccessNeeded)
        await door.shutdown()
    }

    @Test func previewCannotPublishOrLowerExistingConversation() async {
        let (backend, _, door, media, peep) = await fixture()
        door.room.start(host: owner.handle, me: owner, others: [bob])
        media.fadePlayback(to: 1, duration: 0)
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { peep.isConnected })
        #expect(!peep.micOn && peep.playbackGain == 0)
        door.toggleListening()
        #expect(await eventually { peep.playbackGain == 1 })
        #expect(!peep.micOn && media.playbackGain == 1)
        door.dismissPeephole()
        #expect(await eventually { !peep.isConnected })
        #expect(media.playbackGain == 1)
        await door.shutdown()
    }

    @Test func openDoorPolicyPersistsAndFailedSaveRollsBack() async {
        let (backend, hallway, door, _, _) = await fixture()
        #expect(!door.openDoorPolicy)
        door.openDoorPolicy = true
        #expect(door.blocksAutomaticUpdate)
        #expect(await eventually { !door.isUpdatingOpenDoorPolicy })
        #expect(hallway.me?.openDoorPolicy == true)
        await backend.failPolicyChanges()
        door.openDoorPolicy = false
        #expect(await eventually { door.openDoorPolicyProblem != nil && !door.isUpdatingOpenDoorPolicy })
        #expect(door.openDoorPolicy)
        await door.shutdown()
    }

    @Test func outgoingVisitImmediatelyMutesExistingDoorstep() async {
        let (backend, _, door, _, peep) = await fixture()
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { peep.micOn })
        await backend.holdVisit()
        door.visit(Door(profile: bob, followsMe: true, isCloseFriend: false))
        #expect(await eventually { !peep.micOn })
        door.leaveVisit()
        await backend.releaseVisit()
        await door.shutdown()
    }

    @Test func visitorLeavingDuringAnswerCannotStartDevices() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        let id = UUID()
        await backend.simulate(.knock(alice, visitID: id))
        #expect(await eventually { door.visitor != nil })
        await backend.holdAnswer()
        door.openDoor()
        for _ in 0..<200 { if await backend.answerPending { break }; await Task.yield() }
        #expect(await backend.answerPending)
        await backend.simulate(.visitorLeft(alice, visitID: id))
        #expect(await eventually { door.visitor == nil })
        await backend.releaseAnswer()
        #expect(await eventually { !door.isAdmitting })
        #expect(media.connects.isEmpty && !door.room.isActive)
        #expect(await backend.admitted.isEmpty)
        await door.shutdown(); door.quiet = false
    }

    @Test func failedAdmissionRestoresQuietTwoWayPreview() async {
        let (backend, _, door, _, peep) = await fixture()
        await backend.failAdmits()
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { peep.micOn })
        door.openDoor()
        #expect(await eventually { door.problem != nil && !door.isAdmitting && peep.micOn })
        #expect(!door.room.isActive && !peep.camOn)
        await door.shutdown()
    }

    @Test func openDoorPolicyDrainsQueuedWalkInsIntoOwnRoom() async {
        let (backend, _, door, _, _) = await fixture()
        door.openDoorPolicy = true
        #expect(await eventually { !door.isUpdatingOpenDoorPolicy })
        await backend.holdAnswer()
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        for _ in 0..<200 { if await backend.answerPending { break }; await Task.yield() }
        #expect(await backend.answerPending)
        await backend.simulate(.walkIn(bob, visitID: UUID()))
        #expect(await eventually { door.arrivals.count == 2 })
        await backend.releaseAnswer()
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        #expect(await backend.admitted.count == 1)
        #expect(door.visitor?.id == bob.id)
        door.openDoor(bringIn: .add)
        #expect(await eventually { door.arrivals.isEmpty && !door.isAdmitting })
        #expect(await backend.admitted.count == 2)
        #expect(door.room.host == owner.handle)
        await door.shutdown()
    }

    @Test func openDoorPolicyCannotAutomaticallyInviteIntoSomeoneElsesRoom() async {
        let (backend, _, door, _, _) = await fixture()
        door.openDoorPolicy = true
        #expect(await eventually { !door.isUpdatingOpenDoorPolicy })
        door.room.start(host: bob.handle, me: owner, others: [bob])
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        #expect(!door.isAdmitting)
        #expect(await backend.admitted.isEmpty)
        await door.shutdown()
    }

    @Test func automaticWalkInNeverPromptsForMicrophonePermission() async {
        let (backend, _, door, media, _) = await fixture(micAuthorized: { false })
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        #expect(media.connects.count == 1 && media.connects.first?.0 == false)
        await door.shutdown()
    }

    @Test func unreadableProvisionedFocusPausesWalkInButStillAccepts() async {
        let (backend, _, door, media, peep) = await fixture(availability: { .focusStatusUnavailable })
        let visit = UUID()
        await backend.simulate(.walkIn(alice, visitID: visit))
        #expect(await eventually { door.visitor != nil })
        #expect(media.connects.isEmpty && peep.connects.isEmpty)
        #expect(await backend.admitted.isEmpty)
        door.openDoor()
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        #expect(await backend.admitted.count == 1)
        await door.shutdown()
    }

    @Test func sixHourQuietExpiresAfterSleepWithoutResettingAndResumesWalkIn() async {
        let name = "Doorbell.QuietControllerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let backend = TestBackend()
        let hallway = HallwayStore(backend: backend)
        await hallway.refresh()
        let media = TestSeat(); let peep = TestSeat()
        let door = DoorController(backend: backend, state: NotchState(), hallway: hallway,
            media: media, peep: peep, showsWindows: false, availabilityProbe: { .available },
            microphoneAuthorized: { true }, monitorAvailability: false,
            quietDefaults: defaults, now: { clock }, playKnock: { false })
        door.quiet = true
        let deadline = door.quietUntil
        clock = clock.addingTimeInterval(3_600)
        door.refreshAvailability()
        door.quiet = true // repeated writes must not extend a running timer
        #expect(door.quietUntil == deadline)
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        #expect(media.connects.isEmpty && peep.connects.isEmpty)
        clock = clock.addingTimeInterval(18_000)
        door.refreshAvailability()
        #expect(!door.quiet && door.quietUntil == nil)
        #expect(!defaults.bool(forKey: SettingsKey.quiet))
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        #expect(await backend.admitted.count == 1)
        await door.shutdown()
    }

    @Test func queuedWalkInResumesAfterFocusEnds() async {
        let status = AvailabilityBox(); status.value = .focusOn
        let (backend, _, door, media, _) = await fixture(availability: { status.value })
        await backend.simulate(.walkIn(alice, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        #expect(media.connects.isEmpty)
        status.value = .available; door.refreshAvailability()
        #expect(await eventually { door.room.isActive && !door.isAdmitting })
        #expect(await backend.admitted.count == 1)
        await door.shutdown()
    }

    @Test func olderSavedProfilesKeepOpenDoorOffByDefault() throws {
        let data = Data(#"{"id":"owner","handle":"owner","displayName":"Owner"}"#.utf8)
        var profile = try JSONDecoder().decode(Profile.self, from: data)
        #expect(!profile.openDoorPolicy)
        profile.openDoorPolicy = true
        let restored = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(restored.openDoorPolicy)
    }

    @Test func updaterWaitsForActualRoomTeardown() async {
        let (_, _, door, media, _) = await fixture()
        door.room.start(host: owner.handle, me: owner, others: [])
        try? await media.connect(grant, microphone: true, camera: true)
        media.holdNextDisconnect = true
        door.closeRoom()
        #expect(await eventually { media.disconnectWaiter != nil })
        #expect(!door.room.isActive && door.blocksAutomaticUpdate)
        media.releaseDisconnect()
        #expect(await eventually { !door.blocksAutomaticUpdate })
        await door.shutdown()
    }

    @Test func focusDuringPreviewReconnectDisconnectsCapture() async {
        let status = AvailabilityBox()
        let (backend, _, door, _, peep) = await fixture(availability: { status.value })
        await backend.simulate(.knock(alice, visitID: UUID()))
        #expect(await eventually { peep.micOn })
        peep.phase = .reconnecting
        status.value = .focusOn; door.refreshAvailability()
        #expect(await eventually { peep.phase == .idle && !peep.micOn })
        await door.shutdown()
    }

}
