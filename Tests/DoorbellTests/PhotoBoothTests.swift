import Combine
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DoorbellApp

@MainActor private final class BoothSeat: MediaSession {
    var packets: [(topic: String, data: Data)] = []
    override func send(_ data: Data, topic: String) async throws { packets.append((topic, data)) }
}

private let me = Profile(id: "me", handle: "me", displayName: "Me")

private func face(_ side: Int = 64) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()!
}

@MainActor private func temporaryLibrary() -> PhotoBoothLibrary {
    PhotoBoothLibrary(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("photo-booth-\(UUID())", isDirectory: true))
}

@MainActor struct PhotoBoothTests {
    @Test func everyLookKeepsThePictureItsSize() {
        let image = CIImage(cgImage: face(48))
        for filter in BoothFilter.allCases {
            #expect(filter.apply(to: image).extent == image.extent)
        }
    }

    @Test func paperFitsTheCrowd() {
        #expect(PolaroidComposer.layout(for: 1) == PolaroidComposer.layout(for: 0))
        #expect(PolaroidComposer.layout(for: 1).columns == 1)
        #expect(PolaroidComposer.layout(for: 2).columns == 2 && PolaroidComposer.layout(for: 2).rows == 1)
        #expect(PolaroidComposer.layout(for: 3).columns == 2)
        #expect(PolaroidComposer.layout(for: 4) == PolaroidComposer.layout(for: 3))

        let solo = PolaroidComposer.paperSize(for: 1)
        let pair = PolaroidComposer.paperSize(for: 2)
        let four = PolaroidComposer.paperSize(for: 4)
        #expect(solo.height > solo.width)          // classic Polaroid: tall
        #expect(pair.width > pair.height)          // two side by side: wide
        #expect(four.height > four.width)          // grid plus chin: tall again

        for count in 1...4 {
            let faces = (0..<count).map { PolaroidComposer.Face(name: "Friend \($0)", image: face()) }
            let print = PolaroidComposer.compose(faces: faces, filter: .instant)
            let paper = PolaroidComposer.paperSize(for: count)
            #expect(print != nil)
            #expect(print.map { CGFloat($0.width) } == paper.width * PolaroidComposer.scale)
            #expect(print.map { CGFloat($0.height) } == paper.height * PolaroidComposer.scale)
        }
        #expect(PolaroidComposer.compose(faces: [], filter: .noir) == nil)
    }

    @Test func captionsReadLikeAPolaroid() {
        #expect(PolaroidComposer.caption(names: []) == "Doorbell")
        #expect(PolaroidComposer.caption(names: ["Vagdev Tamira"]) == "Vagdev")
        #expect(PolaroidComposer.caption(names: ["Vagdev", "Arjun"]) == "Vagdev & Arjun")
        #expect(PolaroidComposer.caption(names: ["Vagdev", "Arjun Rao", "Meera"]) == "Vagdev, Arjun & Meera")

        let date = Date(timeIntervalSince1970: 1_789_620_240) // 2026-09-17 04:44 UTC
        let stamp = PolaroidComposer.caption(date: date, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        #expect(stamp == "17 Sep 2026 · 10:14 am")
    }

    @Test func libraryKeepsPolaroidsNewestFirstAsRealPNGs() throws {
        let library = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }

        let when = Date(timeIntervalSince1970: 1_789_620_240)
        let first = try library.save(face(), at: when)
        let second = try library.save(face(), at: when)   // same second: no overwrite
        #expect(first != second)
        #expect(library.recent == [second, first])
        #expect(first.lastPathComponent.hasPrefix("Doorbell ") && first.pathExtension == "png")

        let source = try #require(CGImageSourceCreateWithURL(first as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 64)

        // A fresh look at the same folder finds both, newest first.
        let reopened = PhotoBoothLibrary(directory: library.directory)
        #expect(Set(reopened.recent) == Set([first, second]))
    }

    @Test func theShutterCountsDownSaysCheeseOnceAndComesOut() async throws {
        let media = BoothSeat()
        let booth = PhotoBoothSession(media: media, isLive: true)
        booth.library = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: booth.library.directory) }
        booth.pause = { _ in }
        booth.faceSource = { [PolaroidComposer.Face(name: "Vagdev", image: face())] }
        booth.filter = .noir

        var phases: [PhotoBoothSession.Phase] = []
        let sink = booth.$phase.sink { phases.append($0) }
        await booth.take()
        await booth.running?.value
        sink.cancel()

        #expect(media.packets.map(\.topic) == [PhotoBoothSession.topic])
        #expect(media.packets.first?.data == PhotoBoothSession.wire(.noir))
        #expect(booth.shots.count == 1 && booth.shots.first?.filter == .noir)
        #expect(booth.toast?.id == booth.shots.first?.id)
        let url = try #require(booth.shots.first?.url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(booth.library.recent == [url])
        #expect(phases.contains(.countdown(3)) && phases.contains(.countdown(1))
                && phases.contains(.flash) && phases.contains(.developing))
        #expect(booth.phase == .idle)
    }

    @Test func aFriendsShutterAdoptsTheirLookWithoutResending() async throws {
        let media = BoothSeat()
        let booth = PhotoBoothSession(media: media, isLive: true)
        booth.library = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: booth.library.directory) }
        booth.pause = { _ in }
        booth.faceSource = { [PolaroidComposer.Face(name: "Arjun", image: face())] }
        booth.filter = .instant

        booth.receive(PhotoBoothSession.wire(.chrome))
        await booth.running?.value
        #expect(media.packets.isEmpty)
        #expect(booth.shots.first?.filter == .chrome)   // their look, this shot
        #expect(booth.filter == .instant)               // my chip stays mine

        booth.receive(Data("junk".utf8))
        booth.receive(Data(#"{"filter":"sepia"}"#.utf8))
        booth.receive(Data(repeating: 32, count: 300))
        await booth.running?.value
        #expect(booth.shots.count == 1)
    }

    @Test func boothMessagesRideTheirOwnTopicQuietly() async throws {
        let media = BoothSeat()
        var cues = 0
        let room = RoomSession(media: media, isLive: true, onIncomingMessage: { cues += 1 }, myArt: { _ in nil })
        room.booth.library = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: room.booth.library.directory) }
        room.booth.pause = { _ in }
        room.booth.faceSource = { [PolaroidComposer.Face(name: "Vagdev", image: face())] }
        room.start(host: "me", me: me, others: [])

        media.onData?(PhotoBoothSession.wire(.noir), PhotoBoothSession.topic, "friend")
        await room.booth.running?.value
        #expect(room.booth.shots.count == 1)
        #expect(room.unread == 0 && cues == 0 && room.chat.isEmpty)   // a photo, not a message

        // Echoes of my own shutter don't take a second photo.
        media.onData?(PhotoBoothSession.wire(.noir), PhotoBoothSession.topic, "me")
        await room.booth.running?.value
        #expect(room.booth.shots.count == 1)

        room.reset()
        #expect(room.booth.shots.isEmpty && room.boothOpen == false)
        media.onData?(PhotoBoothSession.wire(.noir), PhotoBoothSession.topic, "friend")
        await room.booth.running?.value
        #expect(room.booth.shots.isEmpty)   // the room is over
    }

    @Test func onePanelAtATime() {
        let room = RoomSession(media: MediaSession(), isLive: false, onIncomingMessage: {}, myArt: { _ in nil })
        room.toggleChat()
        room.toggleBooth()
        #expect(room.boothOpen && !room.chatOpen && !room.peopleOpen)
        room.togglePeople()
        #expect(room.peopleOpen && !room.boothOpen)
        room.toggleBooth()
        room.toggleChat()
        #expect(room.chatOpen && !room.boothOpen)
        room.reset()
        #expect(!room.boothOpen)
    }
}
