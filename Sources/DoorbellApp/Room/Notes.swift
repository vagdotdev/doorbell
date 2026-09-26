@preconcurrency import AVFoundation
import Foundation
import LiveKit

private final class Once: @unchecked Sendable {
    var used = false
}

enum NotesAudio {
    static let sampleRate = 16_000
    static let chunkSeconds = 12
    static let chunkBytes = sampleRate * 2 * chunkSeconds

    static func wav(_ pcm: Data, sampleRate: Int = sampleRate) -> Data {
        var header = Data(count: 44)
        func u16(_ value: UInt16, at offset: Int) {
            header[offset] = UInt8(value & 0xFF)
            header[offset + 1] = UInt8(value >> 8)
        }
        func u32(_ value: UInt32, at offset: Int) {
            header[offset] = UInt8(value & 0xFF)
            header[offset + 1] = UInt8((value >> 8) & 0xFF)
            header[offset + 2] = UInt8((value >> 16) & 0xFF)
            header[offset + 3] = UInt8(value >> 24)
        }
        header.replaceSubrange(0..<4, with: Array("RIFF".utf8))
        u32(UInt32(36 + pcm.count), at: 4)
        header.replaceSubrange(8..<12, with: Array("WAVE".utf8))
        header.replaceSubrange(12..<16, with: Array("fmt ".utf8))
        u32(16, at: 16)
        u16(1, at: 20)
        u16(1, at: 22)
        u32(UInt32(sampleRate), at: 24)
        u32(UInt32(sampleRate * 2), at: 28)
        u16(2, at: 32)
        u16(16, at: 34)
        header.replaceSubrange(36..<40, with: Array("data".utf8))
        u32(UInt32(pcm.count), at: 40)
        return header + pcm
    }
}

/// One person's LiveKit audio, cut into short WAV clips.
final class SpeakerTap: NSObject, AudioRenderer, @unchecked Sendable {
    let speaker: String
    var onChunk: ((Data) -> Void)?
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(NotesAudio.sampleRate),
                                       channels: 1, interleaved: true)!

    init(speaker: String) { self.speaker = speaker }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let converted = convert(pcmBuffer), let channel = converted.int16ChannelData else { return }
        let bytes = Data(bytes: channel[0], count: Int(converted.frameLength) * 2)
        var clip: Data?
        lock.lock()
        pcm.append(bytes)
        if pcm.count >= NotesAudio.chunkBytes {
            clip = NotesAudio.wav(pcm)
            pcm = Data()
        }
        lock.unlock()
        if let clip { onChunk?(clip) }
    }

    func flush() -> Data? {
        lock.lock()
        let leftover = pcm
        pcm = Data()
        lock.unlock()
        guard leftover.count >= NotesAudio.sampleRate else { return nil }
        return NotesAudio.wav(leftover)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let frames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(frames, 1)) else { return nil }
        var error: NSError?
        let once = Once()
        nonisolated(unsafe) let input = buffer
        converter?.convert(to: out, error: &error) { _, status in
            if once.used {
                status.pointee = .noDataNow
                return nil
            }
            once.used = true
            status.pointee = .haveData
            return input
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
