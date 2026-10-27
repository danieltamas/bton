import BtonCore
import Foundation
import Testing

struct CodeGraphConfigAcceptanceTests {
    @Test func repoSwitchDefaultsOff() throws {
        let repo = WatchedRepo(slug: "o/r", path: "/tmp/r")
        #expect(repo.buildsGraph == false)
        let json = try JSONEncoder().encode(repo)
        #expect(!String(decoding: json, as: UTF8.self).contains("codeGraph"))
        let legacy = try JSONDecoder().decode(WatchedRepo.self, from: Data(#"{"slug":"o/r","path":"/tmp/r"}"#.utf8))
        #expect(!legacy.buildsGraph)
    }

    @Test func repoSwitchRoundTrips() throws {
        for enabled in [false, true] {
            var repo = WatchedRepo(slug: "o/r", path: "/tmp/r")
            repo.codeGraph = enabled
            let back = try JSONDecoder().decode(WatchedRepo.self, from: JSONEncoder().encode(repo))
            #expect(back.codeGraph == enabled)
            #expect(back.buildsGraph == enabled)
        }
        var config = BtonConfig.initial
        #expect(config.graphifyPython == nil)
        config.graphifyPython = "/synthetic/graphify/python"
        let back = try JSONDecoder().decode(BtonConfig.self, from: JSONEncoder().encode(config))
        #expect(back.graphifyPython == config.graphifyPython)
    }

    @Test func pythonPrefersConfigured() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try executable(".venvs/graphifyy-arm64/bin/python", home: home)
        #expect(CodeGraph.python(configured: "/usr/bin/true", home: home) == "/usr/bin/true")
    }

    @Test func pythonConfiguredButMissingIsNil() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CodeGraph.python(configured: home.appendingPathComponent("nonexistent/python").path, home: home) == nil)
        let file = home.appendingPathComponent("not-executable")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(CodeGraph.python(configured: file.path, home: home) == nil)
    }

    @Test func pythonFallsBackToVenv() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CodeGraph.python(configured: nil, home: home) == nil)
        let pipx = try executable(".local/pipx/venvs/graphifyy/bin/python", home: home)
        #expect(CodeGraph.python(configured: nil, home: home) == pipx.path)
        let venv = try executable(".venvs/graphifyy-arm64/bin/python", home: home)
        #expect(CodeGraph.python(configured: nil, home: home) == venv.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: venv.path)
        #expect(CodeGraph.python(configured: nil, home: home) == pipx.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bton-graph-config-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(_ path: String, home: URL) throws -> URL {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}
