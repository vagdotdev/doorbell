import CoreImage
import Foundation
import ImageIO
import LiveKit
import SwiftUI
import UniformTypeIdentifiers

/// The room's photo booth. One shutter press runs the same 3-2-1 on every Mac in the
/// call — a tiny "say cheese" packet, like chat — and each Mac develops its own copy
/// from the frames it already has: everyone's live face on Polaroid paper, filtered,
/// saved as a real file. Nothing here looks like a screenshot of a video call.

// MARK: - Frames

/// Holds the newest frame of one video track, nothing more. The conversion to a
/// picture happens only at the shutter, never per frame.
final class FrameTap: NSObject, VideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: LiveKit.VideoFrame?

    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }

    func render(frame: LiveKit.VideoFrame) {
        lock.withLock { latest = frame }
    }

    var frame: LiveKit.VideoFrame? { lock.withLock { latest } }
}

// MARK: - Filters

/// Three looks, all of them photographs. No "video call" setting exists.
enum BoothFilter: String, CaseIterable, Codable, Sendable {
    /// Faded warmth, like film that sat in a drawer.
    case instant
    /// Black and white, heavy corners.
    case noir
    /// Loud color, the disposable-camera look.
    case chrome

    var title: String {
        switch self {
        case .instant: "Instant"
        case .noir: "Noir"
        case .chrome: "Chrome"
        }
    }

    private var effect: String {
        switch self {
        case .instant: "CIPhotoEffectInstant"
        case .noir: "CIPhotoEffectNoir"
        case .chrome: "CIPhotoEffectChrome"
        }
    }

    private var vignette: Double {
        switch self {
        case .instant: 0.9
        case .noir: 1.4
        case .chrome: 0.6
        }
    }

    /// Monochrome dust over the photo; zero is clean.
    private var grain: Double {
        switch self {
        case .instant: 0.05
        case .noir: 0.08
        case .chrome: 0
        }
    }

    /// The look, applied without changing the picture's size.
    func apply(to image: CIImage) -> CIImage {
        var out = image
        if let look = CIFilter(name: effect) {
            look.setValue(out, forKey: kCIInputImageKey)
            out = look.outputImage ?? out
        }
        if let vignetteFilter = CIFilter(name: "CIVignette") {
            vignetteFilter.setValue(out, forKey: kCIInputImageKey)
            vignetteFilter.setValue(vignette, forKey: kCIInputIntensityKey)
            vignetteFilter.setValue(1.6, forKey: kCIInputRadiusKey)
            out = vignetteFilter.outputImage ?? out
        }
        if grain > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let dust = noise
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: grain),
                ])
                .cropped(to: image.extent)
            out = dust.composited(over: out)
        }
        return out.cropped(to: image.extent)
    }
}

// MARK: - Paper

/// Crops, filters, and prints faces onto Polaroid paper: cream border, thick chin,
/// who was in it and when. Sized in points, rendered at 2×.
@MainActor
enum PolaroidComposer {
    struct Face {
        let name: String
        let image: CGImage
    }

    struct Layout: Equatable {
        let columns: Int
        let rows: Int
        let cell: CGSize
    }

    static let margin: CGFloat = 28
    static let chin: CGFloat = 92
    static let gap: CGFloat = 4
    static let scale: CGFloat = 2

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// One face is a square print; two stand side by side; three or four share a grid.
    static func layout(for count: Int) -> Layout {
        switch count {
        case ...1: Layout(columns: 1, rows: 1, cell: CGSize(width: 400, height: 400))
        case 2: Layout(columns: 2, rows: 1, cell: CGSize(width: 256, height: 320))
        default: Layout(columns: 2, rows: 2, cell: CGSize(width: 280, height: 280))
        }
    }

    static func paperSize(for count: Int) -> CGSize {
        let grid = layout(for: count)
        let rows = Int(ceil(Double(min(max(count, 1), 4)) / Double(grid.columns)))
        let width = grid.cell.width * CGFloat(grid.columns) + gap * CGFloat(grid.columns - 1)
        let height = grid.cell.height * CGFloat(rows) + gap * CGFloat(rows - 1)
        return CGSize(width: width + margin * 2, height: height + margin + chin)
    }

    /// "Vagdev", "Vagdev & Arjun", "Vagdev, Arjun & Meera" — first names only.
    static func caption(names: [String]) -> String {
        let short = names.compactMap { name in
            name.split(separator: " ").first.map(String.init) ?? (name.isEmpty ? nil : name)
        }
        switch short.count {
        case 0: return "Doorbell"
        case 1: return short[0]
        default: return short.dropLast().joined(separator: ", ") + " & " + short[short.count - 1]
        }
    }

    /// "20 Sep 2026 · 2:14 am"
    static func caption(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy · h:mm a"
        return formatter.string(from: date)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }

    /// A camera frame as an upright picture. The local face is flipped to match
    /// the mirrored selfie everyone was posing against.
    static func snapshot(_ buffer: CVPixelBuffer, mirrored: Bool) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        if mirrored { image = image.oriented(.upMirrored) }
        return context.createCGImage(image, from: image.extent)
    }

    static func compose(faces: [Face], filter: BoothFilter, date: Date = .now) -> CGImage? {
        let shown = Array(faces.prefix(4))
        guard !shown.isEmpty else { return nil }
        let grid = layout(for: shown.count)
        var prints: [CGImage] = []
        for face in shown {
            guard let print = develop(face.image, into: grid.cell, filter: filter) else { return nil }
            prints.append(print)
        }
        let paper = PolaroidPaper(
            prints: prints, layout: grid,
            names: caption(names: shown.map(\.name)), stamp: caption(date: date))
        let size = paperSize(for: shown.count)
        let renderer = ImageRenderer(content: paper.frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.cgImage
    }

    /// Center-crop to the cell's shape, then the look.
    private static func develop(_ image: CGImage, into cell: CGSize, filter: BoothFilter) -> CGImage? {
        let source = CIImage(cgImage: image)
        let extent = source.extent
        let target = cell.width / cell.height
        var crop = extent
        if extent.width / extent.height > target {
            crop.size.width = (extent.height * target).rounded(.down)
            crop.origin.x += ((extent.width - crop.width) / 2).rounded(.down)
        } else {
            crop.size.height = (extent.width / target).rounded(.down)
            crop.origin.y += ((extent.height - crop.height) / 2).rounded(.down)
        }
        let filtered = filter.apply(to: source.cropped(to: crop))
        return context.createCGImage(filtered, from: filtered.extent)
    }
}

/// The paper itself: warm white, a hairline around each print, the caption in the chin.
private struct PolaroidPaper: View {
    let prints: [CGImage]
    let layout: PolaroidComposer.Layout
    let names: String
    let stamp: String

    private static let paper = Color(red: 0.965, green: 0.945, blue: 0.905)
    private static let ink = Color(red: 0.26, green: 0.22, blue: 0.18)

    var body: some View {
        VStack(spacing: 0) {
            grid
                .padding(.top, PolaroidComposer.margin)
                .padding(.horizontal, PolaroidComposer.margin)
            VStack(spacing: 7) {
                Text(names)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 6) {
                    Text(stamp)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Circle()
                        .strokeBorder(Self.ink, lineWidth: 1.2)
                        .overlay(Circle().fill(Self.ink).frame(width: 2.6, height: 2.6))
                        .frame(width: 9, height: 9)
                }
                .foregroundStyle(Self.ink.opacity(0.55))
            }
            .padding(.horizontal, PolaroidComposer.margin)
            .frame(maxHeight: .infinity)
        }
        .background(
            LinearGradient(colors: [.white.opacity(0.9), Self.paper],
                           startPoint: .top, endPoint: .bottom)
                .background(Self.paper)
        )
    }

    private var grid: some View {
        let rows = Int(ceil(Double(prints.count) / Double(layout.columns)))
        return VStack(spacing: PolaroidComposer.gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: PolaroidComposer.gap) {
                    ForEach(rowIndices(row), id: \.self) { index in
                        Image(prints[index], scale: 1, label: Text("Photo"))
                            .resizable()
                            .frame(width: layout.cell.width, height: layout.cell.height)
                            .border(Color.black.opacity(0.14), width: 1)
                    }
                }
            }
        }
    }

    private func rowIndices(_ row: Int) -> [Int] {
        let start = row * layout.columns
        return Array(start..<min(start + layout.columns, prints.count))
    }
}

// MARK: - Library

/// Where the photos live: real PNGs in ~/Pictures/Doorbell/Photo Booth, visible in
/// Finder, sorted newest first. The shelf reads the same list.
@MainActor
final class PhotoBoothLibrary: ObservableObject {
    static let shared = PhotoBoothLibrary()

    /// Newest first.
    @Published private(set) var recent: [URL] = []
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Doorbell/Photo Booth", isDirectory: true)) {
        self.directory = directory
        reload()
    }

    @discardableResult
    func save(_ image: CGImage, at date: Date = .now) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Doorbell \(formatter.string(from: date))"
        var url = directory.appendingPathComponent("\(base).png")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(attempt)).png")
            attempt += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure.write }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.write }
        recent.insert(url, at: 0)
        return url
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        recent = files
            .filter { $0.pathExtension == "png" }
            .sorted { modified($0) > modified($1) }
    }

    enum Failure: Error { case write }
}

// MARK: - Session

/// One room's booth. Owned by `RoomSession`; dies with it.
@MainActor
final class PhotoBoothSession: ObservableObject {
    /// Data-packet topic for "say cheese". Older builds ignore unknown topics.
    static let topic = "booth"
    static let maxWire = 200

    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case flash
        case developing
    }

    struct Shot: Identifiable, Equatable {
        let id = UUID()
        let image: CGImage
        let url: URL
        let filter: BoothFilter

        static func == (a: Shot, b: Shot) -> Bool { a.id == b.id }
    }

    /// The look picked on this Mac. A friend's shutter uses their look for that shot.
    @Published var filter: BoothFilter = .instant
    @Published private(set) var phase: Phase = .idle
    /// This room's photos, newest first. The files outlive the room; this list doesn't.
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var toast: Shot?
    @Published var problem: String?
    /// Who would be in the picture right now, in tile order.
    @Published private(set) var faces: [RoomParticipant] = []

    var canShoot: Bool {
        if faceSource != nil { return true }
        if isLive { return !faces.isEmpty }
        return faces.contains(where: \.isLocal) && CameraFeed.shared.status == .running
    }

    var library: PhotoBoothLibrary = .shared
    /// The countdown's clock, injectable so tests run it instantly.
    var pause: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Test hook: stands in for live capture where no camera exists.
    var faceSource: (() -> [PolaroidComposer.Face])?

    private let media: MediaSession
    private let isLive: Bool
    private var taps: [String: (track: VideoTrack, tap: FrameTap)] = [:]
    private(set) var running: Task<Void, Never>?
    private var toastClear: Task<Void, Never>?
    private var generation = 0

    init(media: MediaSession, isLive: Bool) {
        self.media = media
        self.isLive = isLive
    }

    static func wire(_ filter: BoothFilter) -> Data {
        (try? JSONEncoder().encode(["filter": filter.rawValue])) ?? Data()
    }

    /// Keep a tap on every live track so the shutter can grab everyone at once.
    func attach(_ participants: [RoomParticipant]) {
        var next: [String: (track: VideoTrack, tap: FrameTap)] = [:]
        for participant in participants {
            guard let track = participant.video else { continue }
            if let existing = taps.removeValue(forKey: participant.id), existing.track === track {
                next[participant.id] = existing
            } else {
                let tap = FrameTap()
                track.add(videoRenderer: tap)
                next[participant.id] = (track, tap)
            }
        }
        for stale in taps.values { stale.track.remove(videoRenderer: stale.tap) }
        taps = next
        let inFrame = participants.filter { photographable($0) }
        if inFrame != faces { faces = inFrame }
    }

    /// The shutter. Tells the room first, so every Mac counts down together.
    func take() async {
        guard phase == .idle, canShoot else { return }
        let chosen = filter
        if isLive { try? await media.send(Self.wire(chosen), topic: Self.topic) }
        guard phase == .idle else { return }
        run(chosen)
    }

    /// A friend pressed their shutter: same countdown, their look, my own copy.
    func receive(_ data: Data) {
        guard data.count <= Self.maxWire, phase == .idle,
              let body = try? JSONDecoder().decode([String: String].self, from: data),
              let filter = body["filter"].flatMap(BoothFilter.init(rawValue:)) else { return }
        run(filter)
    }

    func reset() {
        generation += 1
        running?.cancel()
        running = nil
        toastClear?.cancel()
        toastClear = nil
        for entry in taps.values { entry.track.remove(videoRenderer: entry.tap) }
        taps = [:]
        faces = []
        shots = []
        toast = nil
        problem = nil
        phase = .idle
        filter = .instant
    }

    private func run(_ filter: BoothFilter) {
        guard phase == .idle else { return }
        let ticket = generation
        running = Task { @MainActor [weak self] in
            guard let self else { return }
            for count in stride(from: 3, through: 1, by: -1) {
                guard generation == ticket else { return }
                phase = .countdown(count)
                Sounds.boothTick()
                await pause(.seconds(1))
            }
            guard generation == ticket else { return }
            let faces = faceSource?() ?? capture()
            Sounds.shutter()
            phase = .flash
            await pause(.milliseconds(350))
            guard generation == ticket else { return }
            phase = .developing
            if let image = PolaroidComposer.compose(faces: faces, filter: filter),
               let url = try? library.save(image) {
                let shot = Shot(image: image, url: url, filter: filter)
                shots.insert(shot, at: 0)
                present(shot)
                problem = nil
            } else {
                problem = "No picture came out. Turn a camera on and try again."
            }
            phase = .idle
        }
    }

    /// Everyone the tiles are showing live, at this instant. Faces with no picture
    /// (camera off, no frame yet) simply aren't in the photo.
    private func capture() -> [PolaroidComposer.Face] {
        var result: [PolaroidComposer.Face] = []
        for participant in faces {
            let name = participant.profile.displayName
            if let entry = taps[participant.id], let frame = entry.tap.frame,
               let buffer = frame.toCVPixelBuffer(),
               let image = PolaroidComposer.snapshot(buffer, mirrored: participant.isLocal) {
                result.append(PolaroidComposer.Face(name: name, image: image))
            } else if participant.isLocal, !isLive, let buffer = CameraFeed.shared.latestFrame,
                      let image = PolaroidComposer.snapshot(buffer, mirrored: true) {
                result.append(PolaroidComposer.Face(name: name, image: image))
            }
        }
        return result
    }

    private func photographable(_ participant: RoomParticipant) -> Bool {
        // The mock has no tracks: the local camera stands in, like its tile.
        guard isLive else { return participant.isLocal }
        guard participant.video != nil else { return false }
        return participant.camOn || !participant.isLocal
    }

    private func present(_ shot: Shot) {
        toast = shot
        toastClear?.cancel()
        toastClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if self?.toast?.id == shot.id { self?.toast = nil }
        }
    }
}
