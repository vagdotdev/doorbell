import Foundation
import Testing
@testable import DoorbellApp

struct QuietPeriodTests {
    private func withStore(_ test: (QuietPeriod) throws -> Void) rethrows {
        let name = "Doorbell.QuietTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(QuietPeriod(defaults: defaults))
    }

    @Test func restartPreservesDeadlineAndSleepExpiresIt() {
        withStore { store in
            let start = Date(timeIntervalSince1970: 1_000_000)
            let deadline = store.set(true, at: start)
            #expect(deadline == start.addingTimeInterval(21_600))
            let relaunched = QuietPeriod(defaults: store.defaults)
            #expect(relaunched.restore(at: start.addingTimeInterval(3_600)) == deadline)
            #expect(relaunched.restore(at: start.addingTimeInterval(21_599)) == deadline)
            #expect(relaunched.restore(at: start.addingTimeInterval(21_600)) == nil)
            #expect(!store.defaults.bool(forKey: SettingsKey.quiet))
            #expect(relaunched.restore(at: start.addingTimeInterval(30_000)) == nil)
        }
    }

    @Test func earlyOffAndLegacyMigration() {
        withStore { store in
            let now = Date()
            #expect(store.restore(at: now) == nil)
            store.defaults.set(true, forKey: SettingsKey.quiet)
            let deadline = store.restore(at: now)
            #expect(deadline == now.addingTimeInterval(21_600))
            #expect(store.restore(at: now.addingTimeInterval(1)) == deadline)
            store.set(false, at: now)
            #expect(store.restore(at: now) == nil)
            #expect(store.defaults.object(forKey: SettingsKey.quietUntil) == nil)
            #expect(store.set(true, at: now.addingTimeInterval(10)) == now.addingTimeInterval(21_610))
        }
    }

    @Test func clockRollbackCapsRemainingQuietAtSixHours() {
        withStore { store in
            let now = Date()
            store.set(true, at: now)
            let past = now.addingTimeInterval(-86_400)
            #expect(store.restore(at: past) == past.addingTimeInterval(21_600))
        }
    }
}
