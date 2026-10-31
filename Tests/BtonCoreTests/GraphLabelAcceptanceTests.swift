@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct GraphLabelAcceptanceTests {
    @Test func labelReasonsAndLimitsFollowTheDailyContract() {
        let now = Date(timeIntervalSince1970: 1_793_365_500)
        func marker(_ age: TimeInterval?) -> CodeGraph.Marker {
            .init(commit: "tip", at: now, shape: CodeGraph.shape, memoryAt: nil,
                  labeledAt: age.map { now.addingTimeInterval(-$0) })
        }
        let cases: [(CodeGraph.Marker?, Bool, String?)] = [
            (marker(0), false, "no community names"),
            (nil, true, "community names not made here"),
            (marker(nil), true, "community names not made here"),
            (marker(24 * 3600), true, "community names 24 hours old"),
            (marker(25 * 3600), true, "community names 25 hours old"),
            (marker(3600), true, nil)
        ]
        for (marker, exists, expected) in cases {
            #expect(CodeGraph.labelReason(marker: marker, labelsExist: exists, now: now) == expected)
        }
        #expect(CodeGraphBuilder.labelInterval == 24 * 60 * 60)
        #expect(CodeGraphBuilder.labelTimeout == .seconds(2400))
        #expect(CodeGraphBuilder.labelModel == "haiku")
        #expect(CodeGraph.labelsName == ".graphify_labels.json")
        #expect(CodeGraph.cli(python: "/venv/bin/python") == "/venv/bin/graphify")
    }

    @Test func missingNamesAreMadeInAnIsolatedDirectory() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        let cli = try LabelCLI(f, body: Self.makeNames)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 1)
        // The model is an argument: graphify's labeler takes none from the environment (llm.py, _call_llm).
        #expect(try cli.read("args") == "label --backend=claude-cli --model=haiku")
        // The room is gone after the run and Foundation resolves /private/var only for a path that
        // exists, so its parent (the graphs directory, still there) is compared, then its name.
        let pwd = URL(fileURLWithPath: try cli.read("pwd"))
        #expect(pwd.deletingLastPathComponent().resolvingSymlinksInPath() == f.store.deletingLastPathComponent().resolvingSymlinksInPath())
        #expect(pwd.lastPathComponent == f.store.lastPathComponent + ".label")
        #expect(try cli.read("path").split(separator: ":").first == "/usr/bin")
        #expect(CodeGraph.isBuilt(f.store))
        #expect(CodeGraph.marker(in: f.store)?.commit == f.tip)
        #expect(CodeGraph.marker(in: f.store)?.labeledAt != nil)
        #expect(FileManager.default.fileExists(atPath: f.store.appendingPathComponent(CodeGraph.labelsName).path))
        #expect(f.log.contains { $0.hasPrefix("graph \(f.repo.slug): communities named in") && $0.contains("(no community names)") })
        #expect(!FileManager.default.fileExists(atPath: f.store.path + ".label"))
    }

    @Test func namesYoungerThanADayAreKept() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        let cli = try LabelCLI(f, body: Self.makeNames)
        await f.refresh()
        await f.builder.waitForBuilds()
        let labeledAt = Date.now.addingTimeInterval(-3600)
        try Self.ageBuild(f, labeledAt: labeledAt)
        let tip = try await f.commitOnOrigin("second")
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 1)
        let marker = try #require(CodeGraph.marker(in: f.store))
        let kept = try #require(marker.labeledAt)
        #expect(abs(kept.timeIntervalSince1970 - labeledAt.timeIntervalSince1970) < 1)
        #expect(marker.commit == tip)
    }

    @Test func namesADayOldAreMadeAgain() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        let cli = try LabelCLI(f, body: Self.makeNames)
        await f.refresh()
        await f.builder.waitForBuilds()
        let old = Date.now.addingTimeInterval(-CodeGraphBuilder.labelInterval - 60)
        try Self.ageBuild(f, labeledAt: old)
        let tip = try await f.commitOnOrigin("second")
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 2)
        #expect(CodeGraph.marker(in: f.store)?.commit == tip)
        let labeledAt = try #require(CodeGraph.marker(in: f.store)?.labeledAt)
        #expect(labeledAt > old)
        #expect(f.log.contains { $0.contains("communities named in") && $0.contains("hours old") })
    }

    @Test func aFailedLabelRunStillPublishesTheGraph() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        let cli = try LabelCLI(f, body: "exit 3")
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 1)
        #expect(CodeGraph.isBuilt(f.store))
        #expect(CodeGraph.marker(in: f.store)?.commit == f.tip)
        #expect(CodeGraph.marker(in: f.store)?.labeledAt == nil)
        #expect(!FileManager.default.fileExists(atPath: f.store.appendingPathComponent(CodeGraph.labelsName).path))
        #expect(f.log.contains { $0.hasPrefix("graph \(f.repo.slug): communities not named (exit 3)") })
    }

    @Test func missingClaudeIsReportedOnceAcrossBuilds() async throws {
        let f = try await GraphFixture.make(python: .succeeds, claude: nil)
        defer { f.remove() }
        let cli = try LabelCLI(f, body: Self.makeNames)
        await f.refresh()
        await f.builder.waitForBuilds()
        try Self.ageBuild(f, labeledAt: nil)
        let tip = try await f.commitOnOrigin("second")
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try cli.runs() == 0)
        #expect(f.log.filter { $0 == "graph \(f.repo.slug): communities not named: the claude CLI is not on PATH" }.count == 1)
        #expect(CodeGraph.isBuilt(f.store))
        #expect(CodeGraph.marker(in: f.store)?.commit == tip)
    }

    @Test func missingGraphifyCLIIsReportedOnceAcrossBuilds() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        await f.refresh()
        await f.builder.waitForBuilds()
        try Self.ageBuild(f, labeledAt: nil)
        let tip = try await f.commitOnOrigin("second")
        await f.refresh()
        await f.builder.waitForBuilds()
        let expected = "graph \(f.repo.slug): communities not named: graphify's CLI not found at \(CodeGraph.cli(python: f.python))"
        #expect(f.log.filter { $0 == expected }.count == 1)
        #expect(CodeGraph.isBuilt(f.store))
        #expect(CodeGraph.marker(in: f.store)?.commit == tip)
    }

    private static let makeNames = "printf '%s\\n' '{}' > graphify-out/.graphify_labels.json"

    private static func ageBuild(_ f: GraphFixture, labeledAt: Date?) throws {
        let built = try #require(CodeGraph.marker(in: f.store))
        // A moved base must be eligible to rebuild before naming can be considered again.
        try CodeGraph.writeMarker(.init(commit: built.commit, at: built.at - CodeGraphBuilder.baseRebuildInterval,
                                        shape: built.shape, memoryAt: built.memoryAt, labeledAt: labeledAt), in: f.store)
    }
}

private struct LabelCLI {
    let root: URL

    init(_ f: GraphFixture, body: String) throws {
        root = f.root
        let prefix = root.appendingPathComponent("label-").path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        set -eu
        printf 'run\\n' >> '\(prefix)runs'
        printf '%s\\n' "$PWD" > '\(prefix)pwd'
        printf '%s\\n' "$*" > '\(prefix)args'
        printf '%s\\n' "$PATH" > '\(prefix)path'
        \(body)
        """
        let path = CodeGraph.cli(python: f.python)
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("label-" + name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runs() throws -> Int {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("label-runs").path) else { return 0 }
        return try read("runs").split(separator: "\n").count
    }
}
