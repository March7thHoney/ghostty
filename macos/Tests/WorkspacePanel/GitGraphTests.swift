import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitGraphTests {
    private func node(_ sha: String, _ parents: String...) -> GitGraphNode {
        GitGraphNode(sha: sha, parents: parents)
    }

    private func edges(_ row: GitGraphRow, _ kind: GitGraphEdge.Kind) -> [GitGraphEdge] {
        row.edges.filter { $0.kind == kind }
    }

    @Test func linearHistoryStaysInOneLane() {
        let graph = GitGraphBuilder.build([node("a", "b"), node("b", "c"), node("c")])

        #expect(graph.laneCount == 1)
        #expect(graph.rows.map(\.lane) == [0, 0, 0])
        // The tip has nothing above it, and the root has nothing below it.
        #expect(edges(graph.rows[0], .toNode).isEmpty)
        #expect(edges(graph.rows[2], .fromNode).isEmpty)
        #expect(graph.rows[2].openLanes.isEmpty)
    }

    @Test func mergeOpensASecondLaneAndClosesIt() {
        // m forks into a (lane 0) and b (lane 1); both rejoin at the shared parent c.
        let graph = GitGraphBuilder.build([
            node("m", "a", "b"), node("a", "c"), node("b", "c"), node("c"),
        ])

        #expect(graph.laneCount == 2)
        #expect(graph.rows.map(\.lane) == [0, 0, 1, 0])

        // The merge forks: the first parent keeps lane 0, the second opens lane 1.
        #expect(edges(graph.rows[0], .fromNode).map(\.toLane) == [0, 1])
        #expect(graph.rows[0].openLanes == [0, 1])

        // `b` sits in the side lane and bends back into lane 0, where c is already reserved.
        #expect(edges(graph.rows[2], .toNode).map(\.fromLane) == [1])
        #expect(edges(graph.rows[2], .fromNode).map(\.toLane) == [0])
        #expect(graph.rows[2].openLanes == [0])

        #expect(graph.rows[3].openLanes.isEmpty)
    }

    /// Every row must redraw the lanes that merely pass it, or the graph breaks into fragments.
    @Test func passingLanesAreDrawnStraightThrough() {
        let graph = GitGraphBuilder.build([
            node("m", "a", "b"), node("a", "c"), node("b", "c"), node("c"),
        ])

        // The side branch waits in lane 1 while `a` is drawn.
        #expect(edges(graph.rows[1], .through).map(\.fromLane) == [1])
        // The mainline continues past `b`.
        #expect(edges(graph.rows[2], .through).map(\.fromLane) == [0])
    }

    @Test func missingParentLeavesTheLaneOpen() {
        // `y` and `w` are below the page, so both lanes must run off the bottom edge.
        let graph = GitGraphBuilder.build([node("x", "y"), node("z", "w")])

        #expect(graph.laneCount == 2)
        #expect(graph.rows[0].lane == 0)
        #expect(graph.rows[0].openLanes == [0])

        // An unrelated tip takes a fresh lane and the first one passes through beside it.
        #expect(graph.rows[1].lane == 1)
        #expect(edges(graph.rows[1], .through).map(\.fromLane) == [0])
        #expect(graph.rows[1].openLanes == [0, 1])
    }

    @Test func rootCommitClosesItsLane() {
        let graph = GitGraphBuilder.build([node("a", "r"), node("r")])

        #expect(edges(graph.rows[1], .toNode).map(\.fromLane) == [0])
        #expect(edges(graph.rows[1], .fromNode).isEmpty)
        #expect(graph.rows[1].openLanes.isEmpty)
    }

    /// A freed column must be refilled before the graph widens, or long pages creep sideways.
    @Test func freedLanesAreReusedBeforeWidening() {
        let graph = GitGraphBuilder.build([
            node("m", "a", "b"), node("a"), node("b", "c"), node("c"), node("d", "e"),
        ])

        // `a` is a root that frees lane 0, so the later tip `d` lands back in it.
        #expect(graph.rows[4].lane == 0)
        #expect(graph.laneCount == 2)
    }

    @Test func octopusMergeOpensOneLanePerExtraParent() {
        let graph = GitGraphBuilder.build([node("m", "a", "b", "c")])

        #expect(edges(graph.rows[0], .fromNode).map(\.toLane) == [0, 1, 2])
        #expect(graph.laneCount == 3)
    }

    @Test func edgeColorsFollowTheLaneTheSegmentOccupies() {
        let graph = GitGraphBuilder.build([
            node("m", "a", "b"), node("a", "c"), node("b", "c"), node("c"),
        ])

        // A fork's outgoing segment is tinted by the lane it lands in, not the one it leaves.
        #expect(edges(graph.rows[0], .fromNode).map(\.colorLane) == [0, 1])

        // The side branch's incoming segment keeps its own lane's colour...
        #expect(edges(graph.rows[2], .toNode).map(\.colorLane) == [1])
        // ...while the segment folding it back into the mainline takes the mainline's.
        #expect(edges(graph.rows[2], .fromNode).map(\.colorLane) == [0])
    }

    @Test func emptyInputProducesAnEmptyGraph() {
        let graph = GitGraphBuilder.build([])

        #expect(graph.rows.isEmpty)
        #expect(graph.laneCount == 0)
    }
}
