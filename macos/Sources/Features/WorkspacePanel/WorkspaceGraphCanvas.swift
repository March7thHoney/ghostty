import SwiftUI

/// Geometry and colors for the graph gutter, shared by commit rows and their expanded children.
enum GitGraphStyle {
    /// Fixed, because the lines have to meet exactly at every row boundary.
    static let rowHeight: CGFloat = 42

    /// The shorter rows of an expanded file list, which only carry lanes through.
    static let childRowHeight: CGFloat = 22

    static let laneWidth: CGFloat = 9
    static let leadingInset: CGFloat = 7
    static let lineWidth: CGFloat = 1.5
    static let dotRadius: CGFloat = 3

    /// Any wider and the commit text has nowhere to go in a 320pt panel.
    static let maxLanes = 8

    /// The gutter width for a page, which shrinks with the graph rather than reserving the maximum.
    static func gutterWidth(laneCount: Int) -> CGFloat {
        leadingInset + CGFloat(min(max(laneCount, 1), maxLanes)) * laneWidth
    }

    /// A lane's centre line; deeper lanes are clamped so a freak graph cannot widen the panel.
    static func x(_ lane: Int) -> CGFloat {
        leadingInset + CGFloat(min(lane, maxLanes - 1)) * laneWidth + laneWidth / 2
    }

    /// Mid-lightness hues that hold up on both a white and a near-black terminal background.
    static func color(lane: Int, scheme: ColorScheme) -> Color {
        let palette = scheme == .dark ? darkPalette : lightPalette
        return palette[lane % palette.count]
    }

    // Green and red are deliberately absent: the panel already spends them on added and removed lines.
    private static let darkPalette: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 0.94),
        Color(red: 0.89, green: 0.65, blue: 0.31),
        Color(red: 0.68, green: 0.55, blue: 0.90),
        Color(red: 0.36, green: 0.75, blue: 0.68),
        Color(red: 0.90, green: 0.51, blue: 0.60),
        Color(red: 0.62, green: 0.76, blue: 0.40),
    ]

    private static let lightPalette: [Color] = [
        Color(red: 0.16, green: 0.42, blue: 0.80),
        Color(red: 0.72, green: 0.45, blue: 0.08),
        Color(red: 0.45, green: 0.32, blue: 0.74),
        Color(red: 0.08, green: 0.52, blue: 0.47),
        Color(red: 0.76, green: 0.24, blue: 0.40),
        Color(red: 0.38, green: 0.52, blue: 0.16),
    ]

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// One commit row's slice of the gutter, drawn as a single layer rather than a view per line.
struct WorkspaceGraphCanvas: View {
    let row: GitGraphRow
    let laneCount: Int
    let isHead: Bool
    let isMerge: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let center = CGPoint(x: GitGraphStyle.x(row.lane), y: size.height / 2)

            context.drawLayer { layer in
                for edge in row.edges { stroke(edge, into: &layer, height: size.height) }
                // Punching the hole inside the same layer is what makes a hollow dot actually hollow.
                layer.blendMode = .destinationOut
                layer.fill(
                    GitGraphStyle.circle(center, GitGraphStyle.dotRadius + 1.5),
                    with: .color(.black))
            }

            drawNode(at: center, into: &context)
        }
        .frame(width: GitGraphStyle.gutterWidth(laneCount: laneCount))
        .allowsHitTesting(false)
    }

    private func stroke(_ edge: GitGraphEdge, into context: inout GraphicsContext, height: CGFloat) {
        let mid = height / 2
        let span: (CGFloat, CGFloat)
        switch edge.kind {
        case .toNode: span = (0, mid)
        case .fromNode: span = (mid, height)
        case .through: span = (0, height)
        }

        let startX = GitGraphStyle.x(edge.fromLane)
        let endX = GitGraphStyle.x(edge.toLane)

        var path = Path()
        path.move(to: CGPoint(x: startX, y: span.0))
        if startX == endX {
            // Most segments are straight, and a line is cheaper to rasterize than a curve.
            path.addLine(to: CGPoint(x: endX, y: span.1))
        } else {
            // Both controls sit on the span's midline, so each end leaves tangent to its own lane.
            let midY = (span.0 + span.1) / 2
            path.addCurve(
                to: CGPoint(x: endX, y: span.1),
                control1: CGPoint(x: startX, y: midY),
                control2: CGPoint(x: endX, y: midY))
        }

        context.stroke(
            path,
            with: .color(GitGraphStyle.color(lane: edge.colorLane, scheme: scheme)),
            lineWidth: GitGraphStyle.lineWidth)
    }

    private func drawNode(at center: CGPoint, into context: inout GraphicsContext) {
        let color = GitGraphStyle.color(lane: row.lane, scheme: scheme)
        let radius = GitGraphStyle.dotRadius

        if isMerge {
            // A hollow dot marks a merge at a glance, without spending row width on a badge.
            context.stroke(
                GitGraphStyle.circle(center, radius), with: .color(color), lineWidth: 1.8)
        } else {
            context.fill(GitGraphStyle.circle(center, radius), with: .color(color))
        }

        // The ring reads as "you are here" and fits around both the solid and the hollow dot.
        if isHead {
            context.stroke(
                GitGraphStyle.circle(center, radius + 2.5),
                with: .color(color.opacity(0.55)),
                lineWidth: 1.2)
        }
    }
}

/// The gutter beneath an expanded commit: just the lanes that are still open, carried straight down.
struct WorkspaceGraphLaneStrip: View {
    let lanes: [Int]
    let laneCount: Int

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            for lane in lanes {
                var path = Path()
                path.move(to: CGPoint(x: GitGraphStyle.x(lane), y: 0))
                path.addLine(to: CGPoint(x: GitGraphStyle.x(lane), y: size.height))
                context.stroke(
                    path,
                    with: .color(GitGraphStyle.color(lane: lane, scheme: scheme)),
                    lineWidth: GitGraphStyle.lineWidth)
            }
        }
        .frame(width: GitGraphStyle.gutterWidth(laneCount: laneCount))
        .allowsHitTesting(false)
    }
}
