import Foundation

/// The only thing lane assignment needs from a commit, so the algorithm stays independently testable.
struct GitGraphNode: Equatable {
    let sha: String
    let parents: [String]
}

/// One drawable segment of a row, in lane coordinates rather than points.
struct GitGraphEdge: Equatable {
    enum Kind: Equatable {
        /// The row's top edge down to the commit dot.
        case toNode
        /// The commit dot down to the row's bottom edge.
        case fromNode
        /// Top edge straight through to the bottom edge, unrelated to this row's commit.
        case through
    }

    let kind: Kind
    let fromLane: Int
    let toLane: Int

    /// The lane whose color this segment takes, so one branch keeps one hue top to bottom.
    let colorLane: Int
}

/// One commit's place in the graph gutter.
struct GitGraphRow: Equatable {
    let lane: Int
    let edges: [GitGraphEdge]

    /// Lanes still open below this row, so an expanded file list can carry their lines down.
    let openLanes: [Int]
}

/// A page of commits reduced to lane geometry.
struct GitGraph: Equatable {
    static let empty = GitGraph()

    var rows: [GitGraphRow] = []

    /// The widest the graph ever gets, which sizes the gutter for the whole page.
    var laneCount = 0
}

/// Pure lane assignment over topologically ordered commits; no I/O, so it unit tests directly.
enum GitGraphBuilder {
    nonisolated static func build(_ nodes: [GitGraphNode]) -> GitGraph {
        // lanes[i] is the sha that lane is waiting for, or nil when the lane is free.
        var lanes: [String?] = []
        var graph = GitGraph()

        for node in nodes {
            let before = lanes

            // A sha is only ever reserved once, so at most one lane can be waiting for it.
            let incoming = lanes.firstIndex { $0 == node.sha }
            let lane = incoming ?? allocate(&lanes, for: nil)

            var edges: [GitGraphEdge] = []
            if let incoming {
                edges.append(GitGraphEdge(
                    kind: .toNode, fromLane: incoming, toLane: lane, colorLane: incoming))
            }

            // Freed before the parents are placed so a merge's later parents can reuse this column.
            lanes[lane] = nil

            for (index, parent) in node.parents.enumerated() {
                let target: Int
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    target = existing
                } else if index == 0 {
                    // The first parent inherits this commit's lane, so the mainline never drifts sideways.
                    target = lane
                    lanes[lane] = parent
                } else {
                    target = allocate(&lanes, for: parent)
                }
                edges.append(GitGraphEdge(
                    kind: .fromNode, fromLane: lane, toLane: target, colorLane: target))
            }

            // A lane holding the same sha above and below this row is merely passing by.
            for index in lanes.indices {
                let above = index < before.count ? before[index] : nil
                guard above != nil, above == lanes[index] else { continue }
                edges.append(GitGraphEdge(
                    kind: .through, fromLane: index, toLane: index, colorLane: index))
            }

            graph.rows.append(GitGraphRow(
                lane: lane,
                edges: edges,
                openLanes: lanes.indices.filter { lanes[$0] != nil }))
            // lanes only ever grows, so its length is the widest the gutter has had to be.
            graph.laneCount = max(graph.laneCount, lanes.count)
        }

        return graph
    }

    /// The leftmost free column, widening only when every column is taken.
    private static func allocate(_ lanes: inout [String?], for sha: String?) -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) {
            lanes[free] = sha
            return free
        }
        lanes.append(sha)
        return lanes.count - 1
    }
}
