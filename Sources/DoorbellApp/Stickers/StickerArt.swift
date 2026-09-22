import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decoded, downscaled frames of one sticker. Immutable once built; shared by every
/// copy of that sticker on screen.
final class StickerFrames: @unchecked Sendable {
    let images: [CGImage]
    /// Seconds each frame stays up.
    let delays: [Double]
    let duration: Double
    /// Discrete keyframe times: one more than there are frames, 0 through 1.
    let keyTimes: [NSNumber]

    init(images: [CGImage], delays: [Double]) {
        self.images = images
        self.delays = delays
        duration = max(delays.reduce(0, +), 0.01)
        var elapsed = 0.0
        var times: [NSNumber] = [0]
        for delay in delays {
            elapsed += delay
            times.append(NSNumber(value: min(elapsed / duration, 1)))
        }
        keyTimes = times
    }

    var cost: Int { images.reduce(0) { $0 + $1.bytesPerRow * $1.height } }

    /// Fully composited frames no larger than `maxPixel`. Long animations are thinned
    /// to `limit` frames without changing their length. `limit` 1 is a still.
    static func decode(_ data: Data, maxPixel: Int, limit: Int = 150) -> StickerFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let total = CGImageSourceGetCount(source)
        guard total > 0 else { return nil }
        let step = max(1, Int((Double(total) / Double(max(limit, 1))).rounded(.up)))
        let options = thumbnail(maxPixel)
        var images: [CGImage] = []
        var delays: [Double] = []
        for index in stride(from: 0, to: total, by: step) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            images.append(image)
            delays.append((index..<min(index + step, total)).reduce(0) { $0 + frameDelay(source, $1) })
        }
        return images.isEmpty ? nil : StickerFrames(images: images, delays: delays)
    }

    static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let formats: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dictionary, unclamped, clamped) in formats {
            guard let values = properties?[dictionary] as? [CFString: Any],
                  let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) else { continue }
            // Browsers play near-zero delays at 10 fps; match them.
            return delay > 0.011 ? delay : 0.1
        }
        return 0.1
    }

    static func thumbnail(_ maxPixel: Int) -> CFDictionary {
        [kCGImageSourceCreateThumbnailFromImageAlways: true,
         kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceShouldCacheImmediately: true,
         kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
    }
}

/// Where sticker pictures come from, and the one place they are decoded. Noto art is
/// public and cached on disk; custom art arrives from the library or the room.
@MainActor
final class StickerArt {
    static let shared = StickerArt()
    static let posterPixels = 128
    static let motionPixels = 176

    private let cache = NSCache<NSString, StickerFrames>()
    private var pending: [String: Task<StickerFrames?, Never>] = [:]
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Doorbell/Stickers", isDirectory: true)) {
        self.directory = directory
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    /// The still: the tray, and the first frame while motion loads.
    func poster(_ sticker: Sticker, art: Data? = nil) async -> StickerFrames? {
        switch sticker {
        case .emoji(let emoji):
            guard StickerCatalog.animated.contains(emoji) else { return nil }
            let file = directory.appendingPathComponent("\(StickerCatalog.code(for: emoji)).png")
            return await frames("poster:\(emoji)", pixels: Self.posterPixels, limit: 1) {
                await Self.download(StickerCatalog.posterURL(emoji), to: file)
            }
        case .custom(let hash):
            guard let art else { return nil }
            return await frames("poster:\(hash)", pixels: Self.posterPixels, limit: 1) { art }
        }
    }

    func motion(_ sticker: Sticker, art: Data? = nil) async -> StickerFrames? {
        switch sticker {
        case .emoji(let emoji):
            guard StickerCatalog.animated.contains(emoji) else { return nil }
            let file = directory.appendingPathComponent("\(StickerCatalog.code(for: emoji)).gif")
            return await frames("motion:\(emoji)", pixels: Self.motionPixels, limit: 150) {
                await Self.download(StickerCatalog.motionURL(emoji), to: file)
            }
        case .custom(let hash):
            guard let art else { return nil }
            return await frames("motion:\(hash)", pixels: Self.motionPixels, limit: 150) { art }
        }
    }

    private func frames(_ key: String, pixels: Int, limit: Int,
                        data: @escaping @Sendable () async -> Data?) async -> StickerFrames? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = pending[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { () -> StickerFrames? in
            guard let bytes = await data() else { return nil }
            return StickerFrames.decode(bytes, maxPixel: pixels, limit: limit)
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result { cache.setObject(result, forKey: key as NSString, cost: result.cost) }
        return result
    }

    nonisolated private static func download(_ remote: URL, to file: URL) async -> Data? {
        if let cached = try? Data(contentsOf: file), !cached.isEmpty { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: remote),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 6 * 1024 * 1024,
              StickerImport.isImage(data) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}

/// Turns a picked picture into sticker art. Stills become PNGs no larger than 512 px;
/// animations keep their motion, re-encoded smaller only when too heavy to send.
enum StickerImport {
    enum Failure: LocalizedError, Equatable {
        case notAnImage, tooLarge

        var errorDescription: String? {
            switch self {
            case .notAnImage: "That file isn’t a picture Doorbell can use."
            case .tooLarge: "That animation is too big. Try one under 2 MB."
            }
        }
    }

    static func normalize(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
        else { throw Failure.notAnImage }
        if CGImageSourceGetCount(source) > 1 {
            if data.count <= Sticker.maxArtBytes, isImage(data) { return data }
            if let gif = gif(source, maxPixel: 256), gif.count <= Sticker.maxArtBytes { return gif }
            throw Failure.tooLarge
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, StickerFrames.thumbnail(512))
        else { throw Failure.notAnImage }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.notAnImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.notAnImage }
        guard out.length <= Sticker.maxArtBytes else { throw Failure.tooLarge }
        return out as Data
    }

    /// PNG, JPEG, GIF, WebP or HEIC that ImageIO can actually open.
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else { return false }
        return [UTType.png, .jpeg, .gif, .webP, .heic, .heif].contains { type.conforms(to: $0) }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func gif(_ source: CGImageSource, maxPixel: Int) -> Data? {
        let total = CGImageSourceGetCount(source)
        let step = max(1, (total + 119) / 120)
        let indices = Array(stride(from: 0, to: total, by: step))
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, indices.count, nil)
        else { return nil }
        CGImageDestinationSetProperties(destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in indices {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, StickerFrames.thumbnail(maxPixel))
            else { return nil }
            let delay = (index..<min(index + step, total)).reduce(0) { $0 + StickerFrames.frameDelay(source, $1) }
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
