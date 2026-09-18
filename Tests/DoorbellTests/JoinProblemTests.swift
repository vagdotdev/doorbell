import Foundation
import Testing
@testable import DoorbellApp

/// The Join form never shows backend internals: a taken handle names the handle,
/// everything else is one offline-safe sentence.
struct JoinProblemTests {
    private struct BackendError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Test func takenHandleNamesTheHandle() {
        #expect(joinProblem(handle: "tintin", error: BackendError(message: "That handle is taken.")) == "@tintin is taken")
    }

    @Test func takenMatchIgnoresCase() {
        #expect(joinProblem(handle: "tintin", error: BackendError(message: "TAKEN by someone else")) == "@tintin is taken")
    }

    @Test func anythingElseIsGeneric() {
        #expect(joinProblem(handle: "tintin", error: BackendError(message: "InternalError channel closed")) == "Couldn’t connect. Try again in a moment.")
        #expect(joinProblem(handle: "tintin", error: BackendError(message: "You already have a handle.")) == "Couldn’t connect. Try again in a moment.")
    }
}
