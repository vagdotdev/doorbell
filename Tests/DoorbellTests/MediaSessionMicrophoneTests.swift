import Foundation
import Testing
@testable import DoorbellApp

@MainActor struct MediaSessionMicrophoneTests {
    @Test(arguments: [true, false])
    func muteWhilePermissionIsPendingNeverStartsCapture(permissionGranted: Bool) async {
        var permission: CheckedContinuation<Bool, Never>?
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: {
            await withCheckedContinuation { permission = $0 }
        }, microphoneControl: { changes.append($0) })
        media.phase = .connected
        let unmute = Task { await media.setMicrophone(true) }
        while permission == nil { await Task.yield() }
        var mute: Task<Void, Never>?
        // The main-actor child reaches its queue wait before the parent resumes.
        await withCheckedContinuation { queued in
            mute = Task {
                queued.resume()
                await media.setMicrophone(false)
            }
        }
        permission?.resume(returning: permissionGranted)
        await unmute.value; await mute?.value
        #expect(changes == [false])
        #expect(media.problem == nil)
        #expect(!media.isUpdating)
    }

    @Test func reconnectingDuringPermissionPromptDoesNotStartCapture() async {
        var permission: CheckedContinuation<Bool, Never>?
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: {
            await withCheckedContinuation { permission = $0 }
        }, microphoneControl: { changes.append($0) })
        media.phase = .connected
        let unmute = Task { await media.setMicrophone(true) }
        while permission == nil { await Task.yield() }
        media.phase = .reconnecting
        permission?.resume(returning: true)
        await unmute.value
        #expect(changes.isEmpty)
        #expect(media.problem == nil)
        #expect(!media.isUpdating)
    }

    @Test func connectingAllowsMuteWithoutRequestingPermission() async {
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: {
            Issue.record("Connecting mute must not request capture permission")
            return true
        }, microphoneControl: { changes.append($0) })
        media.phase = .connecting
        await media.setMicrophone(false)
        #expect(changes == [false])
    }

    @Test func reconnectingAllowsPrivacyMuteButNeverStartsCapture() async {
        var permissionRequests = 0
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: {
            permissionRequests += 1
            return true
        }, microphoneControl: { changes.append($0) })
        media.phase = .reconnecting
        await media.setMicrophone(false)
        await media.setMicrophone(true)
        #expect(changes == [false])
        #expect(permissionRequests == 0)
        #expect(!media.isUpdating)
    }

    @Test func reconnectingMuteWaitsForPendingUnmuteAndWins() async {
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: { true }, microphoneControl: { on in
            if on {
                started = true
                await withCheckedContinuation { release = $0 }
            }
            changes.append(on)
        })
        media.phase = .connected
        let unmute = Task { await media.setMicrophone(true) }
        while !started { await Task.yield() }
        media.phase = .reconnecting
        let mute = Task { await media.setMicrophone(false) }
        await Task.yield()
        release?.resume()
        await unmute.value; await mute.value
        #expect(changes == [true, false])
        #expect(!media.isUpdating)
    }

    @Test func muteIsNotDroppedDuringAnInFlightUnmute() async {
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: { true }, microphoneControl: { on in
            if on {
                started = true
                await withCheckedContinuation { release = $0 }
            }
            changes.append(on)
        })
        media.phase = .connected
        let first = Task { await media.setMicrophone(true) }
        while !started { await Task.yield() }
        let mute = Task { await media.setMicrophone(false) }
        await Task.yield()
        release?.resume()
        await first.value; await mute.value
        #expect(changes == [true, false])
        #expect(!media.isUpdating)
    }

    @Test func deniedPermissionHasActionableErrorButDoesNotPreventMute() async {
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: { false }, microphoneControl: { changes.append($0) })
        media.phase = .connected
        await media.setMicrophone(true)
        #expect(changes.isEmpty)
        #expect(media.problem?.contains("Privacy & Security → Microphone") == true)
        await media.setMicrophone(false)
        #expect(changes == [false])
    }

    @Test func leavingInvalidatesQueuedMicChanges() async {
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: { true }, microphoneControl: { on in
            if !started {
                started = true
                await withCheckedContinuation { release = $0 }
            }
            changes.append(on)
        })
        media.phase = .connected
        let first = Task { await media.setMicrophone(false) }
        while !started { await Task.yield() }
        let unmute = Task { await media.setMicrophone(true) }
        await Task.yield()
        let leave = Task { await media.disconnect() }
        while media.phase != .idle { await Task.yield() }
        release?.resume()
        await first.value; await unmute.value; await leave.value
        #expect(changes == [false])
        #expect(media.phase == .idle)
        #expect(media.problem == nil)
    }
    @Test func leavingWhilePermissionIsPendingNeverStartsCapture() async {
        var requestStarted = false
        var permission: CheckedContinuation<Bool, Never>?
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: {
            requestStarted = true
            return await withCheckedContinuation { permission = $0 }
        }, microphoneControl: { changes.append($0) })
        media.phase = .connected
        let enable = Task { await media.setMicrophone(true) }
        while !requestStarted { await Task.yield() }
        let leave = Task { await media.disconnect() }
        while media.phase != .idle { await Task.yield() }
        permission?.resume(returning: true)
        await enable.value; await leave.value
        #expect(changes.isEmpty)
        #expect(media.phase == .idle)
    }

    @Test func playbackEnvelopesAreIndependentAndDisconnectCancelsRamp() async {
        let room = MediaSession(), doorstep = MediaSession()
        room.fadePlayback(to: 1, duration: 0)
        doorstep.fadePlayback(to: 0.15, duration: 0)
        #expect(room.playbackGain == 1)
        #expect(doorstep.playbackGain == 0.15)
        doorstep.fadePlayback(to: 1, duration: 0.05)
        await doorstep.disconnect()
        try? await Task.sleep(for: .milliseconds(70))
        #expect(doorstep.playbackGain == 0)
        #expect(room.playbackGain == 1)
    }
    @Test func failedPrivacySetupBlocksCaptureButAllowsMuteAndRetry() async {
        var setupFails = true
        var changes: [Bool] = []
        let media = MediaSession(microphoneAccess: { true }, microphoneControl: { changes.append($0) },
            microphonePrivacySetup: {
                if setupFails { throw MediaSession.MediaFailure.unavailable }
            })
        media.phase = .connected
        await media.setMicrophone(true)
        #expect(changes.isEmpty)
        #expect(media.problem?.contains("couldn’t start safely") == true)
        await media.setMicrophone(false)
        #expect(changes == [false])
        setupFails = false
        await media.setMicrophone(true)
        #expect(changes == [false, true])
        #expect(media.problem == nil)
    }
}
