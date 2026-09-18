import Combine
import SwiftUI

/// A visit has one ID from click through admission. Late events cannot revive it.
@MainActor
final class DoorController: ObservableObject {
    struct Arrival: Identifiable {
        let id: UUID
        let profile: Profile
        let walksIn: Bool
    }
    @Published private(set) var arrivals: [Arrival] = []
    var visitor: Profile? { arrivals.first?.profile }
    @Published private(set) var listening = false
    @Published private(set) var visiting: Door?
    @Published private(set) var isAdmitting = false
    @Published var problem: String?
    @Published var quiet: Bool {
        didSet {
            UserDefaults.standard.set(quiet, forKey: SettingsKey.quiet)
            if quiet {
                listening = false; peep.volumeScale = 0
                if automaticAdmission, !room.isActive { admissionTask?.cancel() }
            }
        }
    }
    let media: MediaSession
    let peep: MediaSession
    let room: RoomSession
    private let backend: any DoorbellBackend
    private let state: NotchState
    private let hallway: HallwayStore
    private let showsWindows: Bool
    private let timeout: Duration
    private(set) var roomName: String?
    private lazy var roomWindow = RoomWindowController(session: room, door: self)
    private var eventTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var arrivalTask: Task<Void, Never>?
    private var admissionTask: Task<Void, Never>?
    private var automaticAdmission = false
    private var visitTimeout: Task<Void, Never>?
    private var arrivalTimeouts: [UUID: Task<Void, Never>] = [:]
    private var outgoingID: UUID?
    private let generation = OperationGeneration()
    private var accountSink: AnyCancellable?
    private var shuttingDown = false
    private var isLeaving = false

    init(backend: any DoorbellBackend, state: NotchState, hallway: HallwayStore,
         media: MediaSession = MediaSession(), peep: MediaSession = MediaSession(),
         showsWindows: Bool = true, timeout: Duration = .seconds(30)) {
        self.backend = backend; self.state = state; self.hallway = hallway
        self.media = media; self.peep = peep; self.showsWindows = showsWindows; self.timeout = timeout
        quiet = UserDefaults.standard.bool(forKey: SettingsKey.quiet)
        room = RoomSession(media: media)
        room.onLeave = { [weak self] in self?.requestLeaveRoom() }
        hallway.beforeSignOut = { [weak self] in await self?.shutdown() }
        accountSink = hallway.$account.dropFirst().removeDuplicates().sink { [weak self] account in
            if account == .signedOut { Task { await self?.shutdown() } }
        }
        eventTask = Task { [weak self] in
            for await event in backend.events { self?.handle(event) }
        }
    }

    func visit(_ door: Door) {
        guard !shuttingDown, !isLeaving, !isAdmitting, !hallway.isSigningOut, hallway.me != nil else { return }
        guard !room.isActive else { problem = "Leave this room before visiting another door."; return }
        guard visiting == nil else { return }
        let ticket = generation.advance()
        let id = UUID()
        outgoingID = id; visiting = door; problem = nil
        state.mode = .visiting(door)
        visitTimeout = Task { [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(30))
            guard !Task.isCancelled else { return }
            self?.leaveVisit()
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let visit = try await backend.visit(door.id, visitID: id)
                try generation.check(ticket)
                if let grant = visit.grant {
                    try await media.connect(grant, microphone: true, camera: true)
                    try generation.check(ticket)
                    // Signal only after the guest really occupies the isolated doorstep.
                    try await backend.announceVisit(door.id, visitID: id)
                    try generation.check(ticket)
                } else if visit.mode == .walkIn { // Development hallway only.
                    finishVisit()
                    openRoom(host: door.profile.handle, others: [door.profile])
                }
            } catch {
                guard generation.isCurrent(ticket) else { return }
                problem = "Couldn’t reach that door. Check your connection and try again."
                leaveVisit()
            }
        }
    }

    func leaveVisit() {
        guard let door = visiting, let id = outgoingID else { return }
        isLeaving = true
        generation.advance(); operation?.cancel(); visitTimeout?.cancel()
        visiting = nil; outgoingID = nil
        state.mode = .building
        Task {
            await media.disconnect()
            isLeaving = false
            await backend.leaveVisit(door.id, visitID: id)
        }
    }
    private func finishVisit() {
        visitTimeout?.cancel()
        visiting = nil; outgoingID = nil
        if case .visiting = state.mode { state.mode = .building }
    }
    private func admitted(by who: Profile, grant: MediaGrant, visitID: UUID) {
        guard outgoingID == visitID, visiting?.profile.id == who.id, !shuttingDown else { return }
        let ticket = generation.advance()
        operation?.cancel()
        // Keep the outgoing visit cancellable until the room seat actually connects.
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await media.disconnect()
                try generation.check(ticket)
                try await media.connect(grant, microphone: true, camera: true)
                try generation.check(ticket)
                finishVisit()
                roomName = grant.room
                let host = grant.room.hasPrefix("door:") ? String(grant.room.dropFirst(5)) : who.handle
                openRoom(host: host, others: [who])
            } catch {
                guard generation.isCurrent(ticket) else { return }
                problem = "Couldn’t enter the room. Try knocking again."
                leaveVisit()
            }
        }
    }

    func openDoor(automatically: Bool = false) {
        guard let arrival = arrivals.first, hallway.me != nil, !isAdmitting, !shuttingDown, !isLeaving else { return }
        guard visiting == nil else { problem = "Leave the doorstep before letting someone in."; return }
        Sounds.stopKnock()
        arrivalTask?.cancel()
        guard !automatically || !quiet else { return }
        isAdmitting = true
        automaticAdmission = automatically
        let ticket = generation.current
        admissionTask = Task { [weak self] in
            guard let self else { return }
            var openedSeat = false
            defer { if generation.isCurrent(ticket) { isAdmitting = false; automaticAdmission = false } }
            do {
                await peep.disconnect()
                try generation.check(ticket)
                guard arrivals.first?.id == arrival.id else { throw CancellationError() }
                if !room.isActive {
                    if let grant = try await backend.answer(hidden: false, visitID: nil) {
                        try generation.check(ticket)
                        try await media.connect(grant, microphone: true, camera: true)
                        openedSeat = true
                        try generation.check(ticket)
                        roomName = grant.room
                    }
                }
                guard arrivals.first?.id == arrival.id else { throw CancellationError() }
                try await backend.admit(arrival.profile.id, visitID: arrival.id, into: roomName)
                try generation.check(ticket)
                if !room.isActive {
                    openRoom(host: hallway.me?.handle ?? "", others: [arrival.profile])
                }
                removeArrival(arrival.id)
            } catch {
                if openedSeat, !room.isActive, generation.isCurrent(ticket) { await media.disconnect(); roomName = nil }
                guard generation.isCurrent(ticket), !shuttingDown, !Task.isCancelled else { return }
                problem = "Couldn’t let them in. They may have left. Try again."
                if arrivals.first?.id == arrival.id { showCurrentArrival() }
            }
        }
    }

    func toggleListening() {
        listening.toggle()
        if listening { Sounds.stopKnock() }
        peep.volumeScale = listening ? 1 : ((quiet || room.isActive) ? 0 : 1)
        if !room.isActive { IncomingAudio.shared.setListening(listening) }
        if listening, !peep.isConnected { showCurrentArrival() }
    }
    func dismissPeephole(stopAudio: Bool = true) {
        guard !isAdmitting, let id = arrivals.first?.id else { return }
        Sounds.stopKnock()
        removeArrival(id)
    }

    /// Clicked the do-not-disturb pinhole: look properly.
    func answerPinhole() {
        guard case .pinhole(_, let walkedIn) = state.mode else { return }
        if walkedIn { openDoor() }
        else { showCurrentArrival() }
    }
    private func removeArrival(_ id: UUID) {
        let wasFirst = arrivals.first?.id == id
        arrivalTimeouts.removeValue(forKey: id)?.cancel()
        arrivals.removeAll { $0.id == id }
        if wasFirst {
            arrivalTask?.cancel()
            listening = false
            if arrivals.isEmpty { Task { await peep.disconnect() } }
            showCurrentArrival()
        }
    }
    private func showCurrentArrival(handoff: Bool = false) {
        guard let arrival = arrivals.first else {
            if case .peephole = state.mode { state.mode = .building }
            if !room.isActive { IncomingAudio.shared.depart() }
            return
        }
        state.mode = .peephole(arrival.profile)
        peep.volumeScale = listening ? 1 : ((quiet || room.isActive) ? 0 : 1)
        guard !quiet || listening else { return }
        let knockedAt = ContinuousClock.now
        arrivalTask?.cancel()
        arrivalTask = Task { [weak self] in
            guard let self else { return }
            do {
                await peep.disconnect()
                try Task.checkCancellation()
                let grant = try await backend.answer(hidden: true, visitID: arrival.id)
                try Task.checkCancellation()
                guard arrivals.first?.id == arrival.id, !shuttingDown else { return }
                if let grant { try await peep.connect(grant, microphone: false, camera: false) }
                try Task.checkCancellation()
                guard arrivals.first?.id == arrival.id else { return }
                if handoff {
                    try? await Task.sleep(until: knockedAt + .seconds(Sounds.knockHandoff), clock: .continuous)
                    guard !Task.isCancelled, arrivals.first?.id == arrival.id else { return }
                }
                if !room.isActive { IncomingAudio.shared.arrive(muffled: !listening) }
            } catch {
                guard !Task.isCancelled, arrivals.first?.id == arrival.id else { return }
                problem = "Preview unavailable. You can still try letting them in."
            }
        }
    }
    private func enqueue(_ profile: Profile, id: UUID, walkIn: Bool) {
        guard !shuttingDown, hallway.me != nil, !arrivals.contains(where: { $0.id == id }), arrivals.count < 5 else { return }
        let arrival = Arrival(id: id, profile: profile, walksIn: walkIn)
        arrivals.append(arrival)
        arrivalTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(30))
            guard !Task.isCancelled else { return }
            self?.removeArrival(id)
        }
        guard arrivals.first?.id == id else { return }
        if walkIn, !quiet, !room.isActive, visiting == nil { openDoor(automatically: true); return }
        let rang: Bool
        if !quiet {
            state.knockBounce()
            rang = Sounds.knock()
        } else {
            rang = false
        }
        showCurrentArrival(handoff: rang)
    }
    private func handle(_ event: DoorEvent) {
        switch event {
        case .knock(let who, let id): enqueue(who, id: id, walkIn: false)
        case .walkIn(let who, let id): enqueue(who, id: id, walkIn: true)
        case .visitorLeft(let who, let id):
            if arrivals.contains(where: { $0.id == id && $0.profile.id == who.id }) { removeArrival(id) }
        case .admitted(let who, let grant, let id): admitted(by: who, grant: grant, visitID: id)
        }
    }
    private func openRoom(host: String, others: [Profile]) {
        guard let me = hallway.me, !shuttingDown else { return }
        IncomingAudio.shared.arrive(muffled: false)
        if !room.isActive { room.start(host: host, me: me, others: others) }
        if showsWindows { roomWindow.present() }
    }
    func closeRoom() {
        if showsWindows { roomWindow.close() }
        else { room.leave() }
    }
    private func requestLeaveRoom() {
        guard !shuttingDown, !isLeaving else { return }
        isLeaving = true
        generation.advance(); operation?.cancel(); admissionTask?.cancel()
        isAdmitting = false
        finishVisit(); room.reset(); roomName = nil
        IncomingAudio.shared.depart()
        Task {
            await media.disconnect()
            isLeaving = false
        }
    }
    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        generation.advance()
        operation?.cancel(); admissionTask?.cancel(); arrivalTask?.cancel(); visitTimeout?.cancel()
        for task in arrivalTimeouts.values { task.cancel() }
        arrivalTimeouts = [:]; arrivals = []; listening = false; isAdmitting = false
        let oldDoor = visiting; let oldID = outgoingID
        finishVisit(); room.reset(); roomName = nil
        if showsWindows { roomWindow.close() }
        await media.disconnect()
        await peep.disconnect()
        if let oldDoor, let oldID { await backend.leaveVisit(oldDoor.id, visitID: oldID) }
        state.mode = .building
        IncomingAudio.shared.depart()
        shuttingDown = false
    }
    func simulate(_ event: DoorEvent) { Task { await backend.simulate(event) } }
}
