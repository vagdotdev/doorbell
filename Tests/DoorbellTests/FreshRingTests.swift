import Foundation
import CryptoKit
import Testing
@testable import DoorbellApp

@MainActor private final class UpdateFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-ring-\(UUID().uuidString)")
    var downloads = 0
    var offline = false
    var badDigest = false
    var downloadStatus = 200
    var busy = true
    var automaticEnabled = false
    var launches = 0
    var quits = 0
    var terminations = 0
    var terminationCompletions = 0
    var terminationFinishes = true
    var provisionalQuarantine = false
    var running = true
    var readyOnLaunch = true
    var simulateRollback = false
    var rejectionLog: String?
    var onWait: (() -> Void)?
    var readyURL: URL?
    let bytes = Data("verified update fixture".utf8)
    var tag = "v2026.09.19-1200-abc"
    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func makeRing(bundlePath: String = "/Applications/Doorbell.app", enabled: Bool = false) -> FreshRing {
        automaticEnabled = enabled
        let network = FreshRing.Network(data: { [self] request in
            if offline { throw URLError(.notConnectedToInternet) }
            let data: Data
            if request.url!.path.hasSuffix("/latest") {
                data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "assets": [
                    ["name": "Doorbell.dmg", "browser_download_url": "https://github.com/vagdotdev/doorbell/releases/download/\(tag)/Doorbell.dmg"],
                    ["name": "Doorbell.dmg.sha256", "browser_download_url": "https://github.com/vagdotdev/doorbell/releases/download/\(tag)/Doorbell.dmg.sha256"]
                ]])
            } else {
                let digest = badDigest ? String(repeating: "0", count: 64)
                    : SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                data = Data("\(digest)  Doorbell.dmg\n".utf8)
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, download: { [self] request in
            downloads += 1
            let file = directory.appendingPathComponent("download-\(UUID().uuidString)")
            try bytes.write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: downloadStatus, httpVersion: nil, headerFields: nil)!)
        })
        let installation = FreshRing.Installation(launch: { [self] _, arguments, log in
            launches += 1
            readyURL = URL(fileURLWithPath: arguments[4])
            if let rejectionLog { try rejectionLog.write(to: log, atomically: true, encoding: .utf8) }
            if simulateRollback || provisionalQuarantine {
                let pending = try Data(contentsOf: directory.appendingPathComponent("Doorbell.pending.json"))
                try pending.write(to: directory.appendingPathComponent("Doorbell.failed.json"), options: .atomic)
            }
            if readyOnLaunch { makeReady() }
            return FreshRing.InstallerHandle(isRunning: { [self] in running }, terminate: { [self] in
                terminations += 1
            }, waitForTermination: { [self] in
                await Task.yield() // Child EXIT cleanup is later than the signal.
                guard terminationFinishes else { return false }
                if provisionalQuarantine {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("Doorbell.failed.json"))
                }
                running = false
                terminationCompletions += 1
                return true
            })
        }, quit: { [self] in quits += 1 }, wait: { [self] in
            onWait?()
            await Task.yield()
        })
        let ring = FreshRing(currentVersion: "v2026.09.18-2213-def", bundleURL: URL(fileURLWithPath: bundlePath),
                             updatesDirectory: directory, profile: "default", environment: [:], network: network,
                             installation: installation, enabled: { [self] in automaticEnabled })
        // Even handoff tests use only callbacks and temporary files: never a real
        // process launcher, installed bundle replacement, or NSApp.terminate.
        ring.registerBusyCheck { [self] in busy }
        return ring
    }
    func makeReady() {
        if let readyURL { _ = FileManager.default.createFile(atPath: readyURL.path, contents: Data()) }
    }
}

@MainActor struct FreshRingTests {
    private func settled(_ ring: FreshRing) async -> Bool {
        for _ in 0..<100 {
            if !ring.canCheck { try? await Task.sleep(for: .milliseconds(10)); continue }
            if ring.phase == .ready || ring.phase == .upToDate { return true }
            if case .failed = ring.phase { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    @Test func newerReleaseTagsWin() {
        #expect(releaseIsNewer("v2026.09.19-1200-abc", than: "v2026.09.18-2213-def"))
        #expect(!releaseIsNewer("v2026.09.18-2213-def", than: "v2026.09.18-2213-def"))
        #expect(!releaseIsNewer("v2026.09.18-2213-def", than: "v2026.09.19-1200-abc"))
    }
    @Test func sameMinuteHashesAndMalformedVersionsNeverTriggerDowngrade() {
        #expect(!releaseIsNewer("v2026.09.19-1200-fff", than: "v2026.09.19-1200-aaa"))
        #expect(!releaseIsNewer("v2026.09.19-1200-aaa", than: "v2026.09.19-1200-fff"))
        #expect(releaseIsNewer("v2026.09.19-1201-aaa", than: "v2026.09.19-1200-fff"))
        for malformed in ["garbage", "v99999.01.01-0000-abc", "v2026.13.01-0000-abc",
                          "v2026.02.30-0000-abc", "v2026.09.19-2460-abc", "v2026.09.19-1200-dev",
                          "v2026.9.19-1200-abc", "v2026.09.19-1200-abc extra"] {
            #expect(!releaseIsNewer(malformed, than: "0.1-dev"))
        }
        #expect(releaseIsNewer("v2024.02.29-1200-abc", than: "0.1-dev"))
        #expect(releaseIsNewer("v2026.09.19-1200-abc", than: "0.1"))
        #expect(!releaseIsNewer("v2025.02.29-1200-abc", than: "0.1-dev"))
        #expect(!releaseIsNewer("v2026.09.19-1200-abc", than: "unknown-version"))
    }
    @Test func checkOnceAndDisabledPreferenceDoNotStartNetwork() throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        let ring = fixture.makeRing()
        ring.checkOnLaunch(); ring.checkOnLaunch()
        #expect(ring.checkedThisLaunch && ring.phase == .idle)
        #expect(fixture.downloads == 0)
    }
    @Test func manualCheckWorksWithAutoOffAndProducesVerifiedPendingUpdate() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        let ring = fixture.makeRing()
        ring.checkAgain()
        #expect(await settled(ring))
        #expect(ring.phase == .ready && ring.latestTag == fixture.tag)
        #expect(fixture.downloads == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Doorbell.pending.json").path))
        ring.installNow()
        #expect(ring.phase == .ready && !ring.canInstallNow) // busy rejects even manual restart
    }
    @Test func corruptChecksumAndHTTPFailureNeverBecomeReady() async throws {
        for badChecksum in [true, false] {
            let fixture = try UpdateFixture(); defer { fixture.cleanup() }
            fixture.badDigest = badChecksum
            fixture.downloadStatus = badChecksum ? 200 : 503
            let ring = fixture.makeRing()
            ring.checkAgain()
            #expect(await settled(ring))
            guard case .failed = ring.phase else { Issue.record("Invalid download became installable"); continue }
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Doorbell.pending.json").path))
        }
    }
    @Test func verifiedPendingSurvivesRestartAndOfflineFeedButTamperedCacheDoesNot() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        let first = fixture.makeRing()
        first.checkAgain(); #expect(await settled(first)); #expect(first.phase == .ready)
        fixture.offline = true
        let restarted = fixture.makeRing()
        restarted.checkAgain(); #expect(await settled(restarted)); #expect(restarted.phase == .ready)
        try Data("tampered".utf8).write(to: fixture.directory.appendingPathComponent("Doorbell.pending.dmg"))
        let tampered = fixture.makeRing()
        tampered.checkAgain(); #expect(await settled(tampered))
        guard case .failed = tampered.phase else { Issue.record("Tampered cache accepted"); return }
    }
    @Test func previewBuildCannotCheckOrReplaceInstalledApp() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        let ring = fixture.makeRing(bundlePath: "/tmp/Doorbell.app", enabled: true)
        ring.checkOnLaunch(); ring.checkAgain(); ring.installNow()
        #expect(!ring.supportsAutomaticUpdates && ring.phase == .idle && fixture.downloads == 0)
        #expect(!FreshRing.canUpdateInPlace(bundleURL: URL(fileURLWithPath: "/Applications/Doorbell Preview.app")))
    }
    @Test func failedCandidateCannotRestartLoopAcrossTwoRelaunchesAndExplicitRetryIsAllowed() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        fixture.busy = false; fixture.simulateRollback = true
        let first = fixture.makeRing(enabled: true)
        first.checkOnLaunch()
        #expect(await eventually { fixture.quits == 1 })
        for _ in 0..<2 {
            let relaunched = fixture.makeRing(enabled: true)
            relaunched.checkOnLaunch()
            #expect(await settled(relaunched))
            guard case .failed(let message) = relaunched.phase else { Issue.record("Failed update attempted automatically again"); return }
            #expect(message.contains("Automatic retry is paused"))
            relaunched.installIfReady()
            #expect(fixture.launches == 1 && fixture.quits == 1)
        }
        let explicitRetry = fixture.makeRing(enabled: true)
        explicitRetry.checkAgain()
        #expect(await settled(explicitRetry)); #expect(explicitRetry.phase == .ready)
        // An automatic idle callback still cannot apply an explicitly checked,
        // quarantined download without the separate manual Restart action.
        explicitRetry.installIfReady()
        #expect(await eventually { if case .failed = explicitRetry.phase { return true }; return false })
        #expect(fixture.launches == 1)
        explicitRetry.checkAgain(); #expect(await settled(explicitRetry))
        fixture.simulateRollback = false
        explicitRetry.installNow()
        #expect(await eventually { fixture.quits == 2 })
    }

    @Test func aDifferentVerifiedReleaseClearsPriorQuarantine() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        let initial = fixture.makeRing()
        initial.checkAgain(); #expect(await settled(initial))
        let pending = try Data(contentsOf: fixture.directory.appendingPathComponent("Doorbell.pending.json"))
        try pending.write(to: fixture.directory.appendingPathComponent("Doorbell.failed.json"))
        fixture.tag = "v2026.09.20-1200-abc"
        let newer = fixture.makeRing(enabled: true)
        newer.checkOnLaunch(); #expect(await settled(newer))
        #expect(newer.phase == .ready)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Doorbell.failed.json").path))
    }

    @Test func readySignalAfterCallStartsDoesNotQuit() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        fixture.busy = false; fixture.readyOnLaunch = false; fixture.provisionalQuarantine = true
        fixture.onWait = { fixture.busy = true; fixture.makeReady() }
        let ring = fixture.makeRing()
        ring.checkAgain(); #expect(await settled(ring))
        ring.installNow()
        #expect(await eventually { fixture.terminationCompletions == 1 && ring.canCheck })
        #expect(fixture.quits == 0 && ring.phase == .ready)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Doorbell.failed.json").path))
    }

    @Test func disablingAutomaticUpdatesDuringPreflightDoesNotQuit() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        fixture.busy = false; fixture.readyOnLaunch = false; fixture.provisionalQuarantine = true
        let ring = fixture.makeRing(enabled: true)
        fixture.onWait = {
            fixture.automaticEnabled = false
            ring.preferenceChanged()
            fixture.makeReady()
        }
        ring.checkOnLaunch()
        #expect(await eventually { fixture.terminationCompletions == 1 && ring.canCheck })
        #expect(fixture.quits == 0 && ring.phase == .ready)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Doorbell.failed.json").path))
    }

    @Test func failedInstallerLeavesCurrentAppOpenAndExplainsLegacyInstallerPolicy() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        fixture.busy = false; fixture.readyOnLaunch = false; fixture.running = false
        fixture.rejectionLog = "Automatic updates require a Developer ID signed installation. Install the signed release manually once."
        let ring = fixture.makeRing()
        ring.checkAgain(); #expect(await settled(ring))
        ring.installNow()
        #expect(await eventually { if case .failed = ring.phase { return true }; return false })
        guard case .failed(let message) = ring.phase else { return }
        #expect(message.contains("official Doorbell installer once"))
        #expect(fixture.quits == 0)
    }

    @Test func successfulIdlePreflightCallsQuitExactlyOnce() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        fixture.busy = false
        let ring = fixture.makeRing()
        ring.checkAgain(); #expect(await settled(ring))
        ring.installNow()
        #expect(await eventually { fixture.quits == 1 })
        #expect(fixture.launches == 1 && fixture.terminations == 0)
    }
    @Test func slowInstallerShutdownBlocksOverlappingRetryUntilItExits() async throws {
        let fixture = try UpdateFixture(); defer { fixture.cleanup() }
        fixture.busy = false; fixture.readyOnLaunch = false
        fixture.terminationFinishes = false; fixture.provisionalQuarantine = true
        fixture.onWait = { fixture.busy = true; fixture.makeReady() }
        let ring = fixture.makeRing()
        ring.checkAgain(); #expect(await settled(ring))
        ring.installNow()
        #expect(await eventually { if case .failed = ring.phase { return true }; return false })
        guard case .failed(let message) = ring.phase else { return }
        #expect(message.contains("still stopping"))
        #expect(!ring.canCheck && !ring.canInstallNow && fixture.quits == 0)
        fixture.busy = false
        ring.checkAgain(); ring.installNow()
        #expect(fixture.launches == 1)
        fixture.running = false // Eventual child exit releases the retry guard.
        #expect(ring.canCheck)
    }
    @Test func betaAssetsMustBelongToExactOfficialRelease() {
        let repo = "vagdotdev/doorbell", tag = "v2026.09.19-1200-abc", name = "Doorbell.dmg"
        let base = "https://github.com/\(repo)/releases/download/\(tag)/\(name)"
        #expect(FreshRing.isOfficialAsset(URL(string: base)!, repo: repo, tag: tag, name: name))
        for bad in [base.replacingOccurrences(of: "https:", with: "http:"),
                    base.replacingOccurrences(of: "github.com", with: "github.com.evil.test"),
                    base.replacingOccurrences(of: "vagdotdev/doorbell", with: "someone/doorbell"),
                    base.replacingOccurrences(of: tag, with: "v2026.09.18-1200-abc"),
                    base + "?other=1", base + "#other", base.replacingOccurrences(of: "github.com", with: "name@github.com")] {
            #expect(!FreshRing.isOfficialAsset(URL(string: bad)!, repo: repo, tag: tag, name: name))
        }
    }
}
