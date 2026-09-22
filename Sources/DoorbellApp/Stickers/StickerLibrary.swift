import Foundation

/// Your own stickers, plus what you sent last. Files on this Mac only; people in the
/// room receive a copy of a picture when you send it.
@MainActor
final class StickerLibrary: ObservableObject {
    static let shared = StickerLibrary(
        directory: AppConfig.current.supportDirectory.appendingPathComponent("Stickers", isDirectory: true))
    static let recentLimit = 10

    /// Hashes, newest first.
    @Published private(set) var mine: [String] = []
    /// Newest first. Catalog and custom alike.
    @Published private(set) var recent: [Sticker] = []

    private let directory: URL
    private let defaults: UserDefaults
    private var loaded: [String: Data] = [:]

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        mine = files
            .filter { $0.pathExtension == "sticker" && Sticker.isHash($0.deletingPathExtension().lastPathComponent) }
            .sorted { modified($0) > modified($1) }
            .map { $0.deletingPathExtension().lastPathComponent }
        let kept = Set(mine)
        recent = (defaults.stringArray(forKey: SettingsKey.recentStickers) ?? [])
            .compactMap { Sticker(wire: Data($0.utf8)) }
            .filter { if case .custom(let hash) = $0 { kept.contains(hash) } else { true } }
    }

    func data(for hash: String) -> Data? {
        if let hit = loaded[hash] { return hit }
        guard mine.contains(hash), let data = try? Data(contentsOf: file(hash)) else { return nil }
        loaded[hash] = data
        return data
    }

    /// Pictures from disk. Returns what went wrong, if anything did.
    func add(files: [URL]) async -> String? {
        await add(files.map { url in { try Data(contentsOf: url) } })
    }

    /// Pictures dropped straight from a browser or another app.
    func add(pictures: [Data]) async -> String? {
        await add(pictures.map { data in { data } })
    }

    /// A friend's sticker from the room, kept for yourself. Already normalized by them.
    func keep(_ art: Data) throws {
        guard art.count <= Sticker.maxArtBytes, StickerImport.isImage(art) else { throw StickerImport.Failure.notAnImage }
        let hash = StickerImport.hash(art)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try art.write(to: file(hash), options: .atomic)
        loaded[hash] = art
        mine.removeAll { $0 == hash }
        mine.insert(hash, at: 0)
    }

    func remove(_ hash: String) {
        try? FileManager.default.removeItem(at: file(hash))
        loaded[hash] = nil
        mine.removeAll { $0 == hash }
        recent.removeAll { $0 == .custom(hash) }
        saveRecent()
    }

    func noteSent(_ sticker: Sticker) {
        recent.removeAll { $0 == sticker }
        recent.insert(sticker, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        saveRecent()
    }

    private func add(_ sources: [@Sendable () throws -> Data]) async -> String? {
        var problem: String?
        for source in sources {
            do {
                let art = try await Task.detached(priority: .userInitiated) { try StickerImport.normalize(source()) }.value
                try keep(art)
            } catch {
                problem = (error as? StickerImport.Failure)?.errorDescription ?? "Couldn’t add that picture."
            }
        }
        return problem
    }

    private func saveRecent() {
        defaults.set(recent.map { String(decoding: $0.wire, as: UTF8.self) }, forKey: SettingsKey.recentStickers)
    }

    private func file(_ hash: String) -> URL { directory.appendingPathComponent("\(hash).sticker") }
}
