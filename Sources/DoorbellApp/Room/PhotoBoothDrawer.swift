import AppKit
import SwiftUI

/// The booth, in the room's right-hand drawer: a live Polaroid of everyone here,
/// three looks, one big shutter. What comes out is a photograph, not a screenshot.
struct PhotoBoothDrawer: View {
    @ObservedObject var booth: PhotoBoothSession
    /// Re-renders the shutter when the mock camera warms up or goes away.
    @ObservedObject private var feed = CameraFeed.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Photo Booth")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
                .padding(.horizontal, 16)
                .padding(.top, 46)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 16) {
                    LivePolaroidPreview(booth: booth)
                    HStack(spacing: 14) {
                        ForEach(BoothFilter.allCases, id: \.self) { filter in
                            FilterChip(filter: filter, selected: booth.filter == filter) {
                                booth.filter = filter
                            }
                        }
                    }
                    ShutterButton(booth: booth, canShoot: booth.canShoot)
                    if !booth.canShoot {
                        Text("Turn on a camera to take a picture.")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.inkTertiary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Everyone hears the count and gets a copy.")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.inkTertiary)
                            .multilineTextAlignment(.center)
                    }
                    if let problem = booth.problem {
                        Text(problem)
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    if !booth.shots.isEmpty {
                        SessionStrip(shots: booth.shots)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(white: 0.05))
        .overlay(alignment: .leading) { Rectangle().fill(DesignTokens.hairline).frame(width: 1) }
    }
}

// MARK: - Preview

/// The same paper and grid the photo will use, live, with a light-touch version of
/// the chosen look. The real look is Core Image; this is the mirror on the booth wall.
private struct LivePolaroidPreview: View {
    @ObservedObject var booth: PhotoBoothSession

    private static let paper = Color(red: 0.965, green: 0.945, blue: 0.905)
    private static let ink = Color(red: 0.26, green: 0.22, blue: 0.18)
    private static let margin: CGFloat = 14
    private static let gap: CGFloat = 3
    private static let width: CGFloat = 260

    var body: some View {
        let faces = booth.faces
        VStack(spacing: 0) {
            Group {
                if faces.isEmpty {
                    Color.black.opacity(0.85)
                        .frame(width: Self.width - Self.margin * 2, height: Self.width - Self.margin * 2)
                        .overlay {
                            Text("Nobody's on camera yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                } else {
                    grid(faces)
                        .modifier(BoothLook(filter: booth.filter))
                }
            }
            .padding(.top, Self.margin)
            .padding(.horizontal, Self.margin)
            Text(PolaroidComposer.caption(names: faces.map(\.profile.displayName)))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, Self.margin)
                .frame(height: 42)
        }
        .frame(width: Self.width)
        .background(
            LinearGradient(colors: [.white.opacity(0.9), Self.paper],
                           startPoint: .top, endPoint: .bottom)
                .background(Self.paper)
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .rotationEffect(.degrees(-0.8))
        .animation(.easeInOut(duration: 0.2), value: booth.filter)
    }

    /// Mirrors `PolaroidComposer.layout`: 1 square, 2 side by side, 3–4 in a grid.
    private func grid(_ faces: [RoomParticipant]) -> some View {
        let shown = Array(faces.prefix(4))
        let layout = PolaroidComposer.layout(for: shown.count)
        let photoWidth = Self.width - Self.margin * 2
        let cellWidth = (photoWidth - Self.gap * CGFloat(layout.columns - 1)) / CGFloat(layout.columns)
        let cellHeight = cellWidth * layout.cell.height / layout.cell.width
        let rows = Int(ceil(Double(shown.count) / Double(layout.columns)))
        return VStack(spacing: Self.gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(rowFaces(shown, row: row, columns: layout.columns)) { participant in
                        FaceCell(participant: participant)
                            .frame(width: cellWidth, height: cellHeight)
                            .clipped()
                            .border(Color.black.opacity(0.14), width: 1)
                    }
                }
            }
        }
    }

    private func rowFaces(_ faces: [RoomParticipant], row: Int, columns: Int) -> [RoomParticipant] {
        let start = row * columns
        let end = min(start + columns, faces.count)
        return start < end ? Array(faces[start..<end]) : []
    }
}

private struct FaceCell: View {
    let participant: RoomParticipant

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let track = participant.video {
                LiveVideo(track: track, mirrored: participant.isLocal)
            } else if participant.isLocal, !AppConfig.current.isLive {
                // Mock: no seat, so the local camera stands in — and keeps the feed warm.
                CameraPreview(mirrored: true, fallback: participant.profile)
            } else {
                AvatarView(profile: participant.profile, size: 40)
            }
        }
    }
}

/// A cheap stand-in for the Core Image look: enough to choose by.
private struct BoothLook: ViewModifier {
    let filter: BoothFilter

    func body(content: Content) -> some View {
        content
            .grayscale(filter == .noir ? 1 : 0)
            .saturation(filter == .instant ? 0.78 : filter == .chrome ? 1.25 : 1)
            .contrast(filter == .noir ? 1.15 : 1.06)
            .overlay {
                if filter == .instant {
                    Color(red: 1, green: 0.75, blue: 0.45).opacity(0.10)
                }
            }
            .overlay {
                RadialGradient(colors: [.clear, .black.opacity(vignette)],
                               center: .center, startRadius: 60, endRadius: 190)
            }
    }

    private var vignette: Double {
        switch filter {
        case .instant: 0.30
        case .noir: 0.42
        case .chrome: 0.20
        }
    }
}

// MARK: - Controls

private struct FilterChip: View {
    let filter: BoothFilter
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Circle()
                    .fill(LinearGradient(colors: swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle().strokeBorder(selected ? DesignTokens.utility : DesignTokens.hairline,
                                              lineWidth: selected ? 2 : 1)
                    )
                    .scaleEffect(hovering && !selected ? 1.08 : 1)
                Text(filter.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DesignTokens.ink : DesignTokens.inkSecondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("\(filter.title) filter")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var swatch: [Color] {
        switch filter {
        case .instant: [Color(red: 0.98, green: 0.86, blue: 0.62), Color(red: 0.80, green: 0.53, blue: 0.33)]
        case .noir: [Color(white: 0.88), Color(white: 0.14)]
        case .chrome: [Color(red: 0.55, green: 0.86, blue: 0.95), Color(red: 0.26, green: 0.44, blue: 0.90)]
        }
    }
}

/// The big round button. Press it and the whole room counts down with you.
private struct ShutterButton: View {
    @ObservedObject var booth: PhotoBoothSession
    /// Passed in, not read from `booth`: in the mock it hinges on the camera feed,
    /// which this view doesn't observe, so reading it here would go stale.
    let canShoot: Bool

    private var busy: Bool { booth.phase != .idle }

    var body: some View {
        Button {
            Task { await booth.take() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(canShoot && !busy ? 0.9 : 0.3), lineWidth: 3)
                    .frame(width: 56, height: 56)
                Circle()
                    .fill(Color(red: 0.965, green: 0.945, blue: 0.905)
                        .opacity(canShoot && !busy ? 1 : 0.3))
                    .frame(width: 44, height: 44)
                if case .countdown(let count) = booth.phase {
                    Text("\(count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.7))
                        .contentTransition(.numericText(countsDown: true))
                }
            }
        }
        .buttonStyle(ShutterPress())
        .disabled(!canShoot || busy)
        .help("Take a photo — everyone gets a copy")
        .accessibilityLabel("Take a photo")
        .animation(.easeOut(duration: 0.2), value: booth.phase)
    }
}

private struct ShutterPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - This session's shots

private struct SessionStrip: View {
    let shots: [PhotoBoothSession.Shot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From this call")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.inkSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                        MiniPolaroid(shot: shot, tilt: index.isMultiple(of: 2) ? -2.5 : 2.5)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MiniPolaroid: View {
    let shot: PhotoBoothSession.Shot
    let tilt: Double

    var body: some View {
        Button {
            NSWorkspace.shared.open(shot.url)
        } label: {
            VStack(spacing: 0) {
                Image(shot.image, scale: PolaroidComposer.scale, label: Text("Photo"))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipped()
                    .padding(4)
                Spacer(minLength: 0)
            }
            .frame(width: 66, height: 78)
            .background(Color(red: 0.965, green: 0.945, blue: 0.905))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            .rotationEffect(.degrees(tilt))
        }
        .buttonStyle(.plain)
        .help("Open the photo")
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
        }
    }
}

// MARK: - Room overlays

/// The count, big, over the tiles — for everyone, drawer open or not.
struct BoothCountdown: View {
    @ObservedObject var booth: PhotoBoothSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if case .countdown(let count) = booth.phase {
                Text("\(count)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .id(count)
                    .transition(reduceMotion ? .opacity : .scale(scale: 1.5).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: booth.phase)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The flash: everything goes white for a blink, then the picture develops.
struct BoothFlash: View {
    @ObservedObject var booth: PhotoBoothSession

    var body: some View {
        Color.white
            .opacity(booth.phase == .flash ? 0.9 : 0)
            .animation(booth.phase == .flash ? .easeIn(duration: 0.05) : .easeOut(duration: 0.4),
                       value: booth.phase)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}

/// "Saved to Photo Booth", with the photo itself. Click reveals the file.
struct BoothToast: View {
    @ObservedObject var booth: PhotoBoothSession
    let drawerOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let shot = booth.toast, !drawerOpen {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([shot.url])
                } label: {
                    HStack(spacing: 8) {
                        Image(shot.image, scale: PolaroidComposer.scale, label: Text("Photo"))
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text("Saved to Photo Booth")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DesignTokens.ink)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 12)
                    .frame(height: 38)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .overlay(Capsule().strokeBorder(DesignTokens.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                .transition(reduceMotion ? .opacity : .offset(y: -6).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: booth.toast?.id)
    }
}
