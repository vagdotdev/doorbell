import CoreGraphics
import Foundation
import Testing
@testable import DoorbellApp

@MainActor private final class PointerSeat: MediaSession {
    var lossy: [PointerMessage] = []
    var reliable: [(topic: String, data: Data)] = []
    override func send(_ data: Data, topic: String) async throws { reliable.append((topic, data)) }
    override func sendLossy(_ data: Data, topic: String) async throws {
        if topic == PointerMessage.topic, let message = PointerMessage(wire: data) { lossy.append(message) }
    }
}

private func peer(_ id: String) -> MediaSession.Peer {
    MediaSession.Peer(id: id, name: id, via: nil, video: nil, screen: nil, micOn: true, camOn: true, isSpeaking: false)
}

@MainActor struct PointingTests {
    @Test func pointerPacketsCarryAPlaceOnTheScreenAndNothingElse() {
        let moved = PointerMessage(on: "bob", at: CGPoint(x: 0.25, y: 0.75))
        #expect(PointerMessage(wire: moved.wire) == moved)
        let gone = PointerMessage(on: "bob", at: nil)
        #expect(PointerMessage(wire: gone.wire)?.gone == true)
        for junk in [#"{"on":"bob","x":1.5,"y":0.2}"#, #"{"on":"bob","x":0.2}"#, #"{"on":"","x":0.1,"y":0.1}"#, "nope"] {
            #expect(PointerMessage(wire: Data(junk.utf8)) == nil)
        }
    }

    @Test func pointsOnTheLetterboxAreNotOnTheScreen() throws {
        let content = ShareGeometry.fit(aspect: 16.0 / 9.0, in: CGSize(width: 800, height: 600))
        #expect(content == CGRect(x: 0, y: 75, width: 800, height: 450))
        #expect(ShareGeometry.normalize(CGPoint(x: 400, y: 40), in: content) == nil)
        let middle = try #require(ShareGeometry.normalize(CGPoint(x: 400, y: 300), in: content))
        #expect(abs(middle.x - 0.5) < 0.001 && abs(middle.y - 0.5) < 0.001)
        let tall = ShareGeometry.fit(aspect: 0.5, in: CGSize(width: 800, height: 600))
        #expect(tall == CGRect(x: 250, y: 0, width: 300, height: 600))
    }

    @Test func friendsPointersLandOnTheBoardNotInTheChat() async {
        let media = PointerSeat()
        var cues = 0
        let room = RoomSession(media: media, isLive: true, onIncomingMessage: { cues += 1 }, myArt: { _ in nil })
        room.start(host: "me", me: Profile(id: "me", handle: "me", displayName: "Me"),
                   others: [Profile(id: "arjun", handle: "arjun", displayName: "Arjun Mehta")])
        media.phase = .connected
        media.peers = [peer("arjun")]
        room.include(Profile(id: "carol", handle: "carol", displayName: "Carol"))
        media.onData?(PointerMessage(on: "me", at: CGPoint(x: 0.3, y: 0.4)).wire, PointerMessage.topic, "arjun")
        media.onData?(PointerMessage(on: "me", at: CGPoint(x: 0.9, y: 0.9)).wire, PointerMessage.topic, "me")
        #expect(room.pointers.marks(on: "me").map(\.id) == ["arjun"])
        #expect(room.pointers.marks["arjun"]?.name == "Arjun")
        #expect(room.chat.isEmpty && room.unread == 0 && cues == 0)
        media.onData?(PointerMessage(on: "me", at: CGPoint(x: 0.3, y: 0.4), ping: true).wire, PointerMessage.topic, "arjun")
        #expect(room.pointers.marks["arjun"]?.pings == 1)
        media.onData?(PointerMessage(on: "me", at: nil).wire, PointerMessage.topic, "arjun")
        #expect(room.pointers.marks.isEmpty)
        media.onData?(PointerMessage(on: "me", at: CGPoint(x: 0.5, y: 0.5)).wire, PointerMessage.topic, "arjun")
        room.reset()
        #expect(room.pointers.marks.isEmpty)
    }

    @Test func aBurstOfMovesSendsNowThenTheLastPositionAndPingsGoReliably() async throws {
        let media = PointerSeat()
        let room = RoomSession(media: media, isLive: true, onIncomingMessage: {}, myArt: { _ in nil })
        room.start(host: "bob", me: Profile(id: "me", handle: "me", displayName: "Me"), others: [])
        for step in 0..<20 { room.point(at: CGPoint(x: Double(step) / 20, y: 0.5), on: "bob") }
        for _ in 0..<100 { if media.lossy.count >= 2 { break }; try? await Task.sleep(for: .milliseconds(5)) }
        #expect(media.lossy.count == 2)
        #expect(media.lossy.first?.x == 0 && media.lossy.last?.x == 0.95)
        room.point(at: nil, on: "bob")
        for _ in 0..<100 { if media.lossy.count >= 3 { break }; try? await Task.sleep(for: .milliseconds(5)) }
        #expect(media.lossy.last?.gone == true)

        room.ping(at: CGPoint(x: 0.1, y: 0.2), on: "bob")
        for _ in 0..<100 { if !media.reliable.isEmpty { break }; try? await Task.sleep(for: .milliseconds(5)) }
        let ping = try #require(media.reliable.first.flatMap { PointerMessage(wire: $0.data) })
        #expect(media.reliable.first?.topic == PointerMessage.topic && ping.ping == true && ping.on == "bob")
        room.reset()
    }
}
