import SwiftUI

/// The glass in the door. Same video, two kinds of lens. Fills whatever space it is
/// given; the eyehole takes the largest circle that fits.
struct DoorGlass<Content: View>: View {
    let style: PeepholeStyle
    var emphasized = false
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            switch style {
            case .eyehole:
                GeometryReader { geo in
                    eyehole(diameter: min(geo.size.width, geo.size.height))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .rectangle:
                rectangle
            }
        }
        .animation(DesignTokens.spring, value: emphasized)
    }

    private func eyehole(diameter d: CGFloat) -> some View {
        content
            // A real peephole magnifies a little and bows the middle.
            .scaleEffect(1.14)
            .frame(width: d, height: d)
            .clipShape(Circle())
            .overlay(
                // Dark at the rim, clear in the centre.
                Circle().fill(
                    RadialGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.55),
                            .init(color: .black.opacity(0.55), location: 0.85),
                            .init(color: .black.opacity(0.95), location: 1.0),
                        ],
                        center: .center, startRadius: 0, endRadius: d / 2
                    )
                )
            )
            .overlay(
                // Specular catch on the glass, upper left.
                Ellipse()
                    .fill(.white.opacity(0.12))
                    .frame(width: d * 0.28, height: d * 0.10)
                    .rotationEffect(.degrees(-32))
                    .offset(x: -d * 0.22, y: -d * 0.30)
                    .blur(radius: 3)
            )
            .overlay(
                // One hairline of rim light, lit from the top.
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), DesignTokens.horizon.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.5
                )
            )
            .overlay(
                Circle().strokeBorder(.black.opacity(0.9), lineWidth: 1).padding(1.5)
            )
            .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
            // Listening: the glass comes forward a little. The same light, not a colour.
            .shadow(color: DesignTokens.horizon.opacity(emphasized ? 0.22 : 0), radius: 14)
    }

    private var rectangle: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.glassRadius, style: .continuous)
        return content
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30), DesignTokens.hairline],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            ))
            .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
            .shadow(color: DesignTokens.horizon.opacity(emphasized ? 0.20 : 0), radius: 12)
            .frame(maxWidth: .infinity)
    }
}
