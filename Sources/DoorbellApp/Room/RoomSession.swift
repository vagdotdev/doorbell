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
    /// Friends' custom sticker pictures, by hash. Gone when the room is.
    @Published private(set) var stickerArt: [String: Data] = [:]

    private(set) var me: Profile?
    let media: MediaSession
    private let isLive: Bool
    private let onIncomingMessage: () -> Void
    private let myArt: (String) -> Data?
    /// Synchronously invalidates pending work when the window closes.
    var onLeave: (() -> Void)?

    private var sessionID = UUID()
    private var others: [Profile] = []
    private var mediaSink: AnyCancellable?
    private var artOrder: [String] = []
    /// Who here already holds each custom picture, so repeat sends carry only its name.
    private var artHolders: [String: Set<String>] = [:]
    private var artUploads: [String: Task<Void, Error>] = [:]

    init(media: MediaSession, isLive: Bool = AppConfig.current.isLive,
         onIncomingMessage: @escaping () -> Void = { Sounds.chatMessage() },
         myArt: @escaping (String) -> Data? = { StickerLibrary.shared.data(for: $0) }) {
        self.isLive = isLive
        self.media = media
        self.onIncomingMessage = onIncomingMessage
        self.myArt = myArt
        mediaSink = media.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send(); self?.rebuild() } }
        media.onData = { [weak self] data, topic, from in self?.receive(data, topic: topic, from: from) }
        media.onBytes = { [weak self] data, topic, attributes, from in
            self?.receiveArt(data, topic: topic, attributes: attributes, from: from)
        }
        media.acceptBytes(topic: Sticker.artTopic, limit: Sticker.maxArtBytes)
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
        stickerArt = [:]
        artOrder = []
        artHolders = [:]
        artUploads.values.forEach { $0.cancel() }
        artUploads = [:]
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
            append(ChatMessage(from: me, text: trimmed))
            problem = nil
            return true
        } catch {
            problem = "Message wasn’t sent. Your text is still here."
            return false
        }
    }

    func send(_ sticker: Sticker) async -> Bool {
        guard let me else { return false }
        let ticket = sessionID
        do {
            if isLive {
                if case .custom(let hash) = sticker { try await shareArt(hash) }
                guard ticket == sessionID else { return false }
                try await media.send(sticker.wire, topic: Sticker.topic)
            }
            guard isActive, ticket == sessionID else { return false }
            append(ChatMessage(from: me, text: sticker.alt, sticker: sticker))
            problem = nil
            return true
        } catch {
            if ticket == sessionID { problem = "Sticker wasn’t sent. Try again." }
            return false
        }
    }

    /// A custom sticker's picture: mine, or one a friend sent here.
    func art(_ hash: String) -> Data? { myArt(hash) ?? stickerArt[hash] }

    /// The picture goes only to people here who don't hold it yet. A burst of the same
    /// sticker shares one upload.
    private func shareArt(_ hash: String) async throws {
        if let upload = artUploads[hash] { try await upload.value }
        let missing = media.peers.map(\.id).filter { !(artHolders[hash]?.contains($0) ?? false) }
        guard !missing.isEmpty else { return }
        guard let art = art(hash) else { throw MediaSession.MediaFailure.unavailable }
        let ticket = sessionID
        let upload = Task { [media] in
            try await media.sendBytes(art, topic: Sticker.artTopic, attributes: ["hash": hash], to: missing)
            if ticket == sessionID { artHolders[hash, default: []].formUnion(missing) }
        }
        artUploads[hash] = upload
        defer { if artUploads[hash] == upload { artUploads[hash] = nil } }
        try await upload.value
    }

    private func receive(_ data: Data, topic: String, from: String?) {
        guard isActive, data.count <= 4_000,
              let from, !from.isEmpty, from != me?.handle, from != me?.id else { return }
        let sender = participants.first { $0.id == from }?.profile
            ?? Profile(id: from, handle: from, displayName: from, avatarURL: nil)
        switch topic {
        case "chat":
            guard let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            append(ChatMessage(from: sender, text: text))
        case Sticker.topic:
            guard let sticker = Sticker(wire: data) else { return }
            append(ChatMessage(from: sender, text: sticker.alt, sticker: sticker))
        default:
            return
        }
        if !chatOpen { unread += 1 }
        onIncomingMessage()
    }

    /// Kept only when the bytes really are the picture they claim to be.
    private func receiveArt(_ data: Data, topic: String, attributes: [String: String], from: String?) {
        guard isActive, topic == Sticker.artTopic, let from, !from.isEmpty, from != me?.handle,
              let hash = attributes["hash"], Sticker.isHash(hash), stickerArt[hash] == nil,
              data.count <= Sticker.maxArtBytes, StickerImport.hash(data) == hash,
              StickerImport.isImage(data) else { return }
        stickerArt[hash] = data
        artOrder.append(hash)
        while artOrder.count > 1, stickerArt.values.reduce(0, { $0 + $1.count }) > 40 * 1024 * 1024 {
            stickerArt[artOrder.removeFirst()] = nil
        }
    }

    private func append(_ message: ChatMessage) {
        chat.append(message)
        if chat.count > 200 { chat.removeFirst(chat.count - 200) }
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
        // Someone who left and came back starts with an empty room: resend their pictures.
        let present = Set(media.peers.map(\.id))
        if artHolders.values.contains(where: { !$0.isSubset(of: present) }) {
            artHolders = artHolders.mapValues { $0.intersection(present) }
        }
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
