import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One sticker at any size: the still at once, then motion when `animated`.
struct StickerView: View {
    let sticker: Sticker
    let size: CGFloat
    var animated = true
    /// A custom sticker's picture. Emoji art is fetched by `StickerArt`.
    var art: Data?
    @State private var poster: StickerFrames?
    @State private var motion: StickerFrames?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let frames = (animated ? motion : nil) ?? poster {
                FrameLayer(frames: frames, playing: animated && !reduceMotion)
            } else if case .emoji(let emoji) = sticker {
                Text(emoji).font(.system(size: size * 0.78))
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(DesignTokens.raised)
                    .overlay(Image(systemName: "photo").font(.system(size: size * 0.3)).foregroundStyle(DesignTokens.inkTertiary))
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.15), value: poster != nil)
        .accessibilityElement()
        .accessibilityLabel(Text(sticker.alt))
        .task(id: art != nil) { poster = await StickerArt.shared.poster(sticker, art: art) }
        .task(id: "\(animated)\(art != nil)") {
            if animated { motion = await StickerArt.shared.motion(sticker, art: art) }
        }
    }
}

private struct FrameLayer: NSViewRepresentable {
    let frames: StickerFrames
    let playing: Bool

    func makeNSView(context: Context) -> FrameLayerView { FrameLayerView() }
    func updateNSView(_ view: FrameLayerView, context: Context) { view.show(frames, playing: playing) }
}

/// Core Animation plays the frames on the render server: no timers, nothing drawn
/// while off screen.
private final class FrameLayerView: NSView {
    private weak var shown: StickerFrames?
    private var playing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    // Clicks belong to the SwiftUI button around the sticker.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeBackingProperties() {
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    func show(_ frames: StickerFrames, playing: Bool) {
        guard let layer, frames !== shown || playing != self.playing else { return }
        shown = frames
        self.playing = playing
        layer.removeAnimation(forKey: "frames")
        layer.contents = frames.images.first
        guard playing, frames.images.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.images
        animation.keyTimes = frames.keyTimes
        animation.calculationMode = .discrete
        animation.duration = frames.duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // Every copy of a sticker shares one clock, so a pile of spam moves together.
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        animation.beginTime = now - now.truncatingRemainder(dividingBy: frames.duration)
        layer.add(animation, forKey: "frames")
    }
}

/// Left to right, wrapping. Every sticker is the same size, so rows stay tidy.
struct StickerFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Consecutive stickers from one person share a block, so spam reads as a pile.
struct ChatRun: Identifiable {
    let id: UUID
    var messages: [ChatMessage]
    var first: ChatMessage { messages[0] }

    static func runs(_ chat: [ChatMessage]) -> [ChatRun] {
        var out: [ChatRun] = []
        for message in chat {
            if message.sticker != nil, let last = out.last, last.first.sticker != nil,
               last.first.from.id == message.from.id,
               let previous = last.messages.last, message.at.timeIntervalSince(previous.at) < 120 {
                out[out.count - 1].messages.append(message)
            } else {
                out.append(ChatRun(id: message.id, messages: [message]))
            }
        }
        return out
    }
}

// MARK: - Tray

/// The roll: Google's animated emoji, your own stickers, and every emoji through the
/// system palette. A click sends at once and leaves the tray open — made for spamming.
struct StickerTray: View {
    let onPick: (Sticker) -> Void
    let onEmoji: () -> Void
    @ObservedObject var library: StickerLibrary
    @State private var tab = Tab.stickers
    /// Frozen while open: a sticker must not slide out from under a spamming cursor.
    @State private var recent: [Sticker] = []
    @State private var problem: String?
    @State private var importing = false
    @State private var dropping = false

    enum Tab: String, CaseIterable, Identifiable {
        case stickers, mine
        var id: String { rawValue }
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let stickers: [Sticker]
    }

    private let columns = Array(repeating: GridItem(.fixed(46), spacing: 6), count: 5)

    private var sections: [Section] {
        (recent.isEmpty ? [] : [Section(id: "recent", title: "Recent", symbol: "clock", stickers: recent)])
            + StickerCatalog.packs.map {
                Section(id: $0.id, title: $0.title, symbol: $0.symbol, stickers: $0.stickers.map(Sticker.emoji))
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SegmentedPills(options: Tab.allCases, selection: $tab) { $0 == .stickers ? "Stickers" : "Mine" }
                Spacer(minLength: 4)
                Button(action: onEmoji) {
                    Label("Emoji", systemImage: "face.smiling")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.inkSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(DesignTokens.raised))
                }
                .buttonStyle(.plain)
                .help("All emoji, into your message")
            }
            switch tab {
            case .stickers: catalog
            case .mine: mine
            }
        }
        .padding(10)
        .frame(minHeight: 150, idealHeight: 260, maxHeight: 260)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DesignTokens.hairline, lineWidth: 1))
        .onAppear { recent = library.recent }
    }

    private var catalog: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    ForEach(sections) { section in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(section.id, anchor: .top) }
                        } label: {
                            Image(systemName: section.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DesignTokens.inkSecondary)
                                .frame(maxWidth: .infinity, minHeight: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(section.title)
                        .accessibilityLabel(section.title)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DesignTokens.inkTertiary)
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                                    ForEach(section.stickers, id: \.self) { sticker in
                                        StickerCell(sticker: sticker, art: customArt(sticker), onPick: onPick)
                                    }
                                }
                            }
                            .id(section.id)
                        }
                        Text("Animated emoji: Noto by Google · CC BY 4.0")
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.inkTertiary)
                            .padding(.top, 2)
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var mine: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    AddStickerCell(busy: importing, action: pickFiles)
                    ForEach(library.mine, id: \.self) { hash in
                        StickerCell(sticker: .custom(hash), art: library.data(for: hash), onPick: onPick)
                            .contextMenu {
                                Button("Remove Sticker", role: .destructive) { library.remove(hash) }
                            }
                    }
                }
                if let problem {
                    Text(problem)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.social)
                        .fixedSize(horizontal: false, vertical: true)
                } else if library.mine.isEmpty {
                    Text("Drop pictures or GIFs here, or click + to make your own. They stay on this Mac; people in the room get a copy when you send one.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignTokens.inkSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DesignTokens.utility, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DesignTokens.utility.opacity(0.06)))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping, perform: accept)
    }

    private func customArt(_ sticker: Sticker) -> Data? {
        if case .custom(let hash) = sticker { library.data(for: hash) } else { nil }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose pictures or GIFs for your stickers"
        guard panel.runModal() == .OK else { return }
        let files = panel.urls
        importing = true
        problem = nil
        Task { problem = await library.add(files: files); importing = false }
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        importing = true
        problem = nil
        Task {
            var files: [URL] = []
            var pictures: [Data] = []
            for provider in providers {
                if provider.canLoadObject(ofClass: URL.self),
                   let url = await withCheckedContinuation({ (done: CheckedContinuation<URL?, Never>) in
                       _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
                   }), url.isFileURL {
                    files.append(url)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                          let data = await withCheckedContinuation({ (done: CheckedContinuation<Data?, Never>) in
                              _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                  done.resume(returning: data)
                              }
                          }) {
                    pictures.append(data)
                }
            }
            let fromFiles = await library.add(files: files)
            let fromPictures = await library.add(pictures: pictures)
            problem = fromFiles ?? fromPictures
            if files.isEmpty, pictures.isEmpty { problem = "Drop a picture or a GIF." }
            importing = false
        }
        return true
    }
}

private struct StickerCell: View {
    let sticker: Sticker
    let art: Data?
    let onPick: (Sticker) -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button {
            onPick(sticker)
            pressed = true
            Task { try? await Task.sleep(for: .milliseconds(110)); pressed = false }
        } label: {
            StickerView(sticker: sticker, size: 38, animated: hovering, art: art)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.09) : .clear)
                )
                .scaleEffect(pressed ? 0.84 : (hovering ? 1.1 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: pressed)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct AddStickerCell: View {
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .foregroundStyle(hovering ? DesignTokens.inkSecondary : DesignTokens.hairline)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(hovering ? DesignTokens.ink : DesignTokens.inkSecondary)
                }
            }
            .frame(width: 46, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .help("Add pictures or GIFs")
        .accessibilityLabel("Add stickers")
    }
}
