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
    @Published var micOn = true {
        didSet { let on = micOn; setLocal { $0.micOn = on }; sync { await $0.setMicrophone(on) } }
    }
    @Published var camOn = true {
        didSet { let on = camOn; setLocal { $0.camOn = on }; sync { await $0.setCamera(on) } }
    }
    @Published var sharing = false {
        didSet { let on = sharing; sync { await $0.setScreenShare(on) } }
    }
    @Published var chatOpen = false
    @Published var peopleOpen = false
    @Published private(set) var chat: [ChatMessage] = []
    @Published private(set) var unread = 0

    private(set) var me: Profile?
    let media: MediaSession
    /// Called when the window closes, after media is down.
    var onLeave: (() -> Void)?

    private var others: [Profile] = []
    private var mediaSink: AnyCancellable?

    init(media: MediaSession) {
        self.media = media
        mediaSink = media.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.rebuild() } }
        media.onData = { [weak self] data, topic, from in
            guard topic == "chat", let self, let text = String(data: data, encoding: .utf8) else { return }
            let sender = self.participants.first { $0.id == from }?.profile
                ?? Profile(id: from ?? "?", handle: from ?? "?", displayName: from ?? "Someone", avatarURL: nil)
            self.chat.append(ChatMessage(from: sender, text: text))
            if !self.chatOpen { self.unread += 1 }
        }
    }

    func start(host: String, me: Profile, others: [Profile]) {
        self.host = host
        self.me = me
        self.others = others
        micOn = true
        camOn = true
        sharing = false
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
        isActive = false
        participants = []
        chatOpen = false
        Task {
            await media.disconnect()
            onLeave?()
        }
    }

    func send(_ text: String) {
        guard let me else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.append(ChatMessage(from: me, text: trimmed))
        Task { await media.send(Data(trimmed.utf8), topic: "chat") }
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
        } else {
            list += others.map { RoomParticipant(id: $0.id, profile: $0, isLocal: false, isHost: $0.handle == host) }
        }
        if list != participants { participants = list }
    }

    private func setLocal(_ change: (inout RoomParticipant) -> Void) {
        guard let i = participants.firstIndex(where: \.isLocal) else { return }
        change(&participants[i])
    }

    private func sync(_ op: @escaping (MediaSession) async -> Void) {
        guard media.isConnected else { return }
        Task { await op(media) }
    }
}
