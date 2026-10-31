import Foundation
import Testing
@testable import BtonCore

@Suite(ProcessBound())
struct SessionFileLookupAcceptanceTests {
    @Test func projectDirectoryNameReplacesEveryNonASCIIAlphanumericCharacter() {
        #expect(ClaudeSessions.projectDirectoryName(for: "/Users/d/Sites/bton/.worktrees/x")
            == "-Users-d-Sites-bton--worktrees-x")
        #expect(ClaudeSessions.projectDirectoryName(for: "/private/tmp/claude-501/-Users-a")
            == "-private-tmp-claude-501--Users-a")
        #expect(ClaudeSessions.projectDirectoryName(for: "/a/b_c d.e") == "-a-b-c-d-e")
        #expect(ClaudeSessions.projectDirectoryName(for: "/AZaz09/é中_!") == "-AZaz09-----")
    }

    @Test func sessionLookupUsesWorktreeWithoutListingProjectsRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let worktree = "/Users/d/Sites/bton/.worktrees/x"
        let project = directory.appendingPathComponent("-Users-d-Sites-bton--worktrees-x")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let id = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!
        let file = project.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: directory.path)

        #expect(throws: (any Error).self) {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        }
        let found = try #require(ClaudeSessions.sessionFile(id: id, worktree: worktree, projectsRoot: directory))
        #expect(found.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(ClaudeSessions.sessionFile(id: id, worktree: nil, projectsRoot: directory) == nil)
    }

    @Test func sessionLookupFallsBackWhenWorktreeFolderDoesNotContainSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("synthetic-other-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let id = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!
        let file = project.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        try Data().write(to: file)
        let worktree = "/Users/d/Sites/bton/.worktrees/x"

        let found = try #require(ClaudeSessions.sessionFile(id: id, worktree: worktree, projectsRoot: directory))
        #expect(found.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(ClaudeSessions.sessionFile(id: UUID(), worktree: worktree, projectsRoot: directory) == nil)
    }
}
