import Foundation

/// A wall-clock deadline survives relaunch, updates and sleep without renewing.
struct QuietPeriod {
    static let duration: TimeInterval = 6 * 60 * 60
    let defaults: UserDefaults

    func restore(at now: Date) -> Date? {
        guard defaults.bool(forKey: SettingsKey.quiet) else {
            defaults.removeObject(forKey: SettingsKey.quietUntil)
            return nil
        }
        guard let saved = defaults.object(forKey: SettingsKey.quietUntil) as? Double else {
            // Migrate an existing indefinite Quiet Door once.
            return set(true, at: now)
        }
        guard saved.isFinite, saved > now.timeIntervalSince1970 else {
            return set(false, at: now)
        }
        // A clock rollback must not leave a door quiet indefinitely.
        let until = min(Date(timeIntervalSince1970: saved), now.addingTimeInterval(Self.duration))
        defaults.set(until.timeIntervalSince1970, forKey: SettingsKey.quietUntil)
        return until
    }

    @discardableResult func set(_ enabled: Bool, at now: Date) -> Date? {
        let until = enabled ? now.addingTimeInterval(Self.duration) : nil
        defaults.set(enabled, forKey: SettingsKey.quiet)
        if let until { defaults.set(until.timeIntervalSince1970, forKey: SettingsKey.quietUntil) }
        else { defaults.removeObject(forKey: SettingsKey.quietUntil) }
        return until
    }
}
