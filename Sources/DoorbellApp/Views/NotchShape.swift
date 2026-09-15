import SwiftUI

/// The shell's silhouette. Flush with the screen edge, it flares into it through
/// concave top fillets — the way the hardware notch meets the bezel — and rounds off
/// at the bottom. The path is left open along the top so a stroke draws only the
/// visible outline; fills and clips close it implicitly.
struct NotchShape: Shape {
    var topFillet: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFillet, bottomRadius) }
        set { topFillet = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = max(0, min(topFillet, rect.height / 2))
        let left = rect.minX + f
        let right = rect.maxX - f
        let r = max(0, min(bottomRadius, (right - left) / 2, rect.height - f))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: left, y: rect.minY),
                 tangent2End: CGPoint(x: left, y: rect.minY + f), radius: f)
        p.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: left, y: rect.maxY),
                 tangent2End: CGPoint(x: left + r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: right, y: rect.maxY),
                 tangent2End: CGPoint(x: right, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: right, y: rect.minY + f))
        p.addArc(tangent1End: CGPoint(x: right, y: rect.minY),
                 tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: f)
        return p
    }
}
