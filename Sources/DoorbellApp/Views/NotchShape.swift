import SwiftUI

/// The shell's silhouette: a rounded rectangle with its own radius top and bottom.
/// At rest the top is square and hidden inside the hardware notch; open, all four
/// corners round off and the shell reads as one clean card at the top of the screen.
/// Both radii animate, so the card grows out of the notch without a seam.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width / 2, rect.height / 2)
        let t = max(0, min(topRadius, limit))
        let b = max(0, min(bottomRadius, limit))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + t))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.minX + t, y: rect.minY), radius: t)
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.maxX, y: rect.minY + t), radius: t)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - b, y: rect.maxY), radius: b)
        p.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.maxY - b), radius: b)
        p.closeSubpath()
        return p
    }
}
