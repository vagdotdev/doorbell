import CoreImage
import Foundation
import ImageIO
import LiveKit
import UniformTypeIdentifiers

/// The visitor's face at the moment they knocked: small, lit, a few KB. It stands in
/// the glass until live video lands.
enum KnockStill {
    static let maxPixel: CGFloat = 192
    /// The server refuses more (base64 ~24 KB).
    static let maxBytes = 16_000

    /// Nil for frames too dark to be a face: a camera still settling its exposure.
    static func encode(_ image: CGImage) -> Data? {
        guard brightness(image) > 0.1 else { return nil }
        for quality in [0.7, 0.5] {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if out.length <= maxBytes { return out as Data }
        }
        return nil
    }

    static func brightness(_ image: CGImage) -> Double {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard drawn else { return 0 }
        var sum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.299 * Double(pixels[index]) + 0.587 * Double(pixels[index + 1]) + 0.114 * Double(pixels[index + 2])
        }
        return sum / (64 * 255)
    }
}

/// Listens to my camera track for the first usable frame. Frames arrive on WebRTC's
/// thread; the answer is handed back exactly once.
final class StillGrabber: NSObject, VideoRenderer, @unchecked Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var finished = false
    private var early: Data?

    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }

    func next(within timeout: Duration) async -> Data? {
        await withCheckedContinuation { continuation in
            let ready: Data?? = lock.withLock {
                if finished { return .some(early) }
                self.continuation = continuation
                return .none
            }
            if let ready { continuation.resume(returning: ready); return }
            Task { try? await Task.sleep(for: timeout); self.finish(nil) }
        }
    }

    func render(frame: VideoFrame) {
        guard !lock.withLock({ finished }), let buffer = frame.toCVPixelBuffer() else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, KnockStill.maxPixel / max(image.extent.width, image.extent.height, 1))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let picture = Self.context.createCGImage(small, from: small.extent),
              let jpeg = KnockStill.encode(picture) else { return }
        finish(jpeg)
    }

    private func finish(_ data: Data?) {
        let waiting: CheckedContinuation<Data?, Never>?? = lock.withLock {
            guard !finished else { return .none }
            finished = true
            early = data
            defer { continuation = nil }
            return .some(continuation)
        }
        if case .some(let continuation?) = waiting { continuation.resume(returning: data) }
    }
}
