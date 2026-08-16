import SwiftUI

/// The VS Code mark as a monochrome shape; SF Symbols carries no third-party brand glyphs.
struct VSCodeLogo: Shape {
    /// The design box every coordinate below is expressed in.
    private static let designSize: CGFloat = 24

    /// The outer contour, with the mark's sub-pixel corner radii flattened to chords.
    private static let outline: [CGPoint] = [
        CGPoint(x: 23.150, y: 2.587),
        CGPoint(x: 18.210, y: 0.210),
        CGPoint(x: 16.505, y: 0.500),
        CGPoint(x: 7.045, y: 9.130),
        CGPoint(x: 2.925, y: 6.002),
        CGPoint(x: 1.649, y: 6.059),
        CGPoint(x: 0.327, y: 7.261),
        CGPoint(x: 0.326, y: 8.740),
        CGPoint(x: 3.899, y: 12.000),
        CGPoint(x: 0.326, y: 15.260),
        CGPoint(x: 0.327, y: 16.739),
        CGPoint(x: 1.650, y: 17.940),
        CGPoint(x: 2.926, y: 17.997),
        CGPoint(x: 7.046, y: 14.869),
        CGPoint(x: 16.506, y: 23.499),
        CGPoint(x: 18.210, y: 23.789),
        CGPoint(x: 23.152, y: 21.412),
        CGPoint(x: 24.000, y: 20.060),
        CGPoint(x: 24.000, y: 3.939),
    ]

    /// The triangular cutout that makes the mark read as a folded ribbon.
    private static let cutout: [CGPoint] = [
        CGPoint(x: 18.004, y: 17.448),
        CGPoint(x: 10.826, y: 12.000),
        CGPoint(x: 18.004, y: 6.552),
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / Self.designSize
        let dx = rect.minX + (rect.width - side) / 2
        let dy = rect.minY + (rect.height - side) / 2

        var path = Path()
        for contour in [Self.outline, Self.cutout] {
            path.move(to: Self.place(contour[0], scale: scale, dx: dx, dy: dy))
            for point in contour.dropFirst() {
                path.addLine(to: Self.place(point, scale: scale, dx: dx, dy: dy))
            }
            path.closeSubpath()
        }
        return path
    }

    private static func place(
        _ point: CGPoint, scale: CGFloat, dx: CGFloat, dy: CGFloat
    ) -> CGPoint {
        CGPoint(x: dx + point.x * scale, y: dy + point.y * scale)
    }
}
