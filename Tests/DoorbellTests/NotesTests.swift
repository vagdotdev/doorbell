import Foundation
import Testing
@testable import DoorbellApp

@MainActor
struct NotesTests {
    @Test func wavHeaderIs16kMonoPcm() {
        let pcm = Data(repeating: 0, count: 32)
        let wav = NotesAudio.wav(pcm)
        #expect(wav.count == 76)
        #expect(String(bytes: wav[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(bytes: wav[8..<12], encoding: .ascii) == "WAVE")
        #expect(wav[22] == 1)
        #expect(wav[24] == 0x80 && wav[25] == 0x3E)
        #expect(String(bytes: wav[36..<40], encoding: .ascii) == "data")
    }

    @Test func startingNotesOpensTheDrawerAndStoppingWrites() async {
        let room = RoomSession(media: MediaSession(), isLive: false)
        var written: String?
        room.onTranscribe = { _, speaker in "\(speaker): telusa" }
        room.onWriteNotes = { _, people, transcript in
            written = transcript
            return MeetingNotes(
                text: "With \(people.joined(separator: ", "))\n\n\(transcript) (do you know?)",
                url: URL(string: "https://example.test/n?t=a")!,
                inboxURL: URL(string: "https://example.test/n/feed?t=b")!
            )
        }
        let me = Profile(id: "me", handle: "me", displayName: "Me")
        room.start(host: "me", me: me, others: [])
        room.toggleNotes()
        #expect(room.notesOpen && room.notesOn)
        room.toggleNotes()
        #expect(!room.notesOn)
        await wait(until: { written != nil || room.notesResult != nil })
        #expect(room.notesWriting == false)
        room.reset()
    }
}

@MainActor
private func wait(until done: @escaping () -> Bool) async {
    for _ in 0..<40 {
        if done() { return }
        try? await Task.sleep(for: .milliseconds(25))
    }
}
