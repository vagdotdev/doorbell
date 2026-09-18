import Combine
import SwiftUI

/// State of the room I'm in. With a live `MediaSession` the tiles are real people on
/// real tracks; without one (the mock) they are placeholders.
@MainActor
final class RoomSession: ObservableObject {
    /// Handle of whoever's door this room is behind. The room has no name of its own.
    @Published private(set) var host = ""
    @Published private(set) var isActive = false
    @Published private(set) var participants: [RoomParticipant] = []
    static let capacity = 5
    var isFull: Bool { isActive && participants.count >= Self.capacity }
    var micOn: Bool { media.micOn }
    var camOn: Bool { media.camOn }
    var sharing: Bool { media.sharing }
    @Published var sharePickerOpen = false
    @Published var devicesOpen = false
    @Published var problem: String?
    @Published var chatOpen = false
    @Published var peopleOpen = false
    @Published private(set) var chat: [ChatMessage] = []
    @Published private(set) var unread = 0

    private(set) var me: Profile?
    let media: MediaSession
    private let isLive: Bool
    /// Synchronously invalidates pending work when the window closes.
    var onLeave: (() -> Void)?

    private var sessionID = UUID()
    private var others: [Profile] = []
    private var mediaSink: AnyCancellable?

    init(media: MediaSession, isLive: Bool = AppConfig.current.isLive,
         onIncomingMessage: @escaping () -> Void = { Sounds.chatMessage() }) {
        self.isLive = isLive
        self.media = media
        mediaSink = media.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send(); self?.rebuild() } }
        media.onData = { [weak self] data, topic, from in
            guard topic == "chat", data.count <= 4_000,
                  let self, self.isActive,
                  let from, !from.isEmpty, from != self.me?.handle, from != self.me?.id,
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let sender = self.participants.first { $0.id == from }?.profile
                ?? Profile(id: from, handle: from, displayName: from, avatarURL: nil)
            self.chat.append(ChatMessage(from: sender, text: text))
            if self.chat.count > 200 { self.chat.removeFirst(self.chat.count - 200) }
            if !self.chatOpen { self.unread += 1 }
            onIncomingMessage()
        }
    }

    func start(host: String, me: Profile, others: [Profile]) {
        sessionID = UUID()
        self.host = host
        self.me = me
        self.others = others
        problem = nil
        chat = []
        unread = 0
        peopleOpen = false
        isActive = true
        rebuild()
    }

    /// Someone was let in while the room is running: know their face and name before
    /// their tracks arrive (and stand in for them entirely on the mock).
    func include(_ profile: Profile) {
        guard !others.contains(profile) else { return }
        others.append(profile)
        rebuild()
    }

    func leave() {
        reset()
        onLeave?()
    }

    func reset() {
        sessionID = UUID()
        isActive = false
        participants = []
        others = []
        chat = []
        unread = 0
        chatOpen = false
        peopleOpen = false
        sharePickerOpen = false
        devicesOpen = false
        me = nil
        host = ""
    }

    func send(_ text: String) async -> Bool {
        guard let me else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_000 else {
            problem = "Keep messages under 4 KB."
            return false
        }
        let ticket = sessionID
        do {
            if isLive { try await media.send(Data(trimmed.utf8), topic: "chat") }
            guard isActive, ticket == sessionID else { return false }
            chat.append(ChatMessage(from: me, text: trimmed))
            if chat.count > 200 { chat.removeFirst(chat.count - 200) }
            problem = nil
            return true
        } catch {
            problem = "Message wasn’t sent. Your text is still here."
            return false
        }
    }

    // One side panel at a time.
    func toggleChat() {
        chatOpen.toggle()
        if chatOpen { unread = 0; peopleOpen = false }
    }

    func togglePeople() {
        peopleOpen.toggle()
        if peopleOpen { chatOpen = false }
    }

    // MARK: -

    private func rebuild() {
        guard isActive, let me else { return }
        var list = [RoomParticipant(id: me.id, profile: me, isLocal: true, isHost: me.handle == host,
                                    micOn: micOn, camOn: camOn, video: media.localVideo)]
        if media.isConnected {
            list += media.peers.map { peer in
                let known = others.first { $0.handle == peer.id }
                return RoomParticipant(
                    id: peer.id,
                    profile: known ?? Profile(id: peer.id, handle: peer.id, displayName: peer.name, avatarURL: nil),
                    isLocal: false, isHost: peer.id == host,
                    micOn: peer.micOn, camOn: peer.camOn, isSpeaking: peer.isSpeaking,
                    // Caption strangers only: not the host, not someone I already know.
                    via: peer.via.flatMap { ($0 == me.handle || $0 == peer.id || known != nil) ? nil : $0 },
                    video: peer.video)
            }
        } else if !isLive {
            list += others.map { RoomParticipant(id: $0.id, profile: $0, isLocal: false, isHost: $0.handle == host) }
        }
        if list != participants { participants = list }
    }

}
