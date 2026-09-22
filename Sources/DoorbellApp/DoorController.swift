import Combine
import SwiftUI
import AVFoundation

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
    @Published private(set) var visitMode: VisitMode = .knock
    @Published private(set) var isAdmitting = false
    @Published var problem: String?
    @Published private(set) var automaticQuiet = false
    @Published private(set) var focusAccessNeeded = false
    @Published private(set) var focusAccessProblem: String?
    @Published private(set) var microphoneAccessNeeded = false
    @Published private(set) var isUpdatingOpenDoorPolicy = false
    @Published private(set) var openDoorPolicyProblem: String?
    @Published var openDoorPolicy = false {
        didSet { if !syncingPolicy, oldValue != openDoorPolicy { saveOpenDoorPolicy() } }
    }
    var effectiveDoorQuiet: Bool { quiet || automaticQuiet }
    @Published private(set) var quietUntil: Date?
    @Published var quiet: Bool {
        didSet {
            guard oldValue != quiet else { return }
            quietUntil = quietPeriod.set(quiet, at: now())
            applyAvailability()
        }
    }
    private let quietPeriod: QuietPeriod
    private let now: () -> Date
    var quietLabel: String {
        if let quietUntil, quiet { return "Quiet until \(quietUntil.formatted(date: .omitted, time: .shortened))" }
        return "Quiet for 6 hours"
    }
    let media: MediaSession
    let peep: MediaSession
    let room: RoomSession
    private let backend: any DoorbellBackend
    private let state: NotchState
    private let hallway: HallwayStore
    private let showsWindows: Bool
    private let timeout: Duration
    var roomName: String?
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
    private var profileSink: AnyCancellable?
    private var policyTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var departureTask: Task<Void, Never>?
    private var previewMicTask: Task<Void, Never>?
    private let availabilityProbe: (@MainActor () -> Quiet.Status)?
    private let microphoneAuthorized: @MainActor () -> Bool
    private let playKnock: @MainActor () -> Bool
    private var syncingPolicy = false
    private var shuttingDown = false
    private var isLeaving = false
    private var pendingPreviewDepartures = 0

    var blocksAutomaticUpdate: Bool {
        room.isActive || visiting != nil || isAdmitting || visitor != nil || isLeaving || shuttingDown
            || hallway.isSigningOut || isUpdatingOpenDoorPolicy
            || media.phase != .idle || peep.phase != .idle || pendingPreviewDepartures > 0
    }

    init(backend: any DoorbellBackend, state: NotchState, hallway: HallwayStore,
         media: MediaSession = MediaSession(), peep: MediaSession = MediaSession(),
         showsWindows: Bool = true, timeout: Duration = .seconds(30),
         availabilityProbe: (@MainActor () -> Quiet.Status)? = nil,
         microphoneAuthorized: @escaping @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         monitorAvailability: Bool = true,
         quietDefaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         playKnock: @escaping @MainActor () -> Bool = { Sounds.knock() }) {
        self.backend = backend; self.state = state; self.hallway = hallway
        self.media = media; self.peep = peep; self.showsWindows = showsWindows; self.timeout = timeout
        self.availabilityProbe = availabilityProbe
        self.microphoneAuthorized = microphoneAuthorized
        self.playKnock = playKnock
        self.now = now
        quietPeriod = QuietPeriod(defaults: quietDefaults)
        let restoredQuietUntil = quietPeriod.restore(at: now())
        quietUntil = restoredQuietUntil
        quiet = restoredQuietUntil != nil
        room = RoomSession(media: media)
        room.onLeave = { [weak self] in self?.requestLeaveRoom() }
        hallway.beforeSignOut = { [weak self] in await self?.shutdown() }
        accountSink = hallway.$account.dropFirst().removeDuplicates().sink { [weak self] account in
            if account == .signedOut { Task { await self?.shutdown() } }
        }
        profileSink = hallway.$me.sink { [weak self] profile in
            guard let self, !self.isUpdatingOpenDoorPolicy else { return }
            self.syncingPolicy = true
            self.openDoorPolicy = profile?.openDoorPolicy ?? false
            self.syncingPolicy = false
        }
        refreshAvailability()
        if monitorAvailability {
            availabilityTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.refreshAvailability()
                }
            }
        }
        eventTask = Task { [weak self] in
            for await event in backend.events { self?.handle(event) }
        }
    }

    deinit { availabilityTask?.cancel(); eventTask?.cancel() }

    func refreshAvailability() {
        let status = availabilityProbe?() ?? Quiet.status(ignoringOwnCamera: media.camOn || peep.camOn)
        let previous = automaticQuiet
        let previousMicAccess = microphoneAccessNeeded
        automaticQuiet = status.suppressesAmbient
        focusAccessNeeded = status == .focusAccessRequired || status == .focusStatusUnavailable
        if !focusAccessNeeded { focusAccessProblem = nil }
        microphoneAccessNeeded = !microphoneAuthorized()
        if quiet, let quietUntil, quietUntil <= now() {
            quiet = false
        } else if previous != automaticQuiet || previousMicAccess != microphoneAccessNeeded {
            applyAvailability()
        }
    }

    func requestFocusAccess() {
        Task { [weak self] in
            let allowed = await Quiet.requestFocusAccess()
            guard let self else { return }
            self.focusAccessProblem = allowed ? nil : "Allow Focus sharing for Doorbell in System Settings to enable automatic door audio and walk-ins."
            self.refreshAvailability()
        }
    }

    func requestMicrophoneAccess() {
        Task { [weak self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            self.microphoneAccessNeeded = !allowed
            if !allowed { self.problem = "Allow Doorbell in System Settings → Privacy & Security → Microphone." }
            self.refreshDoorAudio()
        }
    }

    private func saveOpenDoorPolicy() {
        guard let owner = hallway.me, !isUpdatingOpenDoorPolicy else { return }
        let enabled = openDoorPolicy
        isUpdatingOpenDoorPolicy = true; openDoorPolicyProblem = nil
        if enabled, focusAccessNeeded { requestFocusAccess() }
        policyTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.setOpenDoorPolicy(enabled)
                try Task.checkCancellation()
                await hallway.refresh()
            } catch {
                guard !Task.isCancelled, hallway.me?.id == owner.id else { return }
                syncingPolicy = true; openDoorPolicy = hallway.me?.openDoorPolicy ?? false; syncingPolicy = false
                openDoorPolicyProblem = "Couldn’t save Open Door Policy. Try again."
            }
            guard !Task.isCancelled, hallway.me?.id == owner.id else { return }
            isUpdatingOpenDoorPolicy = false
        }
    }

    private var mayShareDoorstepMicrophone: Bool {
        !effectiveDoorQuiet && !room.isActive && visiting == nil && !isAdmitting && !shuttingDown && microphoneAuthorized()
    }

    private func applyAvailability() {
        if effectiveDoorQuiet {
            listening = false
            if automaticAdmission { admissionTask?.cancel() }
            // Invalidate a preview that could enable capture after its connection returns.
            arrivalTask?.cancel()
        }
        refreshDoorAudio()
        if !effectiveDoorQuiet, visitor != nil, !isAdmitting {
            if !automaticallyAdmitCurrentArrival(), !peep.isConnected { showCurrentArrival() }
        }
    }

    private func refreshDoorAudio() {
        let level: Double = listening ? 1 : (effectiveDoorQuiet || room.isActive ? 0 : Double(DesignTokens.doorVolume))
        peep.fadePlayback(to: level, duration: level == 0 ? 0 : DesignTokens.audioListen)
        previewMicTask?.cancel()
        let share = mayShareDoorstepMicrophone && visitor != nil
        previewMicTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if !share, peep.phase == .reconnecting {
                await peep.disconnect()
                return
            }
            guard peep.isConnected else { return }
            await peep.setMicrophone(share)
            if share, !mayShareDoorstepMicrophone { await peep.setMicrophone(false) }
            if !mayShareDoorstepMicrophone, peep.micOn { await peep.disconnect() }
        }
    }

    var doorstepAudioStatus: String {
        if listening { return peep.micOn ? "Full volume · They hear you quietly" : "Full volume · Your mic is off" }
        if effectiveDoorQuiet { return "Door audio is paused · Accept still works" }
        if room.isActive || visiting != nil { return "Quiet preview · Your call stays private" }
        if microphoneAccessNeeded { return "You can listen · Allow your mic in Settings to talk" }
        if !peep.micOn { return "Quiet preview · Your mic is off" }
        return "Quiet voices · Your mic is shared"
    }

    func visit(_ door: Door) {
        guard !shuttingDown, !isLeaving, !isAdmitting, !hallway.isSigningOut, hallway.me != nil else { return }
        guard !room.isActive else { problem = "Leave this room before visiting another door."; return }
        guard visiting == nil else { return }
        refreshAvailability()
        if focusAccessNeeded { requestFocusAccess() }
        hallway.noteVisit(to: door)
        let ticket = generation.advance()
        let id = UUID()
        outgoingID = id; visiting = door; visitMode = .knock; problem = nil
        refreshDoorAudio()
        let mutedPreview = previewMicTask
        state.mode = .visiting(door)
        visitTimeout = Task { [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(30))
            guard !Task.isCancelled else { return }
            self?.leaveVisit()
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await mutedPreview?.value
                try generation.check(ticket)
                let visit = try await backend.visit(door.id, visitID: id)
                try generation.check(ticket)
                self.visitMode = visit.mode
                if let grant = visit.grant {
                    try await media.connect(grant, microphone: true, camera: true)
                    try generation.check(ticket)
                    media.fadePlayback(to: Double(DesignTokens.doorVolume), duration: DesignTokens.audioArrive)
                    // Signal only after the guest really occupies the isolated doorstep.
                    try await backend.announceVisit(door.id, visitID: id)
                    try generation.check(ticket)
                } else if visit.mode == .walkIn { // Development hallway only.
                    finishVisit()
                    openRoom(host: door.profile.handle, others: [door.profile])
                }
            } catch {
                guard generation.isCurrent(ticket) else { return }
                problem = visitProblem(error: error, media: media)
                leaveVisit()
            }
        }
    }

    func leaveVisit() {
        guard let door = visiting, let id = outgoingID else { return }
        isLeaving = true
        let ticket = generation.advance(); operation?.cancel(); visitTimeout?.cancel()
        visiting = nil; outgoingID = nil
        state.mode = .building
        departureTask = Task {
            await media.disconnect()
            if generation.isCurrent(ticket) {
                isLeaving = false; refreshDoorAudio()
                FreshRing.shared.installIfReady()
            }
        }
        Task { [backend] in await backend.leaveVisit(door.id, visitID: id) }
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
                let host = grant.room.hasPrefix("door:") ? String(grant.room.dropFirst(5).split(separator: ":").first ?? "") : who.handle
                openRoom(host: host, others: [who])
            } catch {
                guard generation.isCurrent(ticket) else { return }
                problem = "Couldn’t enter the room. Try knocking again."
                leaveVisit()
            }
        }
    }

    enum BringIn {
        /// Admit the visitor into the hang already running.
        case add
        /// Leave this hang, then open your own room for the visitor.
        case end
    }

    func openDoor(automatically: Bool = false, bringIn: BringIn = .add) {
        guard let arrival = arrivals.first, hallway.me != nil, !isAdmitting, !shuttingDown, !hallway.isSigningOut else { return }
        refreshAvailability()
        guard !automatically || !effectiveDoorQuiet else { return }
        if bringIn == .add, room.isFull {
            problem = "This call is full."
            return
        }
        Sounds.stopKnock()
        arrivalTask?.cancel()
        previewMicTask?.cancel()
        let outgoingDoor = visiting
        let outgoingVisit = outgoingID
        let endCall = !automatically && bringIn == .end && room.isActive
        let priorDeparture = departureTask
        let ticket = generation.advance()
        operation?.cancel(); visitTimeout?.cancel()
        finishVisit()
        isLeaving = false
        problem = nil
        isAdmitting = true
        automaticAdmission = automatically
        if let outgoingDoor, let outgoingVisit {
            Task { [backend] in await backend.leaveVisit(outgoingDoor.id, visitID: outgoingVisit) }
        }
        admissionTask = Task { [weak self] in
            guard let self else { return }
            var openedSeat = false
            var succeeded = false
            defer {
                if generation.isCurrent(ticket) {
                    isAdmitting = false; automaticAdmission = false
                    refreshDoorAudio()
                    if succeeded || arrivals.first?.id != arrival.id { _ = automaticallyAdmitCurrentArrival() }
                }
            }
            do {
                // A previous Leave may still own media teardown. Let it finish
                // before the accepting call acquires this same seat.
                await priorDeparture?.value
                try generation.check(ticket)
                await peep.disconnect()
                try generation.check(ticket)
                guard arrivals.first?.id == arrival.id else { throw CancellationError() }
                if endCall {
                    vacateRoom()
                    await media.disconnect()
                    try generation.check(ticket)
                    guard arrivals.first?.id == arrival.id else { throw CancellationError() }
                } else if outgoingVisit != nil {
                    await media.disconnect()
                    try generation.check(ticket)
                    guard arrivals.first?.id == arrival.id else { throw CancellationError() }
                }
                if !room.isActive {
                    if let grant = try await backend.answer(hidden: false, visitID: nil) {
                        try generation.check(ticket)
                        guard arrivals.first?.id == arrival.id,
                              !automatically || !effectiveDoorQuiet else { throw CancellationError() }
                        try await media.connect(grant,
                            microphone: !automatically || microphoneAuthorized(),
                            camera: !automatically || AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
                        openedSeat = true
                        try generation.check(ticket)
                        roomName = grant.room
                    }
                }
                guard arrivals.first?.id == arrival.id else { throw CancellationError() }
                if automatically, effectiveDoorQuiet { throw CancellationError() }
                try await backend.admit(arrival.profile.id, visitID: arrival.id, into: roomName, automatically: automatically)
                try generation.check(ticket)
                if !room.isActive {
                    openRoom(host: hallway.me?.handle ?? "", others: [arrival.profile])
                } else {
                    room.include(arrival.profile)
                }
                succeeded = true
                removeArrival(arrival.id, admitted: true)
            } catch {
                if openedSeat, !room.isActive, generation.isCurrent(ticket) { await media.disconnect(); roomName = nil }
                guard generation.isCurrent(ticket), !shuttingDown, !Task.isCancelled else { return }
                problem = "Couldn’t let them in. They may have left. Try again."
                if arrivals.first?.id == arrival.id { showCurrentArrival() }
            }
        }
    }

    /// Drop the current hang locally without Leave-for-everyone. Other people stay.
    private func vacateRoom() {
        if showsWindows { roomWindow.hide() }
        room.reset()
        roomName = nil
    }

    func toggleListening() {
        listening.toggle()
        if listening { Sounds.stopKnock() }
        refreshDoorAudio()
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
        if walkedIn, !room.isActive { openDoor() }
        else { showCurrentArrival() }
    }
    private func removeArrival(_ id: UUID, admitted: Bool = false) {
        let wasFirst = arrivals.first?.id == id
        if let profile = arrivals.first(where: { $0.id == id })?.profile {
            hallway.clearWaiting(profile.id)
        }
        arrivalTimeouts.removeValue(forKey: id)?.cancel()
        arrivals.removeAll { $0.id == id }
        if wasFirst {
            if isAdmitting, !admitted { admissionTask?.cancel() }
            arrivalTask?.cancel()
            listening = false
            if arrivals.isEmpty {
                previewMicTask?.cancel()
                pendingPreviewDepartures += 1
                Task {
                    await peep.disconnect()
                    pendingPreviewDepartures -= 1
                    FreshRing.shared.installIfReady()
                }
            }
            if !automaticallyAdmitCurrentArrival() { showCurrentArrival() }
        }
    }
    private func showCurrentArrival(handoff: Bool = false) {
        guard let arrival = arrivals.first else {
            if case .peephole = state.mode { state.mode = visiting.map(ShellMode.visiting) ?? .building }
            return
        }
        state.mode = .peephole(arrival.profile)
        refreshDoorAudio()
        guard !effectiveDoorQuiet || listening else { return }
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
                // Connect silently first: permission/availability can change
                // while the network is in flight. Only then consider capture.
                if let grant { try await peep.connect(grant, microphone: false, camera: false) }
                try Task.checkCancellation()
                guard arrivals.first?.id == arrival.id else { return }
                if handoff {
                    try? await Task.sleep(until: knockedAt + .seconds(Sounds.knockHandoff), clock: .continuous)
                    guard !Task.isCancelled, arrivals.first?.id == arrival.id else { return }
                }
                refreshDoorAudio()
            } catch {
                guard !Task.isCancelled, arrivals.first?.id == arrival.id else { return }
                problem = "Preview unavailable. You can still try letting them in."
            }
        }
    }
    /// Walk-ins wait whenever a hang is already live. Add / End is a person choosing.
    private func automaticallyAdmitCurrentArrival() -> Bool {
        guard let arrival = arrivals.first, arrival.walksIn, !isAdmitting,
              !effectiveDoorQuiet, visiting == nil, !isLeaving, !shuttingDown,
              !room.isActive else { return false }
        openDoor(automatically: true)
        return isAdmitting
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
        refreshAvailability()
        if automaticallyAdmitCurrentArrival() { return }
        let rang: Bool
        if !effectiveDoorQuiet {
            state.knockBounce()
            rang = playKnock()
        } else {
            rang = false
        }
        showCurrentArrival(handoff: rang)
    }
    private func handle(_ event: DoorEvent) {
        switch event {
        case .knock(let who, let id):
            hallway.noteKnock(from: who)
            enqueue(who, id: id, walkIn: false)
        case .walkIn(let who, let id):
            hallway.noteWalkIn(from: who)
            enqueue(who, id: id, walkIn: true)
        case .visitorLeft(let who, let id):
            if arrivals.contains(where: { $0.id == id && $0.profile.id == who.id }) { removeArrival(id) }
        case .admitted(let who, let grant, let id): admitted(by: who, grant: grant, visitID: id)
        }
    }
    private func openRoom(host: String, others: [Profile]) {
        guard let me = hallway.me, !shuttingDown else { return }
        media.fadePlayback(to: 1, duration: DesignTokens.audioEnter)
        if !room.isActive { room.start(host: host, me: me, others: others) }
        refreshDoorAudio()
        if showsWindows { roomWindow.present() }
    }
    func closeRoom() {
        if showsWindows { roomWindow.close() }
        else { room.leave() }
    }
    private func requestLeaveRoom() {
        guard !shuttingDown, !isLeaving else { return }
        isLeaving = true
        let ticket = generation.advance(); operation?.cancel(); admissionTask?.cancel()
        isAdmitting = false
        finishVisit(); room.reset(); roomName = nil
        departureTask = Task {
            await media.disconnect()
            if generation.isCurrent(ticket) {
                isLeaving = false; refreshDoorAudio()
                FreshRing.shared.installIfReady()
            }
        }
    }
    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        generation.advance()
        policyTask?.cancel(); previewMicTask?.cancel()
        isUpdatingOpenDoorPolicy = false
        operation?.cancel(); admissionTask?.cancel(); arrivalTask?.cancel(); visitTimeout?.cancel()
        for task in arrivalTimeouts.values { task.cancel() }
        arrivalTimeouts = [:]; arrivals = []; listening = false; isAdmitting = false
        let oldDoor = visiting; let oldID = outgoingID
        finishVisit(); room.reset(); roomName = nil
        if showsWindows { roomWindow.close() }
        await departureTask?.value
        await media.disconnect()
        await peep.disconnect()
        if let oldDoor, let oldID {
            // Remote cancellation may wait for connectivity. Local sign-out must
            // finish regardless; the server expires an unreachable visit.
            Task { [backend] in await backend.leaveVisit(oldDoor.id, visitID: oldID) }
        }
        state.mode = .building
        isLeaving = false
        shuttingDown = false
    }
    func simulate(_ event: DoorEvent) { Task { await backend.simulate(event) } }
}

@MainActor
private func visitProblem(error: Error, media: MediaSession) -> String {
    if let msg = media.problem, !msg.isEmpty { return msg }
    let msg = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if msg.contains("401") || msg.localizedCaseInsensitiveContains("invalid token") {
        return "Doorbell’s media server rejected the call. The LiveKit keys on Convex need updating."
    }
    if !msg.isEmpty, msg != "The operation couldn’t be completed." { return msg }
    return "Couldn’t reach that door. Check your connection and try again."
}
