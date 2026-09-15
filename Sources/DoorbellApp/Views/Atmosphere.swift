import SwiftUI

/// Depth for black surfaces. Two pieces, both still: a sparse dust of stars so the
/// black is a space rather than a fill, and a doorstep — a soft glass dome rising
/// from the bottom edge that the controls stand on. Neither animates; idle Doorbell
/// costs nothing.

struct Starfield: View {
    /// Overall strength. The board runs it lower than the door and the room.
    var intensity: Double = 1
    var seed: UInt64 = 7

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { ctx, size in
            var rng = SplitMix(seed: seed)
            let count = Int(size.width * size.height / 2800)
            var specs: [(rect: CGRect, alpha: Double, weight: Double)] = []
            specs.reserveCapacity(max(count, 0))
            for _ in 0..<count {
                let x = rng.unit() * size.width
                let y = rng.unit() * size.height
                let r = 0.32 + rng.unit() * 0.42
                let a = (0.03 + pow(rng.unit(), 2.6) * 0.14) * intensity
                specs.append((
                    CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2),
                    a,
                    r * r * a
                ))
            }
            // The three loudest reads as a sky. Dust only.
            specs.sort { $0.weight > $1.weight }
            for spec in specs.dropFirst(3) {
                ctx.fill(Path(ellipseIn: spec.rect), with: .color(.white.opacity(spec.alpha)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The dome: black glass whose crown is `rise` points above the bottom of the view;
/// everything below is clipped by whoever contains it. It is drawn with as little as
/// it can be: one hairline of rim light and a breath of the same light outside it.
/// `lit` lifts both a touch while the door is being worked. Gradients only, no blur:
/// identical on every renderer and free at idle.
struct Doorstep: View {
    var rise: CGFloat
    var lit = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let d = w * 1.75, r = d / 2
            let center = CGPoint(x: w / 2, y: h - rise + r)
            let rim = DesignTokens.horizon
            let haloW = r * 0.08

            ZStack {
                // A breath of light off the rim, gone within a few points.
                Circle()
                    .fill(RadialGradient(
                        stops: [.init(color: .clear, location: r / (r + haloW)),
                                .init(color: rim.opacity(lit ? 0.16 : 0.10), location: r / (r + haloW) + 0.001),
                                .init(color: .clear, location: 1)],
                        center: .center, startRadius: 0, endRadius: r + haloW
                    ))
                    .frame(width: d + haloW * 2, height: d + haloW * 2)
                    .position(center)

                // The glass itself: black, with a hairline where the light catches it.
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            stops: [.init(color: .white.opacity(lit ? 0.60 : 0.45), location: 0),
                                    .init(color: rim.opacity(0.16), location: 0.06),
                                    .init(color: .clear, location: 0.16)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .frame(width: d, height: d)
                    .position(center)
            }
            // Fades from the crown down, so the arc dissolves before it meets the sides.
            .mask(LinearGradient(
                stops: [.init(color: .white, location: 0), .init(color: .clear, location: 1)],
                startPoint: .init(x: 0.5, y: (h - rise) / h), endPoint: .init(x: 0.5, y: 1)
            ))
        }
        .allowsHitTesting(false)
        .animation(DesignTokens.spring, value: lit)
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
