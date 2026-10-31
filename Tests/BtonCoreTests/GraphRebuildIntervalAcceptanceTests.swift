@testable import BtonCore
import Foundation
import Testing

struct GraphRebuildIntervalAcceptanceTests {
    private static let now = Date(timeIntervalSince1970: 1_793_365_500)
    private static let tip = "abcdef0123456789"

    private static func marker(_ commit: String = "other", shape: Int? = CodeGraph.shape,
                               age: TimeInterval, memoryAt: Date? = nil) -> CodeGraph.Marker {
        .init(commit: commit, at: now.addingTimeInterval(-age), shape: shape, memoryAt: memoryAt)
    }

    @Test func baseRebuildIntervalIsFifteenMinutesAndShorterThanMemoryInterval() {
        #expect(CodeGraphBuilder.baseRebuildInterval == 15 * 60)
        #expect(CodeGraphBuilder.baseRebuildInterval < CodeGraphBuilder.memoryRebuildInterval)
    }

    @Test func movedBaseWaitsUntilBaseRebuildInterval() {
        let cases: [(TimeInterval, String?)] = [
            (5 * 60, nil),
            (CodeGraphBuilder.baseRebuildInterval, "base moved to \(Self.tip.prefix(8))"),
            (60 * 60, "base moved to \(Self.tip.prefix(8))")
        ]
        for (age, expected) in cases {
            let reason = GraphMemory.rebuildReason(marker: Self.marker(age: age), built: true,
                                                  tip: Self.tip, memory: nil, now: Self.now)
            if let expected { #expect(reason?.hasPrefix(expected) == true) }
            else { #expect(reason == nil) }
        }
    }

    @Test func rebuildCauseOrderPreservesShapeAndMemoryRules() {
        let old = Self.now.addingTimeInterval(-3600)
        let memory = GraphMemory.State(updatedAt: Self.now, issues: 1, pullRequests: 0)
        let cases: [(CodeGraph.Marker?, Bool, GraphMemory.State?, String?)] = [
            (Self.marker(shape: nil, age: 5 * 60), true, nil, "graph shape"),
            (Self.marker(shape: CodeGraph.shape + 1, age: 5 * 60), true, nil, "graph shape"),
            (nil, false, nil, "no graph"),
            (Self.marker(shape: nil, age: 5 * 60), false, memory, "no graph"),
            (Self.marker(shape: CodeGraph.shape + 1, age: 60 * 60), false, memory, "no graph"),
            (Self.marker(age: 60 * 60), false, nil, "no graph"),
            (Self.marker(Self.tip, age: 30 * 60, memoryAt: old), false, memory, "no graph"),
            (Self.marker(Self.tip, age: 20 * 60, memoryAt: old), true, memory, nil),
            (Self.marker(Self.tip, age: 30 * 60, memoryAt: old), true, memory, "memory newer than the graph")
        ]
        for (marker, built, memory, expected) in cases {
            let reason = GraphMemory.rebuildReason(marker: marker, built: built, tip: Self.tip,
                                                  memory: memory, now: Self.now)
            if let expected {
                if expected == "graph shape" { #expect(reason?.hasPrefix(expected) == true) }
                else { #expect(reason == expected) }
            } else { #expect(reason == nil) }
        }
        #expect(CodeGraphBuilder.memoryRebuildInterval == 30 * 60)
    }
}
