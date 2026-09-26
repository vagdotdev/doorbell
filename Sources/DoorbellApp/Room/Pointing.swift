import AppKit
import Combine
import LiveKit
import SwiftUI

/// "Look here": where someone's mouse is over a shared screen, 0…1 from its top-left.
/// Lossy packets at ~30 Hz; a click is a ping and goes reliably.
struct PointerMessage: Codable, Equatable, Sendable {
    static let topic = "pointer"
    /// Identity of the person whose screen this is over.
    var on: String
    var x: Double?
    var y: Double?
    var ping: Bool?
    var gone: Bool?

    var wire: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    init(on: String, at point: CGPoint?, ping: Bool = false) {
        self.on = on
        x = point.map { Double($0.x) }
        y = point.map { Double($0.y) }
        self.ping = ping ? true : nil
        gone = point == nil ? true : nil
    }

    init?(wire data: Data) {
        guard data.count <= 512, let message = try? JSONDecoder().decode(Self.self, from: data),
              !message.on.isEmpty, message.on.utf8.count <= 64 else { return nil }
        if message.gone != true {
            guard let x = message.x, let y = message.y, (0...1).contains(x), (0...1).contains(y) else { return nil }
        }
        self = message
    }
}

/// Everyone's pointers in this room. Separate from `RoomSession` so 30 Hz movement
/// redraws only the pointers, never the room.
@MainActor
final class PointerBoard: ObservableObject {
    struct Mark: Identifiable, Equatable {
        let id: String
        var name: String
        var on: String
        var x: Double
        var y: Double
        /// Bumped on each click, to replay the ripple.
        var pings = 0
    }

    @Published private(set) var marks: [String: Mark] = [:]
    private var fades: [String: Task<Void, Never>] = [:]
    static let idle: Duration = .seconds(4)

    func marks(on sharer: String) -> [Mark] {
        marks.values.filter { $0.on == sharer }.sorted { $0.id < $1.id }
    }

    func update(from identity: String, name: String, _ message: PointerMessage) {
        fades.removeValue(forKey: identity)?.cancel()
        guard message.gone != true, let x = message.x, let y = message.y else {
            marks[identity] = nil
            return
        }
        var mark = marks[identity] ?? Mark(id: identity, name: name, on: message.on, x: x, y: y)
        mark.name = name; mark.on = message.on; mark.x = x; mark.y = y
        if message.ping == true { mark.pings += 1 }
        marks[identity] = mark
        fades[identity] = Task { [weak self] in
            try? await Task.sleep(for: Self.idle)
            guard !Task.isCancelled else { return }
            self?.marks[identity] = nil
        }
    }

    func forget(_ identity: String) {
        fades.removeValue(forKey: identity)?.cancel()
        marks[identity] = nil
    }

    func clear() {
        fades.values.forEach { $0.cancel() }
        fades = [:]
        marks = [:]
    }
}

/// Where an aspect-fit picture sits inside its view, and a point's place on it.
enum ShareGeometry {
    static func fit(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// Nil outside the picture: the letterbox is not the screen.
    static func normalize(_ point: CGPoint, in content: CGRect) -> CGPoint? {
        guard content.width > 0, content.height > 0, content.contains(point) else { return nil }
        return CGPoint(x: (point.x - content.minX) / content.width, y: (point.y - content.minY) / content.height)
    }
}

/// A shared screen in the room, with everyone's pointers on it. Over someone else's
/// share, my mouse becomes a pointer they can see; a click pings.
struct SharedScreen: View {
    let track: VideoTrack
    let sharer: String
    let isMine: Bool
    @ObservedObject var pointers: PointerBoard
    let onPoint: (CGPoint?) -> Void
    let onPing: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let content = ShareGeometry.fit(aspect: track.aspectRatio, in: geo.size)
            ZStack(alignment: .topLeading) {
                LiveVideo(track: track, fit: true)
                PointerLayer(marks: pointers.marks(on: sharer), area: content)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard !isMine else { return }
                switch phase {
                case .active(let location): onPoint(ShareGeometry.normalize(location, in: content))
                case .ended: onPoint(nil)
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                guard !isMine, let point = ShareGeometry.normalize(location, in: content) else { return }
                onPing(point)
            }
        }
    }
}

struct PointerLayer: View {
    let marks: [PointerBoard.Mark]
    let area: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(marks) { mark in
                PointerMark(mark: mark)
                    .offset(x: area.minX + mark.x * area.width, y: area.minY + mark.y * area.height)
                    .animation(.linear(duration: 0.05), value: mark.x)
                    .animation(.linear(duration: 0.05), value: mark.y)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: marks.map(\.id))
    }
}

/// A classic arrow in their colour, tip exactly on the point, name beside it.
private struct PointerMark: View {
    let mark: PointerBoard.Mark

    var body: some View {
        let color = AvatarView.palette(for: mark.id).0
        ZStack(alignment: .topLeading) {
            PingRing(color: color, pings: mark.pings)
            Arrow()
                .fill(color)
                .overlay(Arrow().stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)))
                .frame(width: 13, height: 19)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            Text(mark.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(Capsule().fill(color))
                .fixedSize()
                .offset(x: 12, y: 17)
        }
    }
}

private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 12.5, sy = rect.height / 18.5
        let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 16), (4.5, 12.2), (7.5, 18.5), (10, 17.4), (7.1, 11.3), (12.5, 11)]
        let points = outline.map { CGPoint(x: rect.minX + $0.0 * sx, y: rect.minY + $0.1 * sy) }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

private struct PingRing: View {
    let color: Color
    let pings: Int
    @State private var spread = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 3)
            .frame(width: 44, height: 44)
            .scaleEffect(spread ? 1.4 : 0.2)
            .opacity(spread ? 0 : (pings > 0 ? 0.9 : 0))
            .offset(x: -22, y: -22)
            .onChange(of: pings) { _, _ in
                spread = false
                withAnimation(.easeOut(duration: 0.6)) { spread = true }
            }
    }
}

/// On the sharer's real screen: friends' pointers drawn over what they're sharing.
/// Click-through, and never part of the share (LiveKit excludes Doorbell's windows
/// from display capture; a window share captures only that window).
@MainActor
final class PointerOverlay {
    private let panel: NSPanel
    private let session: RoomSession
    private let area = CurrentValueSubject<CGRect, Never>(.zero)
    private var sinks: Set<AnyCancellable> = []
    private var follow: Timer?

    init(session: RoomSession) {
        self.session = session
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OverlayLayer(board: session.pointers, sharer: { [weak session] in
            session?.me?.handle ?? ""
        }))
        session.media.$sharedSource.combineLatest(session.pointers.$marks)
            .receive(on: RunLoop.main)
            .sink { [weak self] source, marks in self?.update(source: source, marks: marks) }
            .store(in: &sinks)
    }

    private func update(source: MediaSession.ShareSource?, marks: [String: PointerBoard.Mark]) {
        let me = session.me?.handle
        guard let source, let me, marks.values.contains(where: { $0.on == me }), let frame = Self.frame(of: source) else {
            follow?.invalidate(); follow = nil
            panel.orderOut(nil)
            return
        }
        place(frame)
        if !panel.isVisible { panel.orderFrontRegardless() }
        guard follow == nil, !source.isDisplay else { return }
        // A shared window can move; the pointers move with it.
        follow = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let source = self.session.media.sharedSource, let frame = Self.frame(of: source) else { return }
                self.place(frame)
            }
        }
    }

    private func place(_ frame: CGRect) {
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// The shared display or window, in AppKit screen coordinates.
    static func frame(of source: MediaSession.ShareSource) -> CGRect? {
        if let display = source.source as? MacOSDisplay {
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }?.frame
        }
        guard let window = source.source as? MacOSWindow,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowID)) as? [[CFString: Any]])?.first,
              let bounds = info[kCGWindowBounds].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
              let primary = NSScreen.screens.first?.frame else { return nil }
        // Quartz window bounds start at the top-left of the main display.
        return CGRect(x: bounds.minX, y: primary.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

private struct OverlayLayer: View {
    @ObservedObject var board: PointerBoard
    let sharer: () -> String

    var body: some View {
        GeometryReader { geo in
            PointerLayer(marks: board.marks(on: sharer()), area: CGRect(origin: .zero, size: geo.size))
        }
        .ignoresSafeArea()
    }
}
