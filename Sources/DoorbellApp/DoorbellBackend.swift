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
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String) async throws
    func claimHandle(_ handle: String, displayName: String) async throws
    func signOut() async

    // Graph
    func hallway() async throws -> HallwaySnapshot
    func search(_ query: String) async throws -> [Profile]
    func request(_ id: Profile.ID) async throws
    func accept(_ id: Profile.ID) async throws
    func ignore(_ id: Profile.ID) async throws
    func unfollow(_ id: Profile.ID) async throws
    func setCloseFriend(_ id: Profile.ID, _ on: Bool) async throws

    // Doors
    /// Go to someone's door. The backend decides whether that's a knock or a walk-in,
    /// tells them, and hands back a seat in their room.
    func visit(_ id: Profile.ID) async throws -> Visit
    /// Step away from their door.
    func leaveVisit(_ id: Profile.ID) async
    /// A seat in my own room. `hidden` is the peephole: I see them, they don't see me.
    func answer(hidden: Bool) async throws -> MediaGrant?
    /// The door I knocked on opened. Trade the knocker's seat for a full one.
    func knockAnswered(_ id: Profile.ID) async throws -> MediaGrant?

    /// Development only: pretend something happened at my door.
    func simulate(_ event: DoorEvent) async
}

extension DoorbellBackend {
    func accountState() async -> AccountState { .ready }
    func signIn(email: String, password: String) async throws {}
    func signUp(email: String, password: String) async throws {}
    func claimHandle(_ handle: String, displayName: String) async throws {}
    func signOut() async {}
    func answer(hidden: Bool) async throws -> MediaGrant? { nil }
    func knockAnswered(_ id: Profile.ID) async throws -> MediaGrant? { nil }
    func simulate(_ event: DoorEvent) async {}
}
