import Foundation
import Testing
@testable import DoorbellApp

@MainActor struct OperationGenerationTests {
    @Test func invalidatedCallbackCannotAct() throws {
        let generation = OperationGeneration()
        let first = generation.advance()
        try generation.check(first)
        generation.advance()
        #expect(throws: CancellationError.self) { try generation.check(first) }
        try generation.check(generation.current)
    }
}
