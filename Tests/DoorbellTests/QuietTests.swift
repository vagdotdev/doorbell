import Testing
@testable import DoorbellApp

struct QuietTests {
    @MainActor @Test func unprovisionedBuildNeverPromptsForFocus() async {
        // SwiftPM's test runner has no provisioned Focus capability.
        #expect(!Quiet.supportsFocusStatus)
        #expect(await Quiet.requestFocusAccess() == false)
    }
    @Test func betaSkipsFocusButStillChecksCapture() {
        var queriedFocus = false
        let focus = { queriedFocus = true; return Quiet.Status.focusAccessRequired }
        #expect(Quiet.status(focusSupported: false, focus: focus, camera: { false }, processes: { [] }) == .available)
        #expect(!queriedFocus)
        #expect(Quiet.status(focusSupported: false, focus: focus, camera: { true }, processes: { [] }) == .otherAppRecording)
        #expect(Quiet.status(focusSupported: false, focus: focus, camera: { nil }, processes: { [] }) == .audioActivityUnavailable)
        #expect(Quiet.status(focusSupported: false, focus: focus, camera: { false }, processes: { nil }) == .audioActivityUnavailable)
        #expect(Quiet.status(focusSupported: true, focus: focus, camera: { false }, processes: { [] }) == .focusAccessRequired)
        #expect(queriedFocus)
    }
    @Test func ownMicrophoneAndOtherPlaybackDoNotMuteAmbient() {
        #expect(!Quiet.shouldSuppressAmbient(focused: false, processes: [
            .init(pid: 10, inputRunning: true), .init(pid: 11, inputRunning: false)
        ], ownPID: 10))
    }

    @Test func anotherAppRecordingSuppressesAmbient() {
        #expect(Quiet.shouldSuppressAmbient(focused: false, processes: [
            .init(pid: 10, inputRunning: true), .init(pid: 11, inputRunning: true)
        ], ownPID: 10))
    }

    @Test func focusAndUnknownStateSuppressAmbient() {
        #expect(Quiet.shouldSuppressAmbient(focused: true, processes: [], ownPID: 10))
        #expect(Quiet.shouldSuppressAmbient(focused: nil, processes: [], ownPID: 10))
        #expect(Quiet.shouldSuppressAmbient(focused: false, processes: nil, ownPID: 10))
        #expect(!Quiet.shouldSuppressAmbient(focused: false, processes: [], ownPID: 10))
    }
}
