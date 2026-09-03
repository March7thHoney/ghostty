import SwiftUI

/// The GitHub mark as a monochrome shape; SF Symbols carries no third-party brand glyphs.
struct GitHubLogo: Shape {
    /// The design box every coordinate below is expressed in.
    private static let designSize: CGFloat = 24

    private enum Segment {
        case move(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
    }

    /// The mark's outline as absolute cubic curves, ending where it started.
    private static let segments: [Segment] = [
        .move(CGPoint(x: 12.000, y: 0.297)),
        .curve(CGPoint(x: 0.000, y: 12.297), CGPoint(x: 5.370, y: 0.297), CGPoint(x: 0.000, y: 5.670)),
        .curve(CGPoint(x: 8.205, y: 23.682), CGPoint(x: 0.000, y: 17.600), CGPoint(x: 3.438, y: 22.097)),
        .curve(CGPoint(x: 9.025, y: 23.105), CGPoint(x: 8.805, y: 23.795), CGPoint(x: 9.025, y: 23.424)),
        .curve(CGPoint(x: 9.010, y: 21.065), CGPoint(x: 9.025, y: 22.820), CGPoint(x: 9.015, y: 22.065)),
        .curve(CGPoint(x: 4.968, y: 19.455), CGPoint(x: 5.672, y: 21.789), CGPoint(x: 4.968, y: 19.455)),
        .curve(CGPoint(x: 3.633, y: 17.700), CGPoint(x: 4.422, y: 18.070), CGPoint(x: 3.633, y: 17.700)),
        .curve(CGPoint(x: 3.717, y: 16.971), CGPoint(x: 2.546, y: 16.956), CGPoint(x: 3.717, y: 16.971)),
        .curve(CGPoint(x: 5.555, y: 18.207), CGPoint(x: 4.922, y: 17.055), CGPoint(x: 5.555, y: 18.207)),
        .curve(CGPoint(x: 9.050, y: 19.205), CGPoint(x: 6.625, y: 20.042), CGPoint(x: 8.364, y: 19.512)),
        .curve(CGPoint(x: 9.810, y: 17.600), CGPoint(x: 9.158, y: 18.429), CGPoint(x: 9.467, y: 17.900)),
        .curve(CGPoint(x: 4.344, y: 11.670), CGPoint(x: 7.145, y: 17.300), CGPoint(x: 4.344, y: 16.268)),
        .curve(CGPoint(x: 5.579, y: 8.450), CGPoint(x: 4.344, y: 10.360), CGPoint(x: 4.809, y: 9.290)),
        .curve(CGPoint(x: 5.684, y: 5.274), CGPoint(x: 5.444, y: 8.147), CGPoint(x: 5.039, y: 6.927)),
        .curve(CGPoint(x: 8.984, y: 6.504), CGPoint(x: 5.684, y: 5.274), CGPoint(x: 6.689, y: 4.952)),
        .curve(CGPoint(x: 11.984, y: 6.099), CGPoint(x: 9.944, y: 6.237), CGPoint(x: 10.964, y: 6.105)),
        .curve(CGPoint(x: 14.984, y: 6.504), CGPoint(x: 13.004, y: 6.105), CGPoint(x: 14.024, y: 6.237)),
        .curve(CGPoint(x: 18.269, y: 5.274), CGPoint(x: 17.264, y: 4.952), CGPoint(x: 18.269, y: 5.274)),
        .curve(CGPoint(x: 18.389, y: 8.450), CGPoint(x: 18.914, y: 6.927), CGPoint(x: 18.509, y: 8.147)),
        .curve(CGPoint(x: 19.619, y: 11.670), CGPoint(x: 19.154, y: 9.290), CGPoint(x: 19.619, y: 10.360)),
        .curve(CGPoint(x: 14.144, y: 17.590), CGPoint(x: 19.619, y: 16.280), CGPoint(x: 16.814, y: 17.295)),
        .curve(CGPoint(x: 14.954, y: 19.810), CGPoint(x: 14.564, y: 17.950), CGPoint(x: 14.954, y: 18.686)),
        .curve(CGPoint(x: 14.939, y: 23.096), CGPoint(x: 14.954, y: 21.416), CGPoint(x: 14.939, y: 22.706)),
        .curve(CGPoint(x: 15.764, y: 23.666), CGPoint(x: 14.939, y: 23.411), CGPoint(x: 15.149, y: 23.786)),
        .curve(CGPoint(x: 24.000, y: 12.297), CGPoint(x: 20.565, y: 22.092), CGPoint(x: 24.000, y: 17.592)),
        .curve(CGPoint(x: 12.000, y: 0.297), CGPoint(x: 24.000, y: 5.670), CGPoint(x: 18.627, y: 0.297)),
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / Self.designSize
        let dx = rect.minX + (rect.width - side) / 2
        let dy = rect.minY + (rect.height - side) / 2

        var path = Path()
        for segment in Self.segments {
            switch segment {
            case .move(let point):
                path.move(to: Self.place(point, scale: scale, dx: dx, dy: dy))
            case .curve(let end, let control1, let control2):
                path.addCurve(
                    to: Self.place(end, scale: scale, dx: dx, dy: dy),
                    control1: Self.place(control1, scale: scale, dx: dx, dy: dy),
                    control2: Self.place(control2, scale: scale, dx: dx, dy: dy))
            }
        }
        path.closeSubpath()
        return path
    }

    private static func place(
        _ point: CGPoint, scale: CGFloat, dx: CGFloat, dy: CGFloat
    ) -> CGPoint {
        CGPoint(x: dx + point.x * scale, y: dy + point.y * scale)
    }
}
