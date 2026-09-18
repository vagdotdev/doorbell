import Testing
@testable import DoorbellApp

@MainActor struct CameraFeedTests {
    @Test func closingPreviewBeforePermissionResolvesNeverStartsCamera() async {
        var permission: CheckedContinuation<Bool, Never>?
        var starts = 0
        let feed = CameraFeed(cameraAccess: {
            await withCheckedContinuation { permission = $0 }
        }, captureStart: { starts += 1; return true }, captureStop: {})
        feed.retain()
        let start = feed.startTask
        while permission == nil { await Task.yield() }
        feed.release()
        permission?.resume(returning: true)
        await start?.value
        #expect(starts == 0)
        #expect(feed.status == .idle)
    }

    @Test func oldPermissionResultCannotStartOrOverrideNewPreview() async {
        var permissions: [CheckedContinuation<Bool, Never>] = []
        var starts = 0
        let feed = CameraFeed(cameraAccess: {
            await withCheckedContinuation { permissions.append($0) }
        }, captureStart: { starts += 1; return true }, captureStop: {})
        feed.retain()
        let oldStart = feed.startTask
        while permissions.count < 1 { await Task.yield() }
        feed.release()
        feed.retain()
        while permissions.count < 2 { await Task.yield() }
        permissions[1].resume(returning: true)
        while feed.status != .running { await Task.yield() }
        permissions[0].resume(returning: false)
        await oldStart?.value
        #expect(starts == 1)
        #expect(feed.status == .running)
        feed.release()
    }
}
