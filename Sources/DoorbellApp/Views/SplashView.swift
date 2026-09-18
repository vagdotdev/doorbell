import SwiftUI

/// The intro. The board opens on a black sky; the doorstep dome rises from the floor;
/// your friends surface through its glass as small peepholes and float up into a plume
/// while "Doorbell" comes into focus. Then every peephole glides to its place in the
/// building and the sky clears. Plays each time the board opens. Click anywhere to skip.
///
/// Built from what the shell already has — starfield, doorstep, avatars — so it costs
/// nothing new to draw. Under Reduce Motion the plume is skipped and it fades.
struct SplashView: View {
    let me: Profile
    let friends: [Profile]
    let geometry: NotchGeometry
    let namespace: Namespace.ID

    @EnvironmentObject private var state: NotchState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false
    @State private var wordmark = false
    @State private var line = false
    @State private var placed: Set<String> = []
    @State private var finishing = false

    /// How long the plume holds before it settles, from the board opening.
    static let holdUntil: Duration = .milliseconds(2300)
    private static let rise: CGFloat = DesignTokens.doorstepRise
    private static let maxFriends = 8

    private var people: [Profile] { [me] + Array(friends.prefix(Self.maxFriends)) }
    private var size: CGSize { geometry.size(for: .board) }
    private var settling: Bool { state.splash == .settling }

    var body: some View {
        ZStack {
            // The sky clears while the peepholes are still in flight; they land on the
            // building's own avatars, which take over the moment the splash is done.
            ZStack {
                Color.black
                Starfield(intensity: 0.9, seed: 3)
                Doorstep(rise: risen ? Self.rise : 0, lit: !settling)
                copy
            }
            .opacity(settling ? 0 : 1)
            plume
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
        .task { await play() }
        .onDisappear {
            // Closed mid-intro: it has not been seen, so it plays again next time.
            if state.splash == .playing { state.splash = .pending }
        }
    }

    // MARK: Copy

    private var copy: some View {
        VStack(spacing: 6) {
            Text("Doorbell")
                .font(.system(size: 22, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(DesignTokens.ink)
                .blur(radius: wordmark ? 0 : 12)
                .opacity(wordmark ? 1 : 0)
            Text(friends.isEmpty ? "Your building. Add a friend." : "Knock, knock.")
                .font(.system(size: 11.5))
                .foregroundStyle(DesignTokens.inkSecondary)
                .blur(radius: line ? 0 : 10)
                .opacity(line ? 1 : 0)
        }
        .position(x: size.width / 2, y: geometry.notchHeight + 52)
        .allowsHitTesting(false)
    }

    // MARK: Plume

    private var plume: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: settling || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    peephole(person, index: index, time: t)
                }
            }
        }
    }

    private func peephole(_ person: Profile, index: Int, time t: TimeInterval) -> some View {
        let isPlaced = placed.contains(person.id)
        let home = home(for: index)
        let crown = CGPoint(x: size.width / 2, y: size.height - Self.rise + 6)
        let side = diameter(for: index)
        // A slow, individual breath once the peephole has settled into the plume.
        let breath: CGFloat = isPlaced && !settling && !reduceMotion
            ? CGFloat(sin(t * (0.9 + 0.13 * Double(index)) + Double(index) * 1.7)) * 2.2
            : 0

        return AvatarView(profile: person, size: side)
            .overlay {
                // The lens: a vignette, a dark bezel, a hairline of the one light, a
                // glint. All of it lifts as the face lands on its card.
                ZStack {
                    Circle().fill(RadialGradient(
                        colors: [.clear, .black.opacity(0.42)],
                        center: .center, startRadius: side * 0.28, endRadius: side * 0.5))
                    Circle().strokeBorder(.black, lineWidth: 2.5)
                    Circle().strokeBorder(DesignTokens.horizon.opacity(0.55), lineWidth: 1)
                    Circle().fill(.white.opacity(0.7))
                        .frame(width: 3, height: 3)
                        .offset(x: -side * 0.28, y: -side * 0.3)
                }
                .opacity(settling ? 0 : 1)
            }
            .matchedGeometryEffect(id: "avatar-\(person.id)", in: namespace, isSource: !settling)
            .scaleEffect(isPlaced ? 1 : 0.3)
            .opacity(isPlaced ? 1 : 0)
            .position(x: isPlaced ? home.x : crown.x, y: (isPlaced ? home.y : crown.y) + breath)
    }

    /// Where a peephole rests: you on the crown, friends fanning up and out on
    /// alternate sides — a plume, narrow at the base and open at the top.
    private func home(for index: Int) -> CGPoint {
        let crownY = size.height - Self.rise
        guard index > 0 else { return CGPoint(x: size.width / 2, y: crownY - 30) }
        let n = max(people.count - 1, 1)
        let t = CGFloat(index) / CGFloat(n + 1)
        let sideSign: CGFloat = index.isMultiple(of: 2) ? 1 : -1
        let x = size.width / 2 + sideSign * (36 + 152 * t)
        let y = crownY - 44 - 118 * t
        return CGPoint(x: x, y: y)
    }

    private func diameter(for index: Int) -> CGFloat {
        guard index > 0 else { return 46 }
        var h: UInt32 = 2166_136_261
        for b in people[index].handle.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return [34, 39, 44][Int(h % 3)]
    }

    // MARK: Timeline

    private func play() async {
        state.splash = .playing
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { risen = true; wordmark = true; line = true }
            placed = Set(people.map(\.id))
            try? await Task.sleep(for: .milliseconds(900))
            finish()
            return
        }
        let start = ContinuousClock.now
        withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) { risen = true }
        try? await Task.sleep(for: .milliseconds(160))
        withAnimation(.easeOut(duration: 0.55)) { wordmark = true }
        try? await Task.sleep(for: .milliseconds(220))
        for person in people {
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.72, dampingFraction: 0.7)) { _ = placed.insert(person.id) }
            try? await Task.sleep(for: .milliseconds(75))
        }
        try? await Task.sleep(for: .milliseconds(240))
        withAnimation(.easeOut(duration: 0.45)) { line = true }
        try? await Task.sleep(until: start + Self.holdUntil, clock: .continuous)
        guard !Task.isCancelled else { return }
        finish()
    }

    /// Hand the avatars to the building and clear the sky.
    private func finish() {
        guard !finishing else { return }
        finishing = true
        withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) { state.splash = .settling }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            state.splash = .done
        }
    }
}

// MARK: - Onboarding plume

/// Same peephole plume as the notch intro, sized for the onboarding window. No copy.
struct IntroPlumeView: View {
    let me: Profile
    let friends: [Profile]
    var onFinished: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false
    @State private var placed: Set<String> = []
    @State private var finishing = false
    @State private var settling = false

    private static let size = CGSize(width: 480, height: 200)
    private static let rise: CGFloat = 34
    private static let maxFriends = 8

    private var people: [Profile] { [me] + Array(friends.prefix(Self.maxFriends)) }

    var body: some View {
        ZStack {
            ZStack {
                Color.black
                Starfield(intensity: 0.9, seed: 3)
                Doorstep(rise: risen ? Self.rise : 0, lit: !settling)
            }
            .opacity(settling ? 0 : 1)
            plume
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
        .task { await play() }
    }

    private var plume: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: settling || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    peephole(person, index: index, time: t)
                }
            }
        }
    }

    private func peephole(_ person: Profile, index: Int, time t: TimeInterval) -> some View {
        let isPlaced = placed.contains(person.id)
        let home = home(for: index)
        let crown = CGPoint(x: Self.size.width / 2, y: Self.size.height - Self.rise + 6)
        let side = diameter(for: index)
        let breath: CGFloat = isPlaced && !settling && !reduceMotion
            ? CGFloat(sin(t * (0.9 + 0.13 * Double(index)) + Double(index) * 1.7)) * 2.2
            : 0

        return AvatarView(profile: person, size: side)
            .overlay {
                ZStack {
                    Circle().fill(RadialGradient(
                        colors: [.clear, .black.opacity(0.42)],
                        center: .center, startRadius: side * 0.28, endRadius: side * 0.5))
                    Circle().strokeBorder(.black, lineWidth: 2.5)
                    Circle().strokeBorder(DesignTokens.horizon.opacity(0.55), lineWidth: 1)
                    Circle().fill(.white.opacity(0.7))
                        .frame(width: 3, height: 3)
                        .offset(x: -side * 0.28, y: -side * 0.3)
                }
                .opacity(settling ? 0 : 1)
            }
            .scaleEffect(isPlaced ? 1 : 0.3)
            .opacity(isPlaced ? 1 : 0)
            .position(x: isPlaced ? home.x : crown.x, y: (isPlaced ? home.y : crown.y) + breath)
    }

    private func home(for index: Int) -> CGPoint {
        let crownY = Self.size.height - Self.rise
        guard index > 0 else { return CGPoint(x: Self.size.width / 2, y: crownY - 28) }
        let n = max(people.count - 1, 1)
        let t = CGFloat(index) / CGFloat(n + 1)
        let sideSign: CGFloat = index.isMultiple(of: 2) ? 1 : -1
        let x = Self.size.width / 2 + sideSign * (32 + 130 * t)
        let y = crownY - 38 - 100 * t
        return CGPoint(x: x, y: y)
    }

    private func diameter(for index: Int) -> CGFloat {
        guard index > 0 else { return 44 }
        var h: UInt32 = 2166_136_261
        for b in people[index].handle.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return [32, 36, 40][Int(h % 3)]
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { risen = true }
            placed = Set(people.map(\.id))
            try? await Task.sleep(for: .milliseconds(900))
            finish()
            return
        }
        let start = ContinuousClock.now
        withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) { risen = true }
        try? await Task.sleep(for: .milliseconds(200))
        for person in people {
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.72, dampingFraction: 0.7)) { _ = placed.insert(person.id) }
            try? await Task.sleep(for: .milliseconds(75))
        }
        try? await Task.sleep(until: start + SplashView.holdUntil, clock: .continuous)
        guard !Task.isCancelled else { return }
        finish()
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) { settling = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            onFinished?()
        }
    }
}

// MARK: - Shared geometry

/// The building's avatars and the splash's peepholes share one namespace so the intro
/// can hand each face to its card.
struct AvatarNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

/// True while the splash owns the avatars' geometry; the building's own avatars follow.
struct SplashOwnsAvatarsKey: EnvironmentKey {
    static let defaultValue = false
}

/// True while the splash is on screen at all (playing or settling); the building's own
/// avatars stay hidden so the landing peepholes are the only faces visible.
struct SplashOnScreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var avatarNamespace: Namespace.ID? {
        get { self[AvatarNamespaceKey.self] }
        set { self[AvatarNamespaceKey.self] = newValue }
    }
    var splashOwnsAvatars: Bool {
        get { self[SplashOwnsAvatarsKey.self] }
        set { self[SplashOwnsAvatarsKey.self] = newValue }
    }
    var splashOnScreen: Bool {
        get { self[SplashOnScreenKey.self] }
        set { self[SplashOnScreenKey.self] = newValue }
    }
}

extension View {
    /// Pairs this avatar with the splash peephole of the same profile, when there is one.
    func buildingAvatar(_ id: Profile.ID) -> some View {
        modifier(BuildingAvatar(id: id))
    }
}

private struct BuildingAvatar: ViewModifier {
    let id: Profile.ID
    @Environment(\.avatarNamespace) private var namespace
    @Environment(\.splashOwnsAvatars) private var splashOwns
    @Environment(\.splashOnScreen) private var splashOnScreen

    func body(content: Content) -> some View {
        if let namespace {
            content
                .matchedGeometryEffect(id: "avatar-\(id)", in: namespace, isSource: !splashOwns)
                .opacity(splashOnScreen ? 0 : 1)
        } else {
            content
        }
    }
}
