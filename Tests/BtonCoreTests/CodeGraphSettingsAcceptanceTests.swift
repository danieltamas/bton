import Foundation
import Testing
@testable import BtonCore

struct CodeGraphSettingsAcceptanceTests {
    @Test func configDefaultsAndRoundTrips() throws {
        // A config file written before the two keys existed: today's, with them removed.
        var written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BtonConfig.initial)) as! [String: Any]
        written["codeGraphs"] = nil
        written["graphInstruction"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: written)
        var config = try JSONDecoder().decode(BtonConfig.self, from: legacy)
        #expect(config.codeGraphs == true)
        #expect(config.graphInstruction == nil)

        config.codeGraphs = false
        config.graphInstruction = "x {graph}"
        let decoded = try JSONDecoder().decode(BtonConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.codeGraphs == false)
        #expect(decoded.graphInstruction == "x {graph}")
    }

    @Test func masterSwitchGatesRepoSwitch() {
        var config = BtonConfig.initial
        var repo = WatchedRepo(slug: "acme/widgets", path: nil)
        for enabled in [false, true] {
            config.codeGraphs = enabled
            for repoEnabled: Bool? in [nil, false, true] {
                repo.codeGraph = repoEnabled
                #expect(config.buildsGraph(repo) == (enabled && repoEnabled == true))
            }
        }
    }

    @Test func instructionLineExpandsPlaceholdersAndDefaults() {
        let marker = CodeGraph.Marker(commit: "abcdef1234567890", at: .now)
        #expect(CodeGraph.instructionLine(base: "main", marker: marker,
                                         template: "X {graph} {base} {commit}")
                == "X graphify-out main abcdef12")
        let expected = "Code graph: graphify-out/ in this checkout is graphify's graph of main at abcdef12; this branch's own changes may not be in it. Run graphify-src \"<question>\" before searching the tree."
        #expect(CodeGraph.defaultInstruction == "Code graph: {graph}/ in this checkout is graphify's graph of {base} at {commit}; this branch's own changes may not be in it. Run graphify-src \"<question>\" before searching the tree.")
        #expect(CodeGraph.instructionLine(base: "main", marker: marker) == expected)
        #expect(CodeGraph.instructionLine(base: "main", marker: marker, template: "") == expected)
        #expect(CodeGraph.instructionLine(base: "main", marker: marker, template: " \n\t ") == expected)
    }

    @Test func readinessHonorsMasterSwitch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        var repo = WatchedRepo(slug: "acme/widgets", path: nil)
        repo.codeGraph = true
        #expect(CodeGraph.readiness(of: repo, python: "/usr/bin/true", home: home, enabled: false) == .off)
        #expect(CodeGraph.readiness(of: repo, python: nil, home: home, enabled: false) == .off)
        #expect(CodeGraph.readiness(of: repo, python: "/usr/bin/true", home: home, enabled: true) == .building)
        #expect(CodeGraph.readiness(of: repo, python: nil, home: home, enabled: true) == .missingPython)
    }

    @Test func storedGraphsListsSizesMarkersAndSortedSlugs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        #expect(CodeGraph.storedGraphs(home: home).isEmpty)

        let graphs = root.appendingPathComponent("graphs")
        let widgets = graphs.appendingPathComponent("acme__widgets")
        let nested = widgets.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: widgets.appendingPathComponent("first"))
        try Data([4, 5, 6, 7, 8]).write(to: nested.appendingPathComponent("second"))
        let marker = CodeGraph.Marker(commit: "abcdef1234567890", at: Date(timeIntervalSince1970: 1))
        try CodeGraph.writeMarker(marker, in: widgets)

        let first = try #require(CodeGraph.storedGraphs(home: home).first)
        #expect(CodeGraph.storedGraphs(home: home).count == 1)
        #expect(first.slug == "acme/widgets")
        #expect(first.url == widgets)
        // Every regular file under the store counts, the marker among them.
        let markerBytes = try #require(FileManager.default.attributesOfItem(atPath: widgets.appendingPathComponent("bton-build.json").path)[.size] as? Int64)
        #expect(first.bytes == 8 + markerBytes)
        #expect(first.marker?.commit == marker.commit)

        let zed = graphs.appendingPathComponent("zed__a")
        try FileManager.default.createDirectory(at: zed, withIntermediateDirectories: true)
        let stored = CodeGraph.storedGraphs(home: home)
        #expect(stored.map(\.slug) == ["acme/widgets", "zed/a"])
        #expect(stored.count == 2)
        let last = try #require(stored.last)
        #expect(last.marker == nil)
        #expect(last.bytes == 0)
    }

    @Test func installStepsUseNativePythonAndGraphifyy() {
        #expect(CodeGraph.installVenv == ".venvs/graphifyy-arm64")
        #expect(CodeGraph.installSteps(home: URL(fileURLWithPath: "/Users/x"), uv: "/Users/x/.local/bin/uv") == [
            ["/Users/x/.local/bin/uv", "venv", "--python", "3.12", "/Users/x/.venvs/graphifyy-arm64"],
            ["/Users/x/.local/bin/uv", "pip", "install", "--python", "/Users/x/.venvs/graphifyy-arm64/bin/python", "graphifyy"],
        ])
        #expect(CodeGraph.installPythonFits("True arm64\n", machine: "arm64"))
        #expect(!CodeGraph.installPythonFits("False arm64\n", machine: "arm64"))
        #expect(!CodeGraph.installPythonFits("True x86_64\n", machine: "arm64"))
        #expect(CodeGraph.installSteps(home: URL(fileURLWithPath: "/Users/x"), python: "/usr/bin/python3") == [
            ["/usr/bin/python3", "-m", "venv", "/Users/x/.venvs/graphifyy-arm64"],
            ["/Users/x/.venvs/graphifyy-arm64/bin/python", "-m", "pip", "install", "graphifyy"],
        ])
    }

    @Test func missingDirectorySizeIsZero() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CodeGraph.size(of: root.appendingPathComponent("missing")) == 0)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-graph-settings-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
