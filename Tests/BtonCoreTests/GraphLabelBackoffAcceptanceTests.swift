@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct GraphLabelBackoffAcceptanceTests {
    @Test func aRecentTryBlocksNamingEvenWithoutNames() {
        let now = Date(timeIntervalSince1970: 1_793_365_500)
        let cases: [(triedHoursAgo: Double, labelsExist: Bool, labeledHoursAgo: Double?, reason: String?)] = [
            (1, false, nil, nil),
            (1, true, nil, nil),
            (24, false, nil, "no community names"),
            (25, true, 25, "community names 25 hours old")
        ]
        for test in cases {
            let marker = CodeGraph.Marker(
                commit: "tip", at: now, shape: CodeGraph.shape, memoryAt: nil,
                labeledAt: test.labeledHoursAgo.map { now.addingTimeInterval(-$0 * 3600) },
                labelTriedAt: now.addingTimeInterval(-test.triedHoursAgo * 3600))
            #expect(CodeGraph.labelReason(marker: marker, labelsExist: test.labelsExist, now: now) == test.reason)
        }
    }

    @Test func namingProgressTakesOverAfterExtraction() {
        #expect(CodeGraph.namingLine == "Naming the communities")
        let cases: [(String, String)] = [
            ("", "Preparing the tree"),
            ("AST extraction: 10/10 uncached files\n", "Grouping the code into modules"),
            ("AST extraction: 10/10 uncached files\nNaming the communities (no community names)\n",
             "Naming the communities")
        ]
        for (text, step) in cases {
            #expect(CodeGraph.progress(from: text) == CodeGraph.Progress(step: step, fraction: nil))
        }
    }

    @Test func aFailedRunIsTriedOnceADay() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        let cli = try BackoffLabelCLI(f)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 1)
        #expect(CodeGraph.isBuilt(f.store))
        let first = try #require(CodeGraph.marker(in: f.store))
        #expect(first.commit == f.tip)
        #expect(first.labeledAt == nil)
        let tried = try #require(first.labelTriedAt)
        #expect(abs(tried.timeIntervalSinceNow) < 60)

        // A fresh base commit must rebuild without paying for another failed naming run.
        try Self.ageBuild(f, marker: first, labelTriedAt: tried)
        let secondTip = try await f.commitOnOrigin("second")
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 1)
        let second = try #require(CodeGraph.marker(in: f.store))
        #expect(second.commit == secondTip)
        #expect(second.labeledAt == nil)
        let kept = try #require(second.labelTriedAt)
        #expect(abs(kept.timeIntervalSince(tried)) < 1)

        // Expiring the attempt, rather than the successful-name time, permits the retry.
        let expired = Date.now.addingTimeInterval(-CodeGraphBuilder.labelInterval - 60)
        try Self.ageBuild(f, marker: second, labelTriedAt: expired)
        let thirdTip = try await f.commitOnOrigin("third")
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 2)
        #expect(CodeGraph.marker(in: f.store)?.commit == thirdTip)
    }

    @Test func aSkipSetsNoTryTime() async throws {
        let f = try await GraphFixture.make(python: .succeeds, claude: nil)
        defer { f.remove() }
        let cli = try BackoffLabelCLI(f)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 0)
        let marker = try #require(CodeGraph.marker(in: f.store))
        #expect(marker.commit == f.tip)
        #expect(marker.labelTriedAt == nil)
        #expect(marker.labeledAt == nil)
    }

    private static func ageBuild(_ f: GraphFixture, marker: CodeGraph.Marker, labelTriedAt: Date) throws {
        // The 15-minute rebuild gate must open before the daily naming gate is exercised.
        try CodeGraph.writeMarker(.init(commit: marker.commit, at: marker.at - CodeGraphBuilder.baseRebuildInterval,
                                        shape: marker.shape, memoryAt: marker.memoryAt, labeledAt: nil,
                                        labelTriedAt: labelTriedAt), in: f.store)
    }
}

private struct BackoffLabelCLI {
    let runsFile: URL

    init(_ f: GraphFixture) throws {
        runsFile = f.root.appendingPathComponent("backoff-label-runs")
        let quotedPath = runsFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        set -eu
        printf 'run\\n' >> '\(quotedPath)'
        exit 3
        """
        let path = CodeGraph.cli(python: f.python)
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    func runs() throws -> Int {
        guard FileManager.default.fileExists(atPath: runsFile.path) else { return 0 }
        return try String(contentsOf: runsFile, encoding: .utf8).split(separator: "\n").count
    }
}
