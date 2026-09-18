import Foundation
import Testing
@testable import DoorbellApp

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DOORBELL_CONVEX_TEST_URL"] != nil))
@MainActor struct ConvexLiveIntegrationTests {
    @Test func twoRealClientsKnockAdmitChatAndLeave() async throws {
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["DOORBELL_CONVEX_TEST_URL"] ?? ""))
        try #require(url.host == "127.0.0.1")
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("doorbell-wire-\(suffix)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = ConvexBackend(url: url, directory: folder, profile: "audit-a-\(suffix)")
        let b = ConvexBackend(url: url, directory: folder, profile: "audit-b-\(suffix)")
        let ah = "alice_\(suffix)", bh = "bob_\(suffix)"
        try await a.signUp(email: "\(ah)@test.local", password: "unique-a-\(suffix)-password")
        try await b.signUp(email: "\(bh)@test.local", password: "unique-b-\(suffix)-password")
        try await a.claimHandle(ah, displayName: "Alice")
        try await b.claimHandle(bh, displayName: "Bob")
        let ap = try await a.hallway().me, bp = try await b.hallway().me
        _ = try await a.search(bh); _ = try await b.search(ah)
        try await a.request(bp.id)
        try await b.accept(ap.id)
        var atA: [DoorEvent] = [], atB: [DoorEvent] = []
        let watchA = Task { for await e in a.events { atA.append(e) } }
        let watchB = Task { for await e in b.events { atB.append(e) } }
        defer { watchA.cancel(); watchB.cancel() }
        let guest = MediaSession(), owner = MediaSession(), peek = MediaSession()
        let visitID = UUID()
        do {
            let visit = try await a.visit(bp.id, visitID: visitID)
            let grant = try #require(visit.grant)
            try await guest.connect(grant, microphone: false, camera: false)
            try await a.announceVisit(bp.id, visitID: visitID)
            for _ in 0..<100 { if !atB.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
            guard case .knock(let from, let receivedID) = try #require(atB.first) else { Issue.record("No knock"); throw BackendError.noProfile }
            #expect(from.id == ap.id && receivedID == visitID)
            let preview = try #require(try await b.answer(hidden: true, visitID: visitID))
            try await peek.connect(preview, microphone: false, camera: false)
            #expect(preview.room == grant.room)
            #expect(!peek.micOn && !peek.camOn)
            await peek.disconnect()
            let hostGrant = try #require(try await b.answer(hidden: false, visitID: nil))
            try await owner.connect(hostGrant, microphone: false, camera: false)
            try await b.admit(ap.id, visitID: visitID, into: hostGrant.room)
            for _ in 0..<100 { if !atA.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
            guard case .admitted(let host, let seat, let admissionID) = try #require(atA.first) else { Issue.record("No admission"); throw BackendError.noProfile }
            #expect(host.id == bp.id && admissionID == visitID && seat.room == hostGrant.room)
            await guest.disconnect()
            try await guest.connect(seat, microphone: false, camera: false)
            var message: String?
            owner.onData = { data, topic, _ in if topic == "chat" { message = String(data: data, encoding: .utf8) } }
            let room = RoomSession(media: guest, isLive: true)
            room.start(host: bh, me: ap, others: [bp])
            #expect(await room.send("real Convex → LiveKit chat"))
            for _ in 0..<100 { if message != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
            #expect(message == "real Convex → LiveKit chat")
            room.reset()
            await guest.disconnect()
            let canceledID = UUID()
            let secondVisit = try await a.visit(bp.id, visitID: canceledID)
            try await guest.connect(try #require(secondVisit.grant), microphone: false, camera: false)
            try await a.announceVisit(bp.id, visitID: canceledID)
            await a.leaveVisit(bp.id, visitID: canceledID)
            func receivedLeft() -> Bool {
                atB.contains { event in
                    if case .visitorLeft(let who, let id) = event { return who.id == ap.id && id == canceledID }
                    return false
                }
            }
            for _ in 0..<100 { if receivedLeft() { break }; try await Task.sleep(for: .milliseconds(30)) }
            #expect(receivedLeft())
        } catch {
            await guest.disconnect(); await owner.disconnect(); await peek.disconnect()
            await a.signOut(); await b.signOut()
            throw error
        }
        await guest.disconnect(); await owner.disconnect(); await peek.disconnect()
        await a.signOut(); await b.signOut()
        let aState = await a.accountState(), bState = await b.accountState()
        #expect(aState == .signedOut && bState == .signedOut)
    }

    @Test func openDoorAdmitsFriendsRejectsStrangersAndClosingRestoresKnocks() async throws {
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["DOORBELL_CONVEX_TEST_URL"] ?? ""))
        try #require(url.host == "127.0.0.1")
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("doorbell-open-\(suffix)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = ConvexBackend(url: url, directory: folder, profile: "open-guest-\(suffix)")
        let host = ConvexBackend(url: url, directory: folder, profile: "open-host-\(suffix)")
        let gh = "guest_\(suffix)", hh = "host_\(suffix)"
        let outside = MediaSession(), inside = MediaSession()
        var arrivals: [DoorEvent] = [], admissions: [DoorEvent] = []
        let watchHost = Task { for await event in host.events { arrivals.append(event) } }
        let watchGuest = Task { for await event in guest.events { admissions.append(event) } }
        defer { watchHost.cancel(); watchGuest.cancel() }
        do {
            try await guest.signUp(email: "\(gh)@test.local", password: "guest-\(suffix)-password")
            try await host.signUp(email: "\(hh)@test.local", password: "host-\(suffix)-password")
            try await guest.claimHandle(gh, displayName: "Guest")
            try await host.claimHandle(hh, displayName: "Host")
            let gp = try await guest.hallway().me, hp = try await host.hallway().me
            #expect(!hp.openDoorPolicy)
            try await host.setOpenDoorPolicy(true)
            let search = try await guest.search(hh)
            #expect(search.first?.openDoorPolicy == true)
            #expect(try await guest.hallway().doors.isEmpty)
            do {
                _ = try await guest.visit(hp.id, visitID: UUID())
                Issue.record("Open Door granted a stranger entry")
            } catch {}
            try await guest.request(hp.id)
            do {
                _ = try await guest.visit(hp.id, visitID: UUID())
                Issue.record("Open Door granted a pending request entry")
            } catch {}
            _ = try await host.search(gh)
            try await host.accept(gp.id)
            let visitID = UUID(), visit = try await guest.visit(hp.id, visitID: visitID)
            #expect(visit.mode == .walkIn)
            try await outside.connect(try #require(visit.grant), microphone: false, camera: false)
            try await guest.announceVisit(hp.id, visitID: visitID)
            for _ in 0..<100 { if !arrivals.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
            guard case .walkIn(let who, let receivedID) = try #require(arrivals.first) else {
                Issue.record("Open door did not receive friend walk-in"); throw BackendError.noProfile
            }
            #expect(who.id == gp.id && receivedID == visitID)
            let grant = try #require(try await host.answer(hidden: false, visitID: nil))
            try await inside.connect(grant, microphone: false, camera: false)
            try await host.admit(gp.id, visitID: visitID, into: grant.room, automatically: true)
            for _ in 0..<100 { if !admissions.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
            guard case .admitted(let owner, let admitted, let admissionID) = try #require(admissions.first) else {
                Issue.record("Friend received no admission"); throw BackendError.noProfile
            }
            #expect(owner.id == hp.id && admissionID == visitID && admitted.room == grant.room)
            await outside.disconnect()
            try await outside.connect(admitted, microphone: false, camera: false)
            try await host.setOpenDoorPolicy(false)
            let knockID = UUID()
            let knock = try await guest.visit(hp.id, visitID: knockID)
            #expect(knock.mode == .knock)
            await guest.leaveVisit(hp.id, visitID: knockID)
            try await host.unfollow(gp.id)
            try await host.setOpenDoorPolicy(true)
            do {
                _ = try await guest.visit(hp.id, visitID: UUID())
                Issue.record("Open Door granted a removed friend entry")
            } catch {}
        } catch {
            await outside.disconnect(); await inside.disconnect()
            await guest.signOut(); await host.signOut()
            throw error
        }
        await outside.disconnect(); await inside.disconnect()
        await guest.signOut(); await host.signOut()
    }

    @Test func coldClientAfterUpdateRestoresSameAccountAndFriendGraph() async throws {
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["DOORBELL_CONVEX_TEST_URL"] ?? ""))
        try #require(url.host == "127.0.0.1")
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("doorbell-upgrade-\(suffix)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = "upgrade-owner-\(suffix)"
        let original = ConvexBackend(url: url, directory: folder, profile: profile)
        let friend = ConvexBackend(url: url, directory: folder, profile: "upgrade-friend-\(suffix)")
        var restored: ConvexBackend?
        let oh = "owner_\(suffix)", fh = "friend_\(suffix)"
        do {
            try await original.signUp(email: "\(oh)@test.local", password: "owner-\(suffix)-password")
            try await friend.signUp(email: "\(fh)@test.local", password: "friend-\(suffix)-password")
            try await original.claimHandle(oh, displayName: "Original account")
            try await friend.claimHandle(fh, displayName: "Existing friend")
            let before = try await original.hallway().me, fp = try await friend.hallway().me
            _ = try await original.search(fh)
            _ = try await friend.search(oh)
            try await original.request(fp.id)
            try await friend.accept(before.id)
            try await original.setCloseFriend(fp.id, true)
            try await original.setOpenDoorPolicy(true)
            // Replace the client/auth objects as an app restart does. No password,
            // new-account call, or in-memory snapshot is supplied to the new client.
            AppConfig.prepareLegacySession(for: url, directory: folder)
            let next = ConvexBackend(url: url, directory: folder, profile: profile)
            restored = next
            #expect(await next.accountState() == .ready)
            var after = try await next.hallway()
            for _ in 0..<100 {
                if after.doors.contains(where: { $0.profile.id == fp.id && $0.isCloseFriend }) { break }
                try await Task.sleep(for: .milliseconds(30))
                after = try await next.hallway()
            }
            #expect(after.me.id == before.id && after.me.handle == oh)
            #expect(after.me.displayName == "Original account" && after.me.openDoorPolicy)
            #expect(after.doors.count == 1)
            #expect(after.doors.first?.profile.id == fp.id)
            #expect(after.doors.first?.isCloseFriend == true && after.doors.first?.followsMe == true)
        } catch {
            await restored?.signOut(); await original.signOut(); await friend.signOut()
            throw error
        }
        await restored?.signOut(); await original.signOut(); await friend.signOut()
    }

    private struct RestartFixture: Codable {
        let profile: String
        let ownerHandle: String
        var ownerID: String
        var friendID: String
        let seedProcessID: Int32
    }

    /// Harness runs this in two separate OS test processes. This proves durable
    /// session/graph restoration, not Keychain ACL behavior across signing changes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOORBELL_UPGRADE_TEST_PHASE"] != nil))
    func separateProcessUpdatePreservesLoginAndFriends() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(URL(string: environment["DOORBELL_CONVEX_TEST_URL"] ?? ""))
        try #require(url.host == "127.0.0.1")
        let fixtureURL = URL(fileURLWithPath: try #require(environment["DOORBELL_UPGRADE_TEST_FIXTURE"]))
        let folder = fixtureURL.deletingLastPathComponent().appendingPathComponent("restart-session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if environment["DOORBELL_UPGRADE_TEST_PHASE"] == "seed" {
            let suffix = UUID().uuidString.prefix(8).lowercased()
            var fixture = RestartFixture(profile: "restart-owner-\(suffix)", ownerHandle: "owner_\(suffix)",
                ownerID: "", friendID: "", seedProcessID: ProcessInfo.processInfo.processIdentifier)
            // Write only nonsecret fixture metadata; the harness can clean the
            // exact disposable Keychain service even if seeding fails midway.
            try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            let owner = ConvexBackend(url: url, directory: folder, profile: fixture.profile)
            let friend = ConvexBackend(url: url, directory: folder, profile: "\(fixture.profile)-friend")
            let fh = "friend_\(suffix)"
            do {
                try await owner.signUp(email: "\(fixture.ownerHandle)@test.local", password: UUID().uuidString)
                try await friend.signUp(email: "\(fh)@test.local", password: UUID().uuidString)
                try await owner.claimHandle(fixture.ownerHandle, displayName: "Account before update")
                try await friend.claimHandle(fh, displayName: "Friend before update")
                fixture.ownerID = try await owner.hallway().me.id
                fixture.friendID = try await friend.hallway().me.id
                _ = try await owner.search(fh); _ = try await friend.search(fixture.ownerHandle)
                try await owner.request(fixture.friendID)
                try await friend.accept(fixture.ownerID)
                try await owner.setCloseFriend(fixture.friendID, true)
                try await owner.setOpenDoorPolicy(true)
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
                await friend.signOut()
                // Deliberately preserve owner's Keychain token as process exits.
            } catch {
                await owner.signOut(); await friend.signOut(); throw error
            }
        } else {
            #expect(environment["DOORBELL_UPGRADE_TEST_PHASE"] == "restore")
            let fixture = try JSONDecoder().decode(RestartFixture.self, from: Data(contentsOf: fixtureURL))
            #expect(fixture.seedProcessID != ProcessInfo.processInfo.processIdentifier)
            #expect(!fixture.ownerID.isEmpty && !fixture.friendID.isEmpty)
            AppConfig.prepareLegacySession(for: url, directory: folder)
            let restored = ConvexBackend(url: url, directory: folder, profile: fixture.profile)
            do {
                // No password or sign-in call exists in this process.
                #expect(await restored.accountState() == .ready)
                var snapshot = try await restored.hallway()
                for _ in 0..<100 {
                    if snapshot.doors.contains(where: { $0.profile.id == fixture.friendID && $0.isCloseFriend }) { break }
                    try await Task.sleep(for: .milliseconds(30))
                    snapshot = try await restored.hallway()
                }
                #expect(snapshot.me.id == fixture.ownerID && snapshot.me.handle == fixture.ownerHandle)
                #expect(snapshot.me.displayName == "Account before update" && snapshot.me.openDoorPolicy)
                #expect(snapshot.doors.count == 1)
                #expect(snapshot.doors.first?.profile.id == fixture.friendID)
                #expect(snapshot.doors.first?.isCloseFriend == true && snapshot.doors.first?.followsMe == true)
            } catch { await restored.signOut(); throw error }
            await restored.signOut()
        }
    }

}
