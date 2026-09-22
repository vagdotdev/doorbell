import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DoorbellApp

@MainActor private final class StickerSeat: MediaSession {
    var packets: [(topic: String, data: Data)] = []
    var streams: [(to: [String], attributes: [String: String])] = []
    override func send(_ data: Data, topic: String) async throws { packets.append((topic, data)) }
    override func sendBytes(_ data: Data, topic: String, attributes: [String: String], to identities: [String]) async throws {
        streams.append((identities, attributes))
    }
}

private let me = Profile(id: "me", handle: "me", displayName: "Me")

private func peer(_ id: String) -> MediaSession.Peer {
    MediaSession.Peer(id: id, name: id, via: nil, video: nil, screen: nil, micOn: true, camOn: true, isSpeaking: false)
}

private func picture(_ side: Int, frames: Int = 1, type: UTType = .png) -> Data {
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, frames, nil)!
    if frames > 1 {
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    }
    for index in 0..<frames {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(frames), green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let properties = frames > 1 ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary : nil
        CGImageDestinationAddImage(destination, context.makeImage()!, properties)
    }
    CGImageDestinationFinalize(destination)
    return out as Data
}

/// Every code answered 200 for both 128.png and 512.gif on fonts.gstatic.com.
private let verifiedNoto: Set<String> = [
    "1f602", "1f923", "1f62d", "1f60d", "1f970", "1f618", "1f60e", "1f929", "1f973", "1f60a", "1f642", "1f643",
    "1f609", "1f605", "1f606", "1f61c", "1f92a", "1f60f", "1f644", "1f62c", "1f979", "1f97a", "1f972", "1f622",
    "1f624", "1f621", "1f92f", "1f631", "1f633", "1fae0", "1f914", "1f928", "1f9d0", "1f92b", "1f92d", "1fae3",
    "1f910", "1f971", "1f634", "1f924", "1f92e", "1f635_200d_1f4ab", "1f636_200d_1f32b_fe0f", "1f607", "1f608",
    "1fae1", "1f921", "1f480", "1f47b", "1f47d", "1f47e", "1f916", "1f4a9", "1f383",
    "2764_fe0f", "2764_fe0f_200d_1f525", "1f525", "2728", "1f4af", "1f496", "1f495", "1f494", "1f48b", "1f63b",
    "1f44d", "1f44e", "1f44f", "1f64c", "1f64f", "1f44b", "1f91d", "270c_fe0f", "1f91e", "1f918", "1faf6", "1f4aa",
    "1f440",
    "1f389", "1f38a", "1f942", "1f37b", "1f382", "1f381", "1f388", "1faa9", "1f483", "1f3c6", "1f680", "1f4a5",
    "26a1", "1f308", "1f6a8", "1f4b8", "2615", "1f355", "1f37f", "2603_fe0f", "1f340", "1f31e", "1f31a",
    "1f648", "1f649", "1f64a", "1f63a", "1f639", "1f640", "1f63f", "1f63e", "1f431", "1f98a", "1f43c", "1f98d",
    "1f438", "1f984", "1f427", "1f423", "1f41d", "1f98b", "1f419", "1f422", "1f40d", "1f40c", "1f996", "1f9a5",
]

@MainActor struct StickerTests {
    @Test func catalogIsExactlyTheVerifiedNotoAnimations() {
        let emoji = StickerCatalog.packs.flatMap(\.stickers)
        #expect(emoji.count == Set(emoji).count)
        #expect(emoji.allSatisfy(Sticker.isEmoji))
        #expect(Set(emoji.map(StickerCatalog.code)) == verifiedNoto)
    }

    @Test func wireCarriesOneStickerAndNothingElse() {
        for sticker in [Sticker.emoji("😂"), .emoji("\u{2764}\u{FE0F}\u{200D}\u{1F525}"), .custom(String(repeating: "ab", count: 32))] {
            #expect(Sticker(wire: sticker.wire) == sticker)
        }
        let junk = [#"{"emoji":"hello"}"#, #"{"emoji":"😂😂"}"#, #"{"emoji":"a"}"#, #"{"emoji":"1"}"#,
                    #"{"custom":"abc"}"#, #"{"custom":"\#(String(repeating: "A", count: 64))"}"#,
                    #"{"emoji":"😂","custom":"x"}"#, "not json", ""]
        for text in junk { #expect(Sticker(wire: Data(text.utf8)) == nil) }
        #expect(Sticker(wire: Data(repeating: 32, count: 600)) == nil)
    }

    @Test func stickersTravelOnTheirOwnTopicBothWays() async {
        let media = StickerSeat()
        var cues = 0
        let room = RoomSession(media: media, isLive: true, onIncomingMessage: { cues += 1 }, myArt: { _ in nil })
        room.start(host: "me", me: me, others: [])
        #expect(await room.send(.emoji("😂")))
        #expect(media.packets.map(\.topic) == [Sticker.topic])
        #expect(room.chat.last?.sticker == .emoji("😂") && room.chat.last?.text == "😂")

        media.onData?(Sticker.emoji("🔥").wire, Sticker.topic, "friend")
        media.onData?(Sticker.emoji("🔥").wire, Sticker.topic, "me")
        media.onData?(Data(#"{"emoji":"hello"}"#.utf8), Sticker.topic, "friend")
        media.onData?(Sticker.emoji("🔥").wire, Sticker.topic, nil)
        #expect(room.chat.count == 2)
        #expect(room.chat.last?.sticker == .emoji("🔥") && room.chat.last?.from.id == "friend")
        #expect(cues == 1 && room.unread == 1)

        room.reset()
        media.onData?(Sticker.emoji("🔥").wire, Sticker.topic, "friend")
        #expect(room.chat.isEmpty)
    }

    @Test func customArtGoesOncePerPersonThenOnlyItsName() async throws {
        let media = StickerSeat()
        let art = try StickerImport.normalize(picture(64)), hash = StickerImport.hash(art)
        let other = try StickerImport.normalize(picture(48)), otherHash = StickerImport.hash(other)
        let room = RoomSession(media: media, isLive: true, onIncomingMessage: {},
                               myArt: { [hash: art, otherHash: other][$0] })
        room.start(host: "me", me: me, others: [])
        media.peers = [peer("friend")]
        #expect(await room.send(.custom(hash)))
        #expect(await room.send(.custom(hash)))
        #expect(media.streams.map(\.to) == [["friend"]])
        #expect(media.streams.first?.attributes == ["hash": hash])
        #expect(media.packets.count == 2 && media.packets.allSatisfy { $0.topic == Sticker.topic })

        media.peers = [peer("friend"), peer("carol")]
        #expect(await room.send(.custom(hash)))
        #expect(media.streams.map(\.to) == [["friend"], ["carol"]])

        // Friend leaves and returns with an empty room of their own.
        media.peers = [peer("carol")]
        room.include(Profile(id: "carol", handle: "carol", displayName: "Carol"))
        media.peers = [peer("friend"), peer("carol")]
        #expect(await room.send(.custom(hash)))
        #expect(media.streams.map(\.to) == [["friend"], ["carol"], ["friend"]])

        // A burst of a new sticker shares one upload.
        async let first = room.send(.custom(otherHash))
        async let second = room.send(.custom(otherHash))
        #expect(await [first, second] == [true, true])
        #expect(media.streams.filter { $0.attributes["hash"] == otherHash }.count == 1)

        #expect(await room.send(.custom(String(repeating: "0", count: 64))) == false)
        #expect(room.problem != nil)
        room.reset()
    }

    @Test func receivedArtMustBeWhatItClaimsAndLeavesWithTheRoom() throws {
        let media = MediaSession()
        let room = RoomSession(media: media, isLive: false, onIncomingMessage: {}, myArt: { _ in nil })
        room.start(host: "me", me: me, others: [])
        let art = try StickerImport.normalize(picture(40)), hash = StickerImport.hash(art)
        let junk = Data("not a picture".utf8)
        media.onBytes?(art, Sticker.artTopic, ["hash": String(repeating: "0", count: 64)], "friend")
        media.onBytes?(junk, Sticker.artTopic, ["hash": StickerImport.hash(junk)], "friend")
        media.onBytes?(art, "other", ["hash": hash], "friend")
        media.onBytes?(art, Sticker.artTopic, ["hash": hash], "me")
        #expect(room.stickerArt.isEmpty)
        media.onBytes?(art, Sticker.artTopic, ["hash": hash], "friend")
        #expect(room.art(hash) == art)
        room.reset()
        #expect(room.art(hash) == nil)
    }

    @Test func importShrinksStillsKeepsMotionAndRefusesJunk() throws {
        let still = try StickerImport.normalize(picture(1024, type: .jpeg))
        let source = try #require(CGImageSourceCreateWithData(still as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        #expect(try #require(StickerFrames.decode(still, maxPixel: 4096)).images.first?.width == 512)

        let gif = picture(64, frames: 3, type: .gif)
        #expect(try StickerImport.normalize(gif) == gif)
        let frames = try #require(StickerFrames.decode(gif, maxPixel: 64))
        #expect(frames.images.count == 3)
        #expect(abs(frames.duration - 0.6) < 0.01)
        #expect(frames.keyTimes.count == 4 && frames.keyTimes.first == 0 && frames.keyTimes.last == 1)

        let long = try #require(StickerFrames.decode(picture(16, frames: 10, type: .gif), maxPixel: 16, limit: 5))
        #expect(long.images.count == 5 && abs(long.duration - 2) < 0.01)

        #expect(throws: StickerImport.Failure.notAnImage) { try StickerImport.normalize(Data("hello".utf8)) }
    }

    @Test func libraryKeepsPicturesAndRecentsAcrossLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stickers-\(UUID())")
        let suite = "StickerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }

        let library = StickerLibrary(directory: directory, defaults: defaults)
        #expect(await library.add(pictures: [picture(32), picture(40)]) == nil)
        #expect(library.mine.count == 2)
        #expect(await library.add(pictures: [Data("nope".utf8)]) != nil)
        #expect(library.mine.count == 2)
        let newest = library.mine[0]
        library.noteSent(.custom(newest))
        library.noteSent(.emoji("😂"))
        library.noteSent(.custom(newest))
        #expect(library.recent == [.custom(newest), .emoji("😂")])

        let reopened = StickerLibrary(directory: directory, defaults: defaults)
        #expect(Set(reopened.mine) == Set(library.mine) && reopened.recent == library.recent)
        #expect(reopened.data(for: newest).map(StickerImport.hash) == newest)
        reopened.remove(newest)
        #expect(!reopened.mine.contains(newest) && reopened.recent == [.emoji("😂")])
        #expect(StickerLibrary(directory: directory, defaults: defaults).mine.count == 1)
    }

    @Test func spamPilesUpPerPersonAndTextBreaksThePile() {
        let a = Profile(id: "a", handle: "a", displayName: "A"), b = Profile(id: "b", handle: "b", displayName: "B")
        let sticker = { (who: Profile) in ChatMessage(from: who, text: "😂", sticker: .emoji("😂")) }
        let chat = [sticker(a), sticker(a), ChatMessage(from: a, text: "lol"), sticker(a), sticker(b), sticker(b)]
        #expect(ChatRun.runs(chat).map(\.messages.count) == [2, 1, 1, 2])
    }
}
