import AppKit
import ImageIO
import SwiftUI

/// The shelf: what's inside your door. For now it holds the photo booth's newest
/// Polaroids, pinned up like a fridge — a magnet dot each, a little crooked, clickable.
/// Empty, it stays the quiet tray it always was.
struct ShelfView: View {
    @ObservedObject private var library = PhotoBoothLibrary.shared

    var body: some View {
        Group {
            if library.recent.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(DesignTokens.inkTertiary)
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.inkTertiary)
                }
            } else {
                fridge
            }
        }
        .onAppear { library.reload() }
    }

    private var fridge: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                ForEach(Array(library.recent.prefix(4).enumerated()), id: \.element) { index, url in
                    FridgePolaroid(url: url, index: index)
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                Text("Photo Booth")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Text("·")
                    .foregroundStyle(DesignTokens.inkTertiary)
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(at: library.directory,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(library.directory)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.utility)
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 6)
    }
}

/// One photo under a glossy magnet, tilted the way it was slapped on.
private struct FridgePolaroid: View {
    let url: URL
    let index: Int
    @State private var thumbnail: ShelfThumbnail?

    private static let paper = Color(red: 0.965, green: 0.945, blue: 0.905)
    private static let magnets: [Color] = [DesignTokens.social, DesignTokens.utility, DesignTokens.horizon]

    /// Stable per file, so the shelf doesn't reshuffle every open. djb2, like AvatarView.
    private var tilt: Double {
        var h: UInt32 = 5381
        for b in url.lastPathComponent.utf8 { h = (h &* 33) &+ UInt32(b) }
        return Double(h % 7) - 3
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    Color(white: 0.14)
                    if let thumbnail {
                        Image(thumbnail.image, scale: 2, label: Text("Photo"))
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 86, height: 86)
                .clipped()
                .padding(.horizontal, 5)
                .padding(.top, 5)
                Spacer(minLength: 0)
            }
            .frame(width: 96, height: 118)
            .background(Self.paper)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
            .overlay(alignment: .top) {
                Circle()
                    .fill(
                        RadialGradient(colors: [magnet.opacity(0.95), magnet.opacity(0.6)],
                                       center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 8)
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(y: -4)
            }
            .rotationEffect(.degrees(tilt))
        }
        .buttonStyle(.plain)
        .help("Open the photo")
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .task(id: url) { thumbnail = await ShelfThumbnail.load(url) }
    }

    private var magnet: Color { Self.magnets[index % Self.magnets.count] }
}

/// A decoded thumbnail that can cross off the main thread. Immutable once built.
private final class ShelfThumbnail: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) { self.image = image }

    static func load(_ url: URL) async -> ShelfThumbnail? {
        await Task.detached(priority: .utility) {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, StickerFrames.thumbnail(320))
            else { return nil }
            return ShelfThumbnail(image)
        }.value
    }
}
