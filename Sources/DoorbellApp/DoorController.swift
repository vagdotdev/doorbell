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
    /// The LiveKit room my `media` seat is in — mine, or one I'm a guest in. This is
    /// where a knocker goes when I let them in.
    private var roomName: String?
    private lazy var roomWindow = RoomWindowController(session: room, door: self)
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
                roomName = visit.grant?.room
                openRoom(host: door.profile.handle, me: me, others: [door.profile])
            case .knock:
                visiting = door
                state.mode = .visiting(door)
                // I wait on the step. If they let me in, `.admitted` arrives at my door.
                visitTimeout?.cancel()
                visitTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.leaveVisit()
                }
            }
            if let grant = visit.grant {
                try? await media.connect(grant, microphone: true, camera: true)
                // Mic is live now: the one moment macOS lets Voice Isolation be chosen.
                if media.isConnected { MicrophoneMode.nudgeOnce() }
            }
        }
    }

    func leaveVisit() {
        guard let door = visiting else { return }
        NSLog("door: leaving \(door.profile.handle)")
        visitTimeout?.cancel()
        visiting = nil
        if case .visiting = state.mode { state.mode = .hallway }
        Task {
            await media.disconnect()
            await backend.leaveVisit(door.id)
        }
    }

    /// They opened. Trade the seat on the step for the one they gave me — in their
    /// room, or in whichever room they're in, meeting whoever is there.
    private func admitted(by who: Profile, grant: MediaGrant) {
        guard visiting?.profile == who, let me = hallway.me else { return }
        NSLog("door: \(who.handle) let me in → \(grant.room)")
        visitTimeout?.cancel()
        visiting = nil
        if case .visiting = state.mode { state.mode = .hallway }
        Task {
            await media.disconnect()
            try? await media.connect(grant, microphone: true, camera: true)
            roomName = grant.room
            IncomingAudio.shared.arrive(muffled: false)
            // `door:<handle>`: whose room I've landed in — theirs, or the one they're a guest in.
            let host = grant.room.hasPrefix("door:") ? String(grant.room.dropFirst(5)) : who.handle
            openRoom(host: host, me: me, others: [who])
        }
    }

    // MARK: Them at my door

    /// Let the knocker in. Into the room I'm already in, if there is one — the person
    /// at the door meets whoever I'm with. Otherwise my own room opens for them.
    func openDoor() {
        guard let guest = visitor, let me = hallway.me else { return }
        Task {
            await peep.disconnect()
            if room.isActive, let roomName {
                room.include(guest)
                try? await backend.admit(guest.id, into: roomName)
            } else {
                if let grant = try? await backend.answer(hidden: false) {
                    roomName = grant.room
                    try? await media.connect(grant, microphone: true, camera: true)
                }
                IncomingAudio.shared.arrive(muffled: false)
                openRoom(host: me.handle, me: me, others: [guest])
                try? await backend.admit(guest.id, into: roomName)
            }
            dismissPeephole(stopAudio: false)
        }
    }

    func toggleListening() {
        listening.toggle()
        if room.isActive {
            // The room keeps its level; only the doorstep seat comes up.
            peep.volumeScale = listening ? 1 : 0
        } else {
            IncomingAudio.shared.setListening(listening)
        }
    }

    func dismissPeephole(stopAudio: Bool = true) {
        audioArriveTask?.cancel()
        visitor = nil
        listening = false
        if stopAudio, !room.isActive { IncomingAudio.shared.depart() }
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
            // Already in a room: they show in the peephole, silent until I choose to
            // listen, and the room's own voices keep their level.
            peep.volumeScale = room.isActive ? 0 : 1
            audioArriveTask = Task {
                // Peek: a hidden seat, no mic, no camera. They cannot tell anyone is there.
                if let grant = try? await backend.answer(hidden: true) {
                    try? await peep.connect(grant, microphone: false, camera: false)
                }
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, !room.isActive else { return }
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
                if room.isActive {
                    room.include(who)   // they walked into a room that was already going
                } else if let grant = try? await backend.answer(hidden: false) {
                    roomName = grant.room
                    try? await media.connect(grant, microphone: true, camera: true)
                }
                IncomingAudio.shared.arrive(muffled: false)
                openRoom(host: me.handle, me: me, others: [who])
            }
        case .visitorLeft(let who):
            if visitor == who { dismissPeephole() }
        case .admitted(let who, let grant):
            admitted(by: who, grant: grant)
        }
    }

    private func openRoom(host: String, me: Profile, others: [Profile]) {
        if room.isActive {
            return   // already in: they'll appear as a tile
        }
        room.start(host: host, me: me, others: others)
        roomWindow.present()
    }

    private func roomClosed() {
        IncomingAudio.shared.depart()
        roomName = nil
        if let door = visiting {
            visiting = nil
            Task { await backend.leaveVisit(door.id) }
        }
    }

    // Development: the mock's door bell.
    func simulate(_ event: DoorEvent) {
        Task { await backend.simulate(event) }
    }
}
