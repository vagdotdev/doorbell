import Foundation
import Testing
@testable import DoorbellApp

private let owner = Profile(id: "00000000-0000-0000-0000-000000000001", handle: "owner", displayName: "Owner", avatarURL: nil)
private let alice = Profile(id: "00000000-0000-0000-0000-000000000002", handle: "alice", displayName: "Alice", avatarURL: nil)
private let bob = Profile(id: "00000000-0000-0000-0000-000000000003", handle: "bob", displayName: "Bob", avatarURL: nil)
private let grant = MediaGrant(url: "ws://localhost:7880", token: "test", room: "door:owner")

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
    var announced = 0
    var signedOut = false
    var failAdmission = false
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
        return .init(me: owner, doors: [], requests: [], outgoing: [])
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
    func leaveVisit(_ id: String, visitID: UUID) async {}
    func holdAnswer() { heldAnswer = true }
    var answerPending: Bool { answerWaiter != nil }
    func releaseAnswer() { answerWaiter?.resume(); answerWaiter = nil }
    func answer(hidden: Bool, visitID: UUID?) async throws -> MediaGrant? {
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
    override func connect(_ grant: MediaGrant, microphone: Bool, camera: Bool) async throws {
        if failConnect { throw URLError(.cannotConnectToHost) }
        connects.append((microphone, camera)); phase = .connected
        micOn = microphone; camOn = camera
    }
    override func disconnect() async {
        disconnects += 1; phase = .idle; micOn = false; camOn = false; peers = []
    }
}

@MainActor private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return predicate()
}
@MainActor private func fixture() async -> (TestBackend, HallwayStore, DoorController, TestSeat, TestSeat) {
    let backend = TestBackend()
    let hallway = HallwayStore(backend: backend)
    await hallway.refresh()
    #expect(await eventually { hallway.me != nil })
    let media = TestSeat(); let peep = TestSeat()
    let controller = DoorController(backend: backend, state: NotchState(), hallway: hallway, media: media, peep: peep, showsWindows: false)
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
        let door = DoorController(backend: backend, state: NotchState(), hallway: hallway, media: TestSeat(), peep: TestSeat(), showsWindows: false, timeout: .milliseconds(40))
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
    @Test func answeringWhileVisitingCannotReplaceTheOutgoingSeat() async {
        let (backend, _, door, media, _) = await fixture()
        door.quiet = true
        door.visit(Door(profile: alice, followsMe: true, isCloseFriend: false))
        #expect(await eventually { media.isConnected })
        await backend.simulate(.knock(bob, visitID: UUID()))
        #expect(await eventually { door.visitor != nil })
        door.openDoor()
        #expect(door.problem != nil && !door.isAdmitting)
        #expect(media.connects.count == 1 && door.visiting?.profile.id == alice.id)
        #expect(await backend.admitted.isEmpty)
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

}
