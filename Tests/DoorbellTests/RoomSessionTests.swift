import Foundation
import Testing
@testable import DoorbellApp

@MainActor private final class ChatSeat: MediaSession {
    var sent: [Data] = []
    var refuse = false
    override func send(_ data: Data, topic: String) async throws {
        if refuse { throw MediaFailure.unavailable }
        sent.append(data)
    }
}
@MainActor struct RoomSessionTests {
    @Test func everyLiveBackendUsesTransportAndDoesNotInventPeers() async {
        let media = ChatSeat(), room = RoomSession(media: media, isLive: true)
        let me = Profile(id: "me", handle: "me", displayName: "Me")
        room.start(host: "me", me: me, others: [Profile(id: "friend", handle: "friend", displayName: "Friend")])
        #expect(room.participants.count == 1)
        #expect(await room.send("hello"))
        #expect(media.sent == [Data("hello".utf8)])
        #expect(room.chat.count == 1)
        media.refuse = true
        #expect(await room.send("kept draft") == false)
        #expect(room.chat.count == 1 && room.problem != nil)
        room.reset()
        await media.disconnect()
    }
}
