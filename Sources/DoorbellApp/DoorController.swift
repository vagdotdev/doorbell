import SwiftUI

/// The door moments: someone at my door, me at theirs, and the room that opens.
@MainActor
final class DoorController: ObservableObject {
    /// Who's in the peephole right now.
    @Published private(set) var visitor: Profile?
    /// Door volume → full volume for the current visitor.
    @Published var listening = false
    /// Which door I'm standing at.
    @Published private(set) var visiting: Door?

    /// My seat in whichever room I'm in: mine, or the one I walked or was let into.
    let media = MediaSession()
    /// My hidden seat behind my own door while someone knocks.
    let peep = MediaSession()
    let room: RoomSession

    private let backend: any DoorbellBackend
    private let state: NotchState
    private let hallway: HallwayStore
    private lazy var roomWindow = RoomWindowController(session: room)
    private var eventTask: Task<Void, Never>?
    private var visitTimeout: Task<Void, Never>?
    private var audioArriveTask: Task<Void, Never>?

    init(backend: any DoorbellBackend, state: NotchState, hallway: HallwayStore) {
        self.backend = backend
        self.state = state
        self.hallway = hallway
        room = RoomSession(media: media)
        room.onLeave = { [weak self] in self?.roomClosed() }
        eventTask = Task { [weak self] in
            for await event in backend.events {
                self?.handle(event)
            }
        }
    }

    // MARK: Me at their door

    func visit(_ door: Door) {
        Task {
            guard let me = hallway.me else { return }
            let visit: Visit
            do { visit = try await backend.visit(door.id) }
            catch { NSLog("door: visit failed: \(error)"); return }
            NSLog("door: at \(door.profile.handle)’s door (\(visit.mode))")
            // Show the moment first; the seat (connect, camera, mic) fills in behind it.
            switch visit.mode {
            case .walkIn:
                IncomingAudio.shared.arrive(muffled: false)
                openRoom(title: "\(firstName(door.profile))’s room", me: me, others: [door.profile])
            case .knock:
                visiting = door
                state.mode = .visiting(door)
                // The door opens when the owner appears in the room. Trade seats and go in.
                media.onPeerJoined = { [weak self] _ in self?.doorOpened(door) }
                visitTimeout?.cancel()
                visitTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.leaveVisit()
                }
            }
            if let grant = visit.grant {
                try? await media.connect(grant, microphone: true, camera: true)
            }
        }
    }

    func leaveVisit() {
        guard let door = visiting else { return }
        NSLog("door: leaving \(door.profile.handle)")
        visitTimeout?.cancel()
        visiting = nil
        media.onPeerJoined = nil
        if case .visiting = state.mode { state.mode = .hallway }
        Task {
            await media.disconnect()
            await backend.leaveVisit(door.id)
        }
    }

    private func doorOpened(_ door: Door) {
        guard visiting?.id == door.id, let me = hallway.me else { return }
        NSLog("door: \(door.profile.handle) opened")
        visitTimeout?.cancel()
        visiting = nil
        media.onPeerJoined = nil
        if case .visiting = state.mode { state.mode = .hallway }
        Task {
            if media.isConnected {
                // A knocker's seat can't hear or see; trade it for a full one.
                guard let grant = try? await backend.knockAnswered(door.id) else {
                    NSLog("door: \(door.profile.handle) did not let me in")
                    await media.disconnect()
                    return
                }
                await media.disconnect()
                try? await media.connect(grant, microphone: true, camera: true)
            }
            IncomingAudio.shared.arrive(muffled: false)
            openRoom(title: "\(firstName(door.profile))’s room", me: me, others: [door.profile])
        }
    }

    // MARK: Them at my door

    func openDoor() {
        guard let visitor, let me = hallway.me else { return }
        Task {
            await peep.disconnect()
            if let grant = try? await backend.answer(hidden: false) {
                try? await media.connect(grant, microphone: true, camera: true)
            }
            IncomingAudio.shared.arrive(muffled: false)
            openRoom(title: "Your room", me: me, others: [visitor])
            dismissPeephole(stopAudio: false)
        }
    }

    func toggleListening() {
        listening.toggle()
        IncomingAudio.shared.setListening(listening)
    }

    func dismissPeephole(stopAudio: Bool = true) {
        audioArriveTask?.cancel()
        visitor = nil
        listening = false
        if stopAudio { IncomingAudio.shared.depart() }
        if case .peephole = state.mode { state.mode = .hallway }
        Task { await peep.disconnect() }
    }

    // MARK: -

    private func handle(_ event: DoorEvent) {
        switch event {
        case .knock(let who):
            visitor = who
            listening = false
            state.mode = .peephole(who)
            state.knockBounce()
            Sounds.knock()
            audioArriveTask?.cancel()
            audioArriveTask = Task {
                // Peek: a hidden seat, no mic, no camera. They cannot tell anyone is there.
                if let grant = try? await backend.answer(hidden: true) {
                    try? await peep.connect(grant, microphone: false, camera: false)
                }
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                IncomingAudio.shared.arrive(muffled: true)
            }
            // Development: DOORBELL_AUTO_OPEN=<seconds> answers the door unattended.
            if let wait = ProcessInfo.processInfo.environment["DOORBELL_AUTO_OPEN"].flatMap(Double.init) {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    self?.openDoor()
                }
            }
        case .walkIn(let who):
            guard let me = hallway.me else { return }
            Sounds.creak()
            Task {
                if let grant = try? await backend.answer(hidden: false) {
                    try? await media.connect(grant, microphone: true, camera: true)
                }
                IncomingAudio.shared.arrive(muffled: false)
                openRoom(title: "Your room", me: me, others: [who])
            }
        case .visitorLeft(let who):
            if visitor == who { dismissPeephole() }
        }
    }

    private func openRoom(title: String, me: Profile, others: [Profile]) {
        if room.isActive {
            return   // already in: they'll appear as a tile
        }
        room.start(title: title, me: me, others: others)
        roomWindow.present()
    }

    private func roomClosed() {
        IncomingAudio.shared.depart()
        if let door = visiting {
            visiting = nil
            Task { await backend.leaveVisit(door.id) }
        }
    }

    private func firstName(_ p: Profile) -> String {
        p.displayName.split(separator: " ").first.map(String.init) ?? p.handle
    }

    // Development: the mock's door bell.
    func simulate(_ event: DoorEvent) {
        Task { await backend.simulate(event) }
    }
}
