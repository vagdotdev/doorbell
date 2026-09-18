import Foundation

/// Everything social goes through here. `MockBackend` for development,
/// `SupabaseBackend` for the real thing.
protocol DoorbellBackend: Sendable {
    /// Fires whenever the graph or the account changes underneath us.
    var updates: AsyncStream<Void> { get }
    /// Knocks and walk-ins at my door.
    var events: AsyncStream<DoorEvent> { get }

    // Account
    func accountState() async -> AccountState
    /// Sign-in email when known (Convex Auth). Nil on the mock.
    func accountEmail() async -> String?
    /// Display-name changes left in the rolling 14-day window. Nil on backends without a limit.
    func accountNameQuota() async -> NameQuota?
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String) async throws
    func claimHandle(_ handle: String, displayName: String) async throws
    /// Change the name friends see.
    func updateProfile(displayName: String) async throws
    func setOpenDoorPolicy(_ enabled: Bool) async throws
    /// Upload a JPEG/PNG as the profile photo. Empty data is refused by the backend.
    func setAvatar(jpegOrPng: Data, contentType: String) async throws
    /// Drop the profile photo.
    func clearAvatar() async throws
    func signOut() async

    // Graph
    func hallway() async throws -> HallwaySnapshot
    func search(_ query: String) async throws -> [Profile]
    func request(_ id: Profile.ID) async throws
    func accept(_ id: Profile.ID) async throws
    func ignore(_ id: Profile.ID) async throws
    func removeFollower(_ id: Profile.ID) async throws
    func unfollow(_ id: Profile.ID) async throws
    func setCloseFriend(_ id: Profile.ID, _ on: Bool) async throws

    // Doors
    /// Go to someone's door. The backend decides whether that's a knock or a walk-in,
    /// tells them, and hands back a seat in their room.
    func visit(_ id: Profile.ID, visitID: UUID) async throws -> Visit
    func announceVisit(_ id: Profile.ID, visitID: UUID) async throws
    /// Step away from their door.
    func leaveVisit(_ id: Profile.ID, visitID: UUID) async
    /// `hidden`: a seat on my doorstep — I see and hear the knocker, they don't see me.
    /// Otherwise a seat in my own room, as its host.
    func answer(hidden: Bool, visitID: UUID?) async throws -> MediaGrant?
    /// Let a knocker in. `room` is where I am right now — my own room, or one I'm a
    /// guest in — and is where their seat will be. They hear about it on their door.
    func admit(_ id: Profile.ID, visitID: UUID, into room: String?) async throws
    func admit(_ id: Profile.ID, visitID: UUID, into room: String?, automatically: Bool) async throws

    /// Development only: pretend something happened at my door.
    func simulate(_ event: DoorEvent) async
}

extension DoorbellBackend {
    func removeFollower(_ id: Profile.ID) async throws { try await ignore(id) }
    func announceVisit(_ id: Profile.ID, visitID: UUID) async throws {}
    func accountState() async -> AccountState { .ready }
    func accountEmail() async -> String? { nil }
    func accountNameQuota() async -> NameQuota? { nil }
    func signIn(email: String, password: String) async throws {}
    func signUp(email: String, password: String) async throws {}
    func claimHandle(_ handle: String, displayName: String) async throws {}
    func updateProfile(displayName: String) async throws {}
    func setOpenDoorPolicy(_ enabled: Bool) async throws { throw DoorPolicyError.unsupported }
    func setAvatar(jpegOrPng: Data, contentType: String) async throws {}
    func clearAvatar() async throws {}
    func signOut() async {}
    func answer(hidden: Bool, visitID: UUID?) async throws -> MediaGrant? { nil }
    func admit(_ id: Profile.ID, visitID: UUID, into room: String?) async throws {}
    func admit(_ id: Profile.ID, visitID: UUID, into room: String?, automatically: Bool) async throws {
        try await admit(id, visitID: visitID, into: room)
    }
    func simulate(_ event: DoorEvent) async {}
}

enum DoorPolicyError: LocalizedError {
    case unsupported
    var errorDescription: String? { "Open Door Policy needs the current Doorbell backend." }
}
