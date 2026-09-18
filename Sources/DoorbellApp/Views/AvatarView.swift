import AppKit
import SwiftUI

/// Initials on a duotone disc until a photo is set. Colour is stable per handle.
/// Remote `avatarURL` (Convex storage) and local mock portraits both show.
struct AvatarView: View {
    let profile: Profile
    var size: CGFloat = 44

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.98, green: 0.62, blue: 0.36), Color(red: 0.86, green: 0.30, blue: 0.36)),
        (Color(red: 0.40, green: 0.66, blue: 1.00), Color(red: 0.30, green: 0.36, blue: 0.86)),
        (Color(red: 0.55, green: 0.86, blue: 0.62), Color(red: 0.20, green: 0.56, blue: 0.50)),
        (Color(red: 0.96, green: 0.76, blue: 0.40), Color(red: 0.80, green: 0.46, blue: 0.20)),
        (Color(red: 0.80, green: 0.60, blue: 0.98), Color(red: 0.48, green: 0.30, blue: 0.80)),
        (Color(red: 0.98, green: 0.56, blue: 0.70), Color(red: 0.74, green: 0.26, blue: 0.50)),
    ]

    private var palette: (Color, Color) {
        // djb2 — Hashable's hashValue is randomised per process.
        var h: UInt32 = 5381
        for b in profile.handle.utf8 { h = (h &* 33) &+ UInt32(b) }
        return Self.palettes[Int(h % UInt32(Self.palettes.count))]
    }

    private var initials: String {
        let parts = profile.displayName.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        if letters.isEmpty { return String(profile.handle.prefix(1)).uppercased() }
        return String(letters).uppercased()
    }

    private var localPortrait: NSImage? {
        guard !AppConfig.current.isLive,
              profile.avatarURL == nil,
              let url = Bundle.module.url(forResource: profile.handle,
                                          withExtension: "jpg",
                                          subdirectory: "Portraits") else { return nil }
        return NSImage(contentsOf: url)
    }

    private var filePortrait: NSImage? {
        guard let url = profile.avatarURL, url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        ZStack {
            if let filePortrait {
                Image(nsImage: filePortrait).resizable().scaledToFill()
            } else if let remote = profile.avatarURL, !remote.isFileURL {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        initialsDisc
                    }
                }
            } else if let localPortrait {
                Image(nsImage: localPortrait).resizable().scaledToFill()
            } else {
                initialsDisc
            }
            // The same rim as the peephole glass, lit from the top: a face behind a lens.
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.38), DesignTokens.horizon.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initialsDisc: some View {
        ZStack {
            Circle().fill(
                LinearGradient(colors: [palette.0, palette.1],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            Text(initials)
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
    }
}
