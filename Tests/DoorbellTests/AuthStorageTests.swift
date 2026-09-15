import Foundation
import Testing
@testable import DoorbellApp

struct AuthStorageTests {
    @Test func legacySessionMigratesOnceAndSignOutRemovesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = MigratingAuthStorage(directory: folder, profile: "test-\(UUID())")
        let key = "session"
        defer { try? storage.remove(key: key) }
        let legacy = folder.appendingPathComponent("session.json")
        let first = Data("local-test-session".utf8)
        try first.write(to: legacy)
        #expect(try storage.retrieve(key: key) == first)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let updated = Data("updated-test-session".utf8)
        try storage.store(key: key, value: updated)
        #expect(try storage.retrieve(key: key) == updated)
        try storage.remove(key: key)
        #expect(try storage.retrieve(key: key) == nil)
    }
}
