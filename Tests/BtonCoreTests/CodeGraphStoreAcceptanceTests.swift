import BtonCore
import Foundation
import Testing

struct CodeGraphStoreAcceptanceTests {
    @Test func storePathIsUnderHome() {
        let home = BtonHome(environment: ["BTON_HOME": "/tmp/h"])
        #expect(CodeGraph.store(for: "Owner/Repo.Name", home: home).path == "/tmp/h/graphs/owner__repo.name")
    }

    @Test func linkMakesSymlinkAndIsIdempotent() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try CodeGraph.link(into: f.checkout, store: f.store) == .linked)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.link.path) == f.store.path)
        try "sentinel".write(to: f.store.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
        #expect(try CodeGraph.link(into: f.checkout, store: f.store) == .alreadyLinked)
        #expect(try String(contentsOf: f.link.appendingPathComponent("graph.json"), encoding: .utf8) == "sentinel")
    }

    @Test func linkMovesExistingGraphIntoEmptyStore() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.link.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "{}".write(to: f.link.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
        try "preserved".write(to: f.link.appendingPathComponent("nested/index"), atomically: true, encoding: .utf8)
        #expect(try CodeGraph.link(into: f.checkout, store: f.store) == .moved)
        #expect(CodeGraph.isBuilt(f.store))
        #expect(try String(contentsOf: f.store.appendingPathComponent("graph.json"), encoding: .utf8) == "{}")
        #expect(try String(contentsOf: f.store.appendingPathComponent("nested/index"), encoding: .utf8) == "preserved")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.link.path) == f.store.path)
    }

    @Test func linkKeepsExistingGraphWhenStoreIsBuilt() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try "{}".write(to: f.store.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.link, withIntermediateDirectories: true)
        try "old".write(to: f.link.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
        guard case let .kept(reason) = try CodeGraph.link(into: f.checkout, store: f.store) else {
            Issue.record("expected kept"); return
        }
        #expect(!reason.isEmpty)
        #expect(try String(contentsOf: f.link.appendingPathComponent("graph.json"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: f.store.appendingPathComponent("graph.json"), encoding: .utf8) == "{}")
        #expect(try FileManager.default.attributesOfItem(atPath: f.link.path)[.type] as? FileAttributeType == .typeDirectory)
    }

    @Test func linkKeepsAFile() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try "x".write(to: f.link, atomically: true, encoding: .utf8)
        guard case .kept = try CodeGraph.link(into: f.checkout, store: f.store) else {
            Issue.record("expected kept"); return
        }
        #expect(try String(contentsOf: f.link, encoding: .utf8) == "x")
    }

    @Test func linkKeepsSymlinkElsewhere() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let elsewhere = f.root.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(at: f.link, withDestinationURL: elsewhere)
        guard case .kept = try CodeGraph.link(into: f.checkout, store: f.store) else {
            Issue.record("expected kept for a symlink elsewhere, including a dangling link"); return
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.link.path) == elsewhere.path)
    }

    @Test func markerRoundTrips() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(CodeGraph.marker(in: f.store) == nil)
        let date = Date(timeIntervalSince1970: 1)
        try CodeGraph.writeMarker(.init(commit: "abc", at: date), in: f.store)
        #expect(CodeGraph.marker(in: f.store)?.commit == "abc")
        #expect(CodeGraph.marker(in: f.store)?.at == date)
        #expect(CodeGraph.isBuilt(f.store) == false)
        let data = try Data(contentsOf: f.store.appendingPathComponent("bton-build.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["commit"] == "abc")
        #expect(json["at"].flatMap { ISO8601DateFormatter().date(from: $0) } == date)
        try "broken".write(to: f.store.appendingPathComponent("bton-build.json"), atomically: true, encoding: .utf8)
        #expect(CodeGraph.marker(in: f.store) == nil)
    }

    private func fixture() throws -> (root: URL, checkout: URL, store: URL, link: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-graph-store-\(UUID())")
            .resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("checkout")
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("home").path])
        let store = CodeGraph.store(for: "synthetic/project", home: home)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        return (root, checkout, store, checkout.appendingPathComponent("graphify-out"))
    }
}
