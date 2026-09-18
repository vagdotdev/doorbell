import Foundation
import Testing
@testable import DoorbellApp

@MainActor struct ChatSoundTests {
    @Test func remoteMessagesCueEvenWithChatOpenAndOwnMessagesStayQuiet() async {
        let media = MediaSession()
        var cues = 0
        let room = RoomSession(media: media, isLive: false, onIncomingMessage: { cues += 1 })
        let me = Profile(id: "local-id", handle: "local", displayName: "You")
        let friend = Profile(id: "friend", handle: "friend", displayName: "Friend")
        room.start(host: "local", me: me, others: [friend])
        room.chatOpen = true

        media.onData?(Data("hello".utf8), "chat", "friend")
        #expect(cues == 1)
        #expect(room.chat.count == 1)
        #expect(room.unread == 0)

        #expect(await room.send("hi back"))
        #expect(cues == 1)
        #expect(room.chat.count == 2)
        // A transport echo of our own publication must not double the message or cue.
        media.onData?(Data("hi back".utf8), "chat", "local")
        media.onData?(Data("hi back".utf8), "chat", "local-id")
        #expect(cues == 1)
        #expect(room.chat.count == 2)

        room.chatOpen = false
        media.onData?(Data("another thing".utf8), "chat", "friend")
        #expect(cues == 2)
        #expect(room.unread == 1)
        room.reset()
    }

    @Test func inactiveUnknownAndMalformedMessagesStayQuiet() {
        let media = MediaSession()
        var cues = 0
        let room = RoomSession(media: media, isLive: false, onIncomingMessage: { cues += 1 })
        media.onData?(Data("before joining".utf8), "chat", "friend")
        room.start(host: "local", me: Profile(id: "local", handle: "local", displayName: "You"), others: [])
        media.onData?(Data("other topic".utf8), "status", "friend")
        media.onData?(Data(repeating: 65, count: 4_001), "chat", "friend")
        media.onData?(Data([0xFF]), "chat", "friend")
        media.onData?(Data(" \n\t".utf8), "chat", "friend")
        media.onData?(Data("missing sender".utf8), "chat", nil)
        media.onData?(Data("empty sender".utf8), "chat", "")
        #expect(cues == 0)
        #expect(room.chat.isEmpty)
        room.reset()
        media.onData?(Data("after leaving".utf8), "chat", "friend")
        #expect(cues == 0)
        #expect(room.chat.isEmpty)
    }

    @Test func burstThrottleHonorsSoundsSettingWithoutDelayingReenable() {
        var throttle = ChatCueThrottle()
        let initiallyDisabled = throttle.shouldPlay(enabled: false, now: 10)
        let first = throttle.shouldPlay(enabled: true, now: 10)
        let burst = throttle.shouldPlay(enabled: true, now: 10.1)
        let justBefore = throttle.shouldPlay(enabled: true, now: 10.49)
        let next = throttle.shouldPlay(enabled: true, now: 10.5)
        let disabledAgain = throttle.shouldPlay(enabled: false, now: 11)
        let reenabled = throttle.shouldPlay(enabled: true, now: 11)
        #expect(!initiallyDisabled)
        #expect(first)
        #expect(!burst)
        #expect(!justBefore)
        #expect(next)
        #expect(!disabledAgain)
        #expect(reenabled)
    }
}
