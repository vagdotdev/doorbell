import Foundation
import LiveKit

struct Profile: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var handle: String
    var displayName: String
    var avatarURL: URL?
}

enum FollowStatus: String, Codable, Sendable {
    case pending, accepted
}

/// Someone you follow: a door you can knock on.
struct Door: Identifiable, Hashable, Sendable {
    var id: String { profile.id }
    let profile: Profile
    /// They follow you back, so they can knock on your door — and can be made a close friend.
    var followsMe: Bool
    /// On your close-friends list: they walk straight into your room.
    var isCloseFriend: Bool
}

struct HallwaySnapshot: Sendable {
    var me: Profile
    var doors: [Door]
    /// People asking to follow you.
    var requests: [Profile]
    /// Profile ids you've requested and are waiting on.
    var outgoing: Set<String>
}

/// What happened at my door.
enum DoorEvent: Sendable, Equatable {
    case knock(Profile)
    case walkIn(Profile)
    case visitorLeft(Profile)
    /// The door I knocked on opened: who let me in, and my seat in their room.
    case admitted(Profile, MediaGrant)
}

/// What the token function decided when I clicked a door.
enum VisitMode: Sendable {
    case knock, walkIn
}

/// A seat in a LiveKit room: where, and the signed permission to sit there.
struct MediaGrant: Sendable, Equatable {
    let url: String
    let token: String
    /// The LiveKit room. `door:<handle>` is that person's room; `doorstep:<handle>`
    /// is the step outside it, where a knocker waits and the owner peeks.
    let room: String
}

/// The verdict when I click a door. The mock has no media, so `grant` is nil there.
struct Visit: Sendable {
    let mode: VisitMode
    let grant: MediaGrant?
}

/// Where the account stands. The mock is always `ready`.
enum AccountState: Sendable, Equatable {
    case signedOut
    /// Signed in, but no profile row yet: pick a handle.
    case needsHandle
    case ready
}

// MARK: - Room

struct RoomParticipant: Identifiable, Equatable {
    let id: String
    let profile: Profile
    let isLocal: Bool
    /// Whose door this room is behind.
    var isHost = false
    var micOn = true
    var camOn = true
    var isSpeaking = false
    /// "friend of Vagdev" — set when two visitors don't know each other.
    var via: String?
    /// Live picture, when there is one. Compared by identity.
    var video: VideoTrack?

    static func == (a: RoomParticipant, b: RoomParticipant) -> Bool {
        a.id == b.id && a.profile == b.profile && a.isLocal == b.isLocal && a.isHost == b.isHost
            && a.micOn == b.micOn && a.camOn == b.camOn && a.isSpeaking == b.isSpeaking
            && a.via == b.via && a.video === b.video
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let from: Profile
    let text: String
    let at = Date()
}
