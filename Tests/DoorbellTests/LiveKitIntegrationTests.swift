import Foundation
import Testing
@testable import DoorbellApp

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DOORBELL_MEDIA_TEST_CONFIG"] != nil))
@MainActor struct LiveKitIntegrationTests {
    struct Config: Decodable { let room: String; let url: String; let first: String; let second: String }
    func config() throws -> Config {
        let path = try #require(ProcessInfo.processInfo.environment["DOORBELL_MEDIA_TEST_CONFIG"])
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    @Test func actualPeersExchangeDataAndDisconnect() async throws {
        let c = try config(); let first = MediaSession(); let second = MediaSession()
        var received: String?
        second.onData = { data, topic, sender in if topic == "chat", sender == "first" { received = String(data: data, encoding: .utf8) } }
        try await first.connect(.init(url: c.url, token: c.first, room: c.room), microphone: false, camera: false)
        try await second.connect(.init(url: c.url, token: c.second, room: c.room), microphone: false, camera: false)
        // LiveKit batches non-publishing participant updates every three seconds.
        for _ in 0..<500 { if first.peers.count == 1 && second.peers.count == 1 { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(first.peers.count == 1 && second.peers.count == 1)
        try await first.send(Data("hello from a real room".utf8), topic: "chat")
        for _ in 0..<100 { if received != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(received == "hello from a real room")
        #expect(!first.micOn && !first.camOn && !second.micOn && !second.camOn)
        await first.disconnect(); await second.disconnect()
        #expect(first.phase == .idle && second.phase == .idle)
        #expect(first.peers.isEmpty && second.peers.isEmpty)
    }
    @Test func immediateDisconnectCannotBeUndoneByConnectCompletion() async throws {
        let c = try config(); let seat = MediaSession()
        let connecting = Task { try await seat.connect(.init(url: c.url, token: c.first, room: c.room), microphone: false, camera: false) }
        await Task.yield()
        await seat.disconnect()
        _ = try? await connecting.value
        #expect(seat.phase == .idle && !seat.micOn && !seat.camOn)
        #expect(seat.peers.isEmpty)
    }
    @Test func refusedConnectionProducesFailureState() async {
        let seat = MediaSession()
        do {
            try await seat.connect(.init(url: "ws://127.0.0.1:1", token: "invalid", room: "door:test"), microphone: false, camera: false)
            Issue.record("Unexpected connection to closed port")
        } catch {}
        #expect(seat.phase == .failed && seat.problem != nil)
        #expect(!seat.micOn && !seat.camOn)
        await seat.disconnect()
    }
}
