import Foundation

/// Shared by forms and backends. Matches the database's ASCII handle constraint.
enum ProfileValidation {
    static func validHandle(_ value: String) -> Bool {
        (3...20).contains(value.utf8.count) && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }
    static func validName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 60
    }
}
