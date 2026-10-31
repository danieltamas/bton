import Foundation
import Testing
@testable import BtonCore

@Suite(ProcessBound())
struct SQLGrammarAcceptanceTests {
    @Test func installPackageIncludesSQLGrammarAndProbeImportsIt() {
        #expect(CodeGraph.installPackage == "graphifyy[sql]")
        #expect(CodeGraph.sqlGrammarProbe == "import tree_sitter_sql")
    }

    @Test func ownedVenvUsesHomeUV() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let python = home.appendingPathComponent(".venvs/graphifyy-arm64/bin/python").path
        let uv = home.appendingPathComponent(".local/bin/uv")
        try FileManager.default.createDirectory(at: uv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: uv.path)
        #expect(CodeGraph.sqlGrammarInstallStep(python: python, home: home) == [
            uv.path, "pip", "install", "--python", python, "graphifyy[sql]",
        ])
    }

    @Test func ownedVenvWithoutHomeUVUsesAvailableInstaller() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let python = home.appendingPathComponent(".venvs/graphifyy-arm64/bin/python").path
        let step = try #require(CodeGraph.sqlGrammarInstallStep(python: python, home: home))
        let systemUV = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        // A system uv is outside the fixture's control, so only require pip when none exists.
        if systemUV.isEmpty {
            #expect(step == [python, "-m", "pip", "install", "graphifyy[sql]"])
        } else {
            #expect(step.last == "graphifyy[sql]")
            #expect(systemUV.contains(try #require(step.first)))
        }
    }

    @Test func personalPythonsHaveNoInstallStep() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let pipx = home.appendingPathComponent(".local/pipx/venvs/graphifyy/bin/python").path
        #expect(CodeGraph.sqlGrammarInstallStep(python: pipx, home: home) == nil)
        #expect(CodeGraph.sqlGrammarInstallStep(python: "/usr/bin/python3", home: home) == nil)
    }

    @Test func availableGrammarBuildsWithoutSQLMessage() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(!f.log.contains { $0.contains("SQL grammar") })
        #expect(CodeGraph.isBuilt(f.store))
    }

    @Test func missingGrammarInPersonalPythonLogsCommandOnceAndStillBuilds() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        let script = try String(contentsOfFile: f.python, encoding: .utf8)
        // Fail only the probe, so a missing optional grammar cannot mask a build failure.
        try #require(script.contains("&& exit 0"))
        try script.replacingOccurrences(of: "&& exit 0", with: "&& exit 1")
            .write(toFile: f.python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.python)
        await f.refresh()
        await f.builder.waitForBuilds()
        await f.refresh()
        await f.builder.waitForBuilds()
        let warnings = f.log.filter {
            $0.hasPrefix("graph \(f.repo.slug): graphify at \(f.python) has no SQL grammar")
        }
        #expect(warnings.count == 1)
        #expect(try #require(warnings.first).contains("graphifyy[sql]"))
        #expect(CodeGraph.isBuilt(f.store))
        #expect(try f.pythonRuns() == 1)
    }

    private func temporaryDirectory() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-sql-grammar-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
}
