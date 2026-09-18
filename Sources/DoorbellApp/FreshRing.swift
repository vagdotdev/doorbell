import AppKit
import CryptoKit
import Foundation

/// Fresh Ring checks once per launch. Only the installed app may update itself.
/// A cached update is verified again before a preflight helper asks us to quit.
@MainActor
final class FreshRing: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, downloading, ready, applying, upToDate
        case failed(String)
    }
    struct Network {
        var data: @MainActor (URLRequest) async throws -> (Data, URLResponse)
        var download: @MainActor (URLRequest) async throws -> (URL, URLResponse)
        static var live: Network {
            Network(data: { try await URLSession.shared.data(for: $0) },
                    download: { try await URLSession.shared.download(for: $0) })
        }
    }
    struct InstallerHandle {
        var isRunning: @MainActor () -> Bool
        var terminate: @MainActor () -> Void
        var waitForTermination: @MainActor () async -> Bool
    }
    /// The process boundary is injectable so lifecycle tests never close a user app.
    struct Installation {
        var launch: @MainActor (_ script: URL, _ arguments: [String], _ log: URL) throws -> InstallerHandle
        var quit: @MainActor () -> Void
        var wait: @MainActor () async throws -> Void
        static var live: Installation {
            Installation(launch: { script, arguments, log in
                guard FileManager.default.isExecutableFile(atPath: script.path) else { throw UpdateFailure.installerMissing }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [script.path] + arguments
                _ = FileManager.default.createFile(atPath: log.path, contents: nil)
                let output = try FileHandle(forWritingTo: log)
                defer { try? output.close() }
                process.standardOutput = output
                process.standardError = output
                try process.run()
                return InstallerHandle(isRunning: { process.isRunning }, terminate: { process.terminate() }, waitForTermination: {
                    for _ in 0..<100 {
                        if !process.isRunning { return true }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    return !process.isRunning
                })
            }, quit: { NSApp.terminate(nil) }, wait: { try await Task.sleep(for: .milliseconds(250)) })
        }
    }
    private struct PendingUpdate: Codable, Equatable {
        let tag: String
        let digest: String
    }
    private struct ReleaseInfo {
        let tag: String
        let dmgURL: URL
        let checksumURL: URL
    }
    private struct GitHubRelease: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }

    static let shared = FreshRing()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latestTag: String?
    @Published private(set) var isBusyNow = false
    private(set) var checkedThisLaunch = false
    let currentVersion: String
    private let repo: String
    private let bundleURL: URL
    private let directory: URL
    private let profile: String
    private let environment: [String: String]
    private let network: Network
    private let installation: Installation
    private let enabled: @MainActor () -> Bool
    private var isBusy: @MainActor () -> Bool = { false }
    private var task: Task<Void, Never>?
    private var taskIsAutomatic = false
    private var stoppingInstaller: InstallerHandle?
    private var isInstallerStopping: Bool { stoppingInstaller?.isRunning() == true }

    private convenience init() {
        self.init(currentVersion: Bundle.main.infoDictionary?["DoorbellReleaseTag"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    init(currentVersion: String, repo: String = "vagdotdev/doorbell",
         bundleURL: URL = Bundle.main.bundleURL, updatesDirectory: URL? = nil,
         profile: String = AppConfig.current.profile, environment: [String: String] = ProcessInfo.processInfo.environment,
         network: Network = .live, installation: Installation = .live, enabled: @escaping @MainActor () -> Bool = { FreshRing.isEnabled }) {
        self.currentVersion = currentVersion
        self.repo = repo
        self.bundleURL = bundleURL
        self.profile = profile
        self.environment = environment
        self.directory = updatesDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doorbell/updates", isDirectory: true)
        self.network = network
        self.installation = installation
        self.enabled = enabled
    }

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: SettingsKey.freshRing) != nil {
            return UserDefaults.standard.bool(forKey: SettingsKey.freshRing)
        }
        return UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
    }
    var unavailableReason: String? {
        guard Self.canUpdateInPlace(bundleURL: bundleURL) else { return "Install Doorbell in Applications to use Fresh Ring." }
        guard profile == "default" else { return "Fresh Ring runs from your main Doorbell profile. Open that profile to update." }
        guard environment["DOORBELL_SNAPSHOT"] == nil, environment["XCTestConfigurationFilePath"] == nil,
              !environment.keys.contains(where: { $0.hasPrefix("DOORBELL_") && $0.contains("_TEST") }) else {
            return "Fresh Ring is paused for this test or preview session."
        }
        return nil
    }
    var supportsAutomaticUpdates: Bool { unavailableReason == nil }
    var canInstallNow: Bool { supportsAutomaticUpdates && phase == .ready && !isBusyNow && !isInstallerStopping }
    var canCheck: Bool { supportsAutomaticUpdates && task == nil && !isInstallerStopping }

    func registerBusyCheck(_ check: @escaping @MainActor () -> Bool) {
        isBusy = check
        refreshBusyState()
    }
    func refreshBusyState() { isBusyNow = isBusy() }

    func checkOnLaunch() {
        guard !checkedThisLaunch, task == nil else { return }
        checkedThisLaunch = true
        guard supportsAutomaticUpdates, enabled() else { return }
        startCheck(automatic: true)
    }
    func checkAgain() {
        guard canCheck else { return }
        startCheck(automatic: false)
    }
    func preferenceChanged() {
        if !enabled(), taskIsAutomatic { task?.cancel() }
        if enabled() { installIfReady() }
    }
    func installNow() {
        refreshBusyState()
        guard supportsAutomaticUpdates, task == nil, phase == .ready, !isBusyNow, !isInstallerStopping else { return }
        taskIsAutomatic = false
        task = Task { [self] in
            defer { task = nil }
            await applyPending(automatic: false)
        }
    }
    func installIfReady() {
        refreshBusyState()
        guard supportsAutomaticUpdates, task == nil, phase == .ready, enabled(), !isBusyNow, !isInstallerStopping else { return }
        taskIsAutomatic = true
        task = Task { [self] in
            defer { task = nil; taskIsAutomatic = false }
            await applyPending(automatic: true)
        }
    }
    private func startCheck(automatic: Bool) {
        taskIsAutomatic = automatic
        task = Task { [self] in
            defer { task = nil; taskIsAutomatic = false }
            await runCheck(automatic: automatic)
        }
    }

    private func runCheck(automatic: Bool) async {
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            try Task.checkCancellation()
            latestTag = release.tag
            guard releaseIsNewer(release.tag, than: currentVersion) else { phase = .upToDate; return }
            if let pending = try? verifiedPending(), pending.tag == release.tag {
                phase = .ready
            } else {
                phase = .downloading
                try await download(release: release)
                try Task.checkCancellation()
                phase = .ready
            }
            if automatic, let pending = try? verifiedPending(), isQuarantined(pending) {
                phase = .failed(Self.quarantineMessage)
                return
            }
            refreshBusyState()
            if automatic, enabled(), !isBusyNow { await applyPending(automatic: true) }
        } catch is CancellationError {
            restoreReadyOrIdle()
        } catch {
            // A verified download survives a restart and an offline release feed.
            // Keep it queued for an explicit retry; never silently install on error.
            if let pending = try? verifiedPending(), releaseIsNewer(pending.tag, than: currentVersion) {
                latestTag = pending.tag
                phase = automatic && isQuarantined(pending) ? .failed(Self.quarantineMessage) : .ready
            } else { phase = .failed(friendly(error)) }
        }
    }

    private func applyPending(automatic: Bool) async {
        refreshBusyState()
        guard supportsAutomaticUpdates, !isBusyNow, !automatic || enabled() else { phase = .ready; return }
        var installer: InstallerHandle?
        let ready = directory.appendingPathComponent("ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        do {
            try Task.checkCancellation()
            let pending = try verifiedPending()
            guard releaseIsNewer(pending.tag, than: currentVersion) else { phase = .upToDate; return }
            if automatic, isQuarantined(pending) { phase = .failed(Self.quarantineMessage); return }
            let script = bundleURL.appendingPathComponent("Contents/Resources/scripts/apply-update.sh")
            phase = .applying
            installer = try installation.launch(script, [pendingDMG.path, String(ProcessInfo.processInfo.processIdentifier),
                bundleURL.path, pending.digest, ready.path, pending.tag], directory.appendingPathComponent("installer.log"))
            for _ in 0..<120 {
                try Task.checkCancellation()
                guard installer?.isRunning() == true else { throw UpdateFailure.installerRejected }
                if FileManager.default.fileExists(atPath: ready.path) {
                    refreshBusyState()
                    guard !isBusyNow, !automatic || enabled() else {
                        if await stopInstaller(installer) { phase = .ready }
                        return
                    }
                    installation.quit()
                    return
                }
                try await installation.wait()
            }
            throw UpdateFailure.installerRejected
        } catch is CancellationError {
            if await stopInstaller(installer) { restoreReadyOrIdle() }
        } catch {
            if await stopInstaller(installer) { phase = .failed(friendly(error)) }
        }
    }

    private func stopInstaller(_ installer: InstallerHandle?) async -> Bool {
        guard let installer, installer.isRunning() else { return true }
        installer.terminate()
        // Cancellation must not cancel the cleanup wait itself. The helper removes
        // its provisional quarantine in EXIT, before its process terminates.
        let cleanup = Task { @MainActor in await installer.waitForTermination() }
        let completed = await cleanup.value
        if completed || !installer.isRunning() { stoppingInstaller = nil; return true }
        stoppingInstaller = installer
        phase = .failed("The update is still stopping. Your app is open. Retry after the installer finishes.")
        return false
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await network.data(request)
        try Self.checkResponse(response)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard releaseTimestamp(release.tag_name) != nil,
              let dmg = release.assets.first(where: { $0.name == "Doorbell.dmg" }),
              let checksum = release.assets.first(where: { $0.name == "Doorbell.dmg.sha256" }),
              let dmgURL = URL(string: dmg.browser_download_url),
              let checksumURL = URL(string: checksum.browser_download_url),
              Self.isOfficialAsset(dmgURL, repo: repo, tag: release.tag_name, name: "Doorbell.dmg"),
              Self.isOfficialAsset(checksumURL, repo: repo, tag: release.tag_name, name: "Doorbell.dmg.sha256") else { throw URLError(.resourceUnavailable) }
        return ReleaseInfo(tag: release.tag_name, dmgURL: dmgURL, checksumURL: checksumURL)
    }
    private func download(release: ReleaseInfo) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: release.dmgURL)
        request.timeoutInterval = 600
        let (tmp, response) = try await network.download(request)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.checkResponse(response)
        var checksumRequest = URLRequest(url: release.checksumURL)
        checksumRequest.timeoutInterval = 30
        let (data, checksumResponse) = try await network.data(checksumRequest)
        try Self.checkResponse(checksumResponse)
        guard let digest = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw URLError(.cannotDecodeContentData)
        }
        try Self.verify(dmg: tmp, expected: digest)
        try Task.checkCancellation()
        let record = PendingUpdate(tag: release.tag, digest: digest.lowercased())
        // A crash between these operations leaves a mismatched cache, which the
        // next verification rejects. No path alone can authorize installation.
        try? FileManager.default.removeItem(at: pendingDMG)
        try FileManager.default.moveItem(at: tmp, to: pendingDMG)
        try JSONEncoder().encode(record).write(to: manifest, options: .atomic)
        // A different verified candidate gets its own attempt. Redownloading the
        // same failed bytes must not clear the automatic-retry quarantine.
        if let failed = try? JSONDecoder().decode(PendingUpdate.self, from: Data(contentsOf: quarantine)), failed != record {
            try? FileManager.default.removeItem(at: quarantine)
        }
    }
    private func verifiedPending() throws -> PendingUpdate {
        let record = try JSONDecoder().decode(PendingUpdate.self, from: Data(contentsOf: manifest))
        try Self.verify(dmg: pendingDMG, expected: record.digest)
        return record
    }
    private static let quarantineMessage = "The last update attempt failed. Automatic retry is paused. Check again, then restart to retry manually."
    private func isQuarantined(_ pending: PendingUpdate) -> Bool {
        guard let failed = try? JSONDecoder().decode(PendingUpdate.self, from: Data(contentsOf: quarantine)) else { return false }
        return failed == pending
    }
    private func restoreReadyOrIdle() {
        if let pending = try? verifiedPending(), releaseIsNewer(pending.tag, than: currentVersion) {
            latestTag = pending.tag; phase = isQuarantined(pending) ? .failed(Self.quarantineMessage) : .ready
        } else { phase = .idle }
    }
    private var pendingDMG: URL { directory.appendingPathComponent("Doorbell.pending.dmg") }
    private var manifest: URL { directory.appendingPathComponent("Doorbell.pending.json") }
    private var quarantine: URL { directory.appendingPathComponent("Doorbell.failed.json") }

    static func canUpdateInPlace(bundleURL: URL) -> Bool {
        let installed = "/Applications/Doorbell.app"
        return bundleURL.standardizedFileURL.path == installed && bundleURL.resolvingSymlinksInPath().path == installed
    }
    static func isOfficialAsset(_ url: URL, repo: String, tag: String, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && url.path == "/\(repo)/releases/download/\(tag)/\(name)"
    }
    private static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let url = response.url, url.scheme == "https", let host = url.host,
              ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) else {
            throw URLError(.badServerResponse)
        }
    }
    static func verify(dmg: URL, expected: String) throws {
        guard expected.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
            throw URLError(.cannotDecodeContentData)
        }
        let handle = try FileHandle(forReadingFrom: dmg)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else { throw URLError(.cannotDecodeContentData) }
    }
    static func installerFailureMessage(log: URL) -> String {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        if text.contains("Developer ID signed installation") {
            return "This installer uses an older distribution policy. Run the official Doorbell installer once; your current app is still open."
        }
        if text.contains("not approved by macOS") {
            return "macOS rejected this update’s signature policy. Retry with the official Doorbell installer; your current app is still open."
        }
        if text.contains("publisher does not match") {
            return "The update’s publisher doesn’t match this app. The update was blocked and your app is still open."
        }
        if text.contains("different account database") || text.contains("changes the account service") {
            return "The update points to a different account service. It was blocked to protect your login and friends."
        }
        if text.contains("Release version does not match") {
            return "The release contains the wrong app version. Ask for a corrected download; your app is still open."
        }
        if text.contains("Another Doorbell instance") {
            return "Close the other Doorbell instance, then retry the update. This app is still open."
        }
        return "The update didn’t pass installation checks. Your current app is still open."
    }
    private enum UpdateFailure: Error { case installerMissing, installerRejected }
    private func friendly(_ error: Error) -> String {
        if let failure = error as? UpdateFailure {
            switch failure {
            case .installerMissing: return "Fresh Ring’s installer is missing. Download the current app to update."
            case .installerRejected: return Self.installerFailureMessage(log: directory.appendingPathComponent("installer.log"))
            }
        }
        if let url = error as? URLError, url.code == .cannotDecodeContentData {
            return "Download didn’t pass the checksum. Try again."
        }
        return "Couldn’t get the update. Check your connection and retry."
    }
}

/// Release order comes only from the publisher's minute timestamp. A commit
/// hash identifies a build; it is not a version and must never sort as one.
func releaseIsNewer(_ remote: String, than local: String) -> Bool {
    guard let remoteDate = releaseTimestamp(remote) else { return false }
    if let localDate = releaseTimestamp(local) { return remoteDate > localDate }
    return ["0", "0.1", "0.1-dev", "dev"].contains(local)
}

private func releaseTimestamp(_ version: String) -> Date? {
    let pattern = #"^v?([0-9]{4})\.([0-9]{2})\.([0-9]{2})-([0-9]{2})([0-9]{2})-[a-fA-F0-9]{3,40}$"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)) else { return nil }
    let pieces = (1...5).compactMap { index -> Int? in
        guard let range = Range(match.range(at: index), in: version) else { return nil }
        return Int(version[range])
    }
    guard pieces.count == 5, pieces[0] > 0,
          (1...12).contains(pieces[1]), (1...31).contains(pieces[2]),
          (0...23).contains(pieces[3]), (0...59).contains(pieces[4]) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2], hour: pieces[3], minute: pieces[4])
    guard let date = calendar.date(from: components) else { return nil }
    let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    guard [roundTrip.year, roundTrip.month, roundTrip.day, roundTrip.hour, roundTrip.minute] == pieces.map(Optional.some) else { return nil }
    return date
}
