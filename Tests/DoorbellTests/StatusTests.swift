import Foundation
import Testing
@testable import DoorbellApp

@MainActor struct StatusTests {
    @Test func myStatusShowsAtOnceTidyAndShort() async {
        let backend = TestBackend()
        let hallway = HallwayStore(backend: backend)
        await hallway.refresh()
        hallway.setStatus("  in a   meeting\n till 4 — then chai on the terrace, come up  ")
        let shown = hallway.myStatus?.text
        #expect(shown == "in a meeting till 4 — then chai on the t")
        #expect(shown?.count == DoorStatus.maxLength)
        #expect(hallway.myStatus.map { abs($0.expiresAt.timeIntervalSinceNow - DoorStatus.lifetime) < 5 } == true)
        for _ in 0..<200 { if await backend.statusWrites.count == 1 { break }; try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await backend.statusWrites == [shown])

        hallway.setStatus(shown ?? "")
        hallway.setStatus("   ")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.statusWrites.count == 1)

        hallway.clearStatus()
        #expect(hallway.myStatus == nil)
        for _ in 0..<200 { if await backend.statusWrites.count == 2 { break }; try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await backend.statusWrites.last == .some(nil))
    }

    @Test func expiredStatusesAreNotShown() {
        #expect(DoorStatus(text: "x", expiresAt: Date() + 60).isShowing())
        #expect(!DoorStatus(text: "x", expiresAt: Date() - 1).isShowing())
    }

    @Test func typingAStatusHoldsTheBoardOpenUntilUnpinned() {
        let state = NotchState()
        var keyed = 0
        state.onTypingStart = { keyed += 1 }
        #expect(state.kind == .compact)
        state.isTyping = true
        #expect(state.kind == .board && keyed == 1)
        state.unpin()
        #expect(!state.isTyping && state.kind == .compact)
    }
}
