import Foundation

/// Something big and silly for the room chat. Catalog stickers are Google's animated
/// Noto emoji (CC BY 4.0), fetched from Google's font CDN and cached. Custom stickers
/// are your own pictures: kept on this Mac, sent peer-to-peer to the people in the room.
enum Sticker: Hashable, Sendable {
    case emoji(String)
    /// SHA-256 of the picture's bytes, lowercase hex.
    case custom(String)

    /// Data-packet topic for "show this sticker". Older builds ignore unknown topics.
    static let topic = "sticker"
    /// Byte-stream topic carrying a custom sticker's picture, once per person per room.
    static let artTopic = "sticker-art"
    static let maxArtBytes = 2 * 1024 * 1024

    /// What a reader without the picture sees.
    var alt: String {
        switch self {
        case .emoji(let emoji): emoji
        case .custom: "Sticker"
        }
    }

    var wire: Data {
        let body: [String: String] = switch self {
        case .emoji(let emoji): ["emoji": emoji]
        case .custom(let hash): ["custom": hash]
        }
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    init?(wire data: Data) {
        guard data.count <= 512,
              let body = try? JSONDecoder().decode([String: String].self, from: data), body.count == 1 else { return nil }
        if let emoji = body["emoji"], Self.isEmoji(emoji) {
            self = .emoji(emoji)
        } else if let hash = body["custom"], Self.isHash(hash) {
            self = .custom(hash)
        } else {
            return nil
        }
    }

    static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Exactly one emoji: a sticker can't smuggle in a line of text.
    static func isEmoji(_ text: String) -> Bool {
        guard text.count == 1, text.utf8.count <= 40, let scalars = text.first?.unicodeScalars,
              scalars.first?.properties.isEmoji == true else { return false }
        return scalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }
}

/// The roll. Every entry exists in Noto's animated set (checked by `StickerTests`).
enum StickerCatalog {
    struct Pack: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let stickers: [String]
    }

    static let packs: [Pack] = [
        Pack(id: "faces", title: "Faces", symbol: "face.smiling", stickers: [
            "😂", "🤣", "😭", "😍", "🥰", "😘", "😎", "🤩", "🥳", "😊", "🙂", "🙃", "😉", "😅",
            "😆", "😜", "🤪", "😏", "🙄", "😬", "🥹", "🥺", "🥲", "😢", "😤", "😡", "🤯", "😱",
            "😳", "🫠", "🤔", "🤨", "🧐", "🤫", "🤭", "🫣", "🤐", "🥱", "😴", "🤤", "🤮",
            "\u{1F635}\u{200D}\u{1F4AB}", "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}",
            "😇", "😈", "🫡", "🤡", "💀", "👻", "👽", "👾", "🤖", "💩", "🎃",
        ]),
        Pack(id: "love", title: "Love & fire", symbol: "heart", stickers: [
            "\u{2764}\u{FE0F}", "\u{2764}\u{FE0F}\u{200D}\u{1F525}", "🔥", "\u{2728}", "💯",
            "💖", "💕", "💔", "💋", "😻",
        ]),
        Pack(id: "hands", title: "Hands", symbol: "hand.thumbsup", stickers: [
            "👍", "👎", "👏", "🙌", "🙏", "👋", "🤝", "\u{270C}\u{FE0F}", "🤞", "🤘", "🫶", "💪", "👀",
        ]),
        Pack(id: "party", title: "Party", symbol: "party.popper", stickers: [
            "🎉", "🎊", "🥂", "🍻", "🎂", "🎁", "🎈", "🪩", "💃", "🏆", "🚀", "💥", "\u{26A1}",
            "🌈", "🚨", "💸", "\u{2615}", "🍕", "🍿", "\u{2603}\u{FE0F}", "🍀", "🌞", "🌚",
        ]),
        Pack(id: "animals", title: "Animals", symbol: "pawprint", stickers: [
            "🙈", "🙉", "🙊", "😺", "😹", "🙀", "😿", "😾", "🐱", "🦊", "🐼", "🦍", "🐸", "🦄",
            "🐧", "🐣", "🐝", "🦋", "🐙", "🐢", "🐍", "🐌", "🦖", "🦥",
        ]),
    ]

    static let animated: Set<String> = Set(packs.flatMap(\.stickers))

    /// Noto names each animation by its code points: "2764_fe0f_200d_1f525".
    static func code(for emoji: String) -> String {
        emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_")
    }

    static func posterURL(_ emoji: String) -> URL { URL(string: "\(base)/\(code(for: emoji))/128.png")! }
    /// GIF, not WebP: ImageIO re-composites every WebP frame from the first, ~10× slower.
    static func motionURL(_ emoji: String) -> URL { URL(string: "\(base)/\(code(for: emoji))/512.gif")! }

    private static let base = "https://fonts.gstatic.com/s/e/notoemoji/latest"
}
