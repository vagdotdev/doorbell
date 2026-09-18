import Foundation
import Testing
@testable import DoorbellApp

struct AppConfigTests {
    @Test func installedAppCannotReadWorkingDirectoryOrBundledLocalOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cwd = root.appendingPathComponent("cwd"), resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "CONVEX_URL=http://127.0.0.1:3210\nADMIN_SECRET=private".write(to: cwd.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "CONVEX_URL=https://release.convex.cloud\nDOORBELL_BACKEND=convex".write(to: resources.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "ADMIN_SECRET=also-private".write(to: resources.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        let release = AppConfig.resolvedValues(environment: [:], workingDirectory: cwd, resources: resources, bundled: true)
        #expect(release["CONVEX_URL"] == "https://release.convex.cloud")
        #expect(release["ADMIN_SECRET"] == nil)
        let development = AppConfig.resolvedValues(environment: [:], workingDirectory: cwd, resources: resources, bundled: false)
        #expect(development["CONVEX_URL"] == "http://127.0.0.1:3210")
        let explicit = AppConfig.resolvedValues(environment: ["DOORBELL_PROFILE": "alice"], workingDirectory: cwd, resources: resources, bundled: true)
        #expect(explicit["DOORBELL_PROFILE"] == "alice")
        #expect(explicit["DOORBELL_BACKEND"] == "convex")
        let polluted = AppConfig.resolvedValues(environment: ["CONVEX_URL": "http://127.0.0.1:3210"], workingDirectory: cwd, resources: resources, bundled: true)
        #expect(polluted["CONVEX_URL"] == "https://release.convex.cloud")
    }
    @Test func upgradePreservesLegacySessionWithMissingOrEquivalentDeploymentMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("convex-session.json")
        let marker = root.appendingPathComponent("convex-url.txt")
        let saved = Data("test-legacy-session".utf8)
        try saved.write(to: session)
        let url = URL(string: "https://release.convex.cloud")!
        AppConfig.prepareLegacySession(for: url, directory: root)
        #expect(try Data(contentsOf: session) == saved)
        try "https://RELEASE.convex.cloud:443/\n".write(to: marker, atomically: true, encoding: .utf8)
        AppConfig.prepareLegacySession(for: url, directory: root)
        #expect(try Data(contentsOf: session) == saved)
        #expect(try String(contentsOf: marker, encoding: .utf8) == url.absoluteString)
        AppConfig.prepareLegacySession(for: URL(string: "https://different.convex.cloud")!, directory: root)
        #expect(!FileManager.default.fileExists(atPath: session.path))
    }

}
