import Foundation

/// A callback can act only while it belongs to the current user operation.
@MainActor
final class OperationGeneration {
    private(set) var current: UInt64 = 0
    @discardableResult func advance() -> UInt64 { current &+= 1; return current }
    func isCurrent(_ ticket: UInt64) -> Bool { ticket == current }
    func check(_ ticket: UInt64) throws {
        try Task.checkCancellation()
        guard isCurrent(ticket) else { throw CancellationError() }
    }
}
