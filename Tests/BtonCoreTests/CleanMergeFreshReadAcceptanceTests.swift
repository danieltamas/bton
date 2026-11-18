@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CleanMergeFreshReadAcceptanceTests {
    @Test func replacingCloneWithEmptyRepositoryRevokesApproval() async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        try approvalPage(f)
        let client = f.client
        let first = try await f.read(client)
        #expect(first.carriedHeads == [f.a])
        #expect(first.carryRefusal == nil)
        #expect(FlowEngine.move(for: first, flow: try CleanMergeFixture.flow())?.name == "merge")

        try FileManager.default.removeItem(at: f.clone)
        try await CleanMergeFixture.git(f.root, ["init", "--initial-branch=main", f.clone.path])
        #expect(try await CleanMergeFixture.git(f.clone, ["remote"]).isEmpty)
        try await CleanMergeFixture.git(f.clone, ["cat-file", "commit", f.head], status: 128)
        let second = try await f.read(client)
        try CleanMergeFixture.refusal(second, at: f.head)
        let flow = try CleanMergeFixture.flow()
        #expect(FlowEngine.move(for: second, flow: flow)?.name == "review")
        // Isolate the approval predicate so the earlier review rule cannot mask a stale approval.
        let approvalOnly = try MoveWaitFixture.flow(rules: [
            MoveWaitFixture.rule("merge", ["approved_current_head"], who: "author")])
        #expect(FlowEngine.move(for: first, flow: approvalOnly)?.name == "merge")
        #expect(FlowEngine.move(for: second, flow: approvalOnly)?.name == nil)
    }

    @Test func removingUnionAttributeRevokesCarry() async throws {
        let seed = try await CleanMergeFixture.make()
        defer { seed.remove() }
        let f = try await divergentMerge(seed, rename: false)
        let client = f.client
        let first = try await f.read(client)
        #expect(first.carriedHeads == [f.a])
        #expect(first.carryRefusal == nil)

        try FileManager.default.removeItem(at: f.clone.appendingPathComponent(".gitattributes"))
        let conflict = try await CleanMergeFixture.git(f.clone,
            ["merge-tree", "--write-tree", f.a, f.base1], status: 1)
        #expect(conflict.contains("CONFLICT"))
        let second = try await f.read(client)
        #expect(second.carriedHeads == [])
        #expect(second.carryRefusal == "\(CleanMergeFixture.short(f.head)) resolves a conflict by hand")
    }

    @Test func disablingRenamesRevokesCarry() async throws {
        let seed = try await CleanMergeFixture.make()
        defer { seed.remove() }
        let f = try await divergentMerge(seed, rename: true)
        let client = f.client
        let first = try await f.read(client)
        #expect(first.carriedHeads == [f.a])
        #expect(first.carryRefusal == nil)

        try await CleanMergeFixture.git(f.clone, ["config", "merge.renames", "false"])
        let conflict = try await CleanMergeFixture.git(f.clone,
            ["merge-tree", "--write-tree", f.a, f.base1], status: 1)
        #expect(conflict.contains("CONFLICT"))
        let second = try await f.read(client)
        #expect(second.carriedHeads == [])
        #expect(second.carryRefusal == "\(CleanMergeFixture.short(f.head)) resolves a conflict by hand")
    }

    @Test func replacingCloneWithoutBaseTipRevokesRememberedAncestry() async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        try await CleanMergeFixture.git(f.clone, ["branch", "carry-head", f.head])
        try await CleanMergeFixture.git(f.clone, ["checkout", "main"])
        let tip = try await CleanMergeFixture.commit(f.clone, file: "later.txt", text: "later base\n")
        #expect(tip != f.base1)
        try await CleanMergeFixture.git(f.clone, ["merge-base", "--is-ancestor", f.base1, tip])
        try approvalPage(f, base: tip)
        let client = f.client
        let first = try await f.read(client)
        #expect(first.carriedHeads == [f.a])
        #expect(first.carryRefusal == nil)

        let source = f.root.appendingPathComponent("source")
        try FileManager.default.moveItem(at: f.clone, to: source)
        try await CleanMergeFixture.git(f.root,
            ["clone", "--no-local", "--single-branch", "--branch", "carry-head", source.path, f.clone.path])
        try await CleanMergeFixture.git(f.clone, ["remote", "remove", "origin"])
        #expect(try await CleanMergeFixture.git(f.clone, ["remote"]).isEmpty)
        for commit in [f.head, f.a, f.base1] {
            try await CleanMergeFixture.git(f.clone, ["cat-file", "commit", commit])
        }
        try await CleanMergeFixture.git(f.clone, ["cat-file", "commit", tip], status: 128)
        try await CleanMergeFixture.git(f.clone, ["merge-base", "--is-ancestor", f.base1, tip], status: 128)
        let second = try await f.read(client)
        #expect(second.baseSha == tip)
        try CleanMergeFixture.refusal(second, at: f.head)
    }

    @Test func addingUnionAttributeRechecksAnEarlierRefusal() async throws {
        let seed = try await CleanMergeFixture.make()
        defer { seed.remove() }
        let f = try await divergentMerge(seed, rename: false)
        try FileManager.default.removeItem(at: f.clone.appendingPathComponent(".gitattributes"))
        let client = f.client
        let first = try await f.read(client)
        #expect(first.carriedHeads == [])
        #expect(first.carryRefusal == "\(CleanMergeFixture.short(f.head)) resolves a conflict by hand")

        try CleanMergeFixture.write(f.clone, ".gitattributes", "notes.txt merge=union\n")
        let second = try await f.read(client)
        #expect(second.carriedHeads == [f.a])
        #expect(second.carryRefusal == nil)
    }

    /// Freeze one response, including the approval, before either read.
    private func approvalPage(_ f: CleanMergeFixture, base: String? = nil) throws {
        var node = f.node(base: base)
        node["body"] = "Tier: small"
        node["assignees"] = ["nodes": [["login": "reviewer"]]]
        node["comments"] = ["nodes": [["author": ["login": "reviewer"],
            "authorAssociation": "MEMBER", "createdAt": "2026-10-19T12:00:00Z",
            "body": "## Review: approve (head \(f.a))"]]]
        try f.page([node])
    }

    /// Build C from git's successful tree, before changing the clone's merge behavior.
    private func divergentMerge(_ seed: CleanMergeFixture, rename: Bool) async throws -> CleanMergeFixture {
        let clone = seed.clone
        try await CleanMergeFixture.git(clone, ["checkout", "-b", "fresh-root", seed.base0])
        let file = rename ? "old.txt" : "notes.txt"
        let original = (1...8).map { "line \($0)\n" }.joined()
        let root = try await CleanMergeFixture.commit(clone, file: file, text: original)
        try await CleanMergeFixture.git(clone, ["checkout", "-b", "fresh-approved"])
        let a: String
        if rename {
            try await CleanMergeFixture.git(clone, ["mv", "old.txt", "new.txt"])
            try await CleanMergeFixture.git(clone, ["commit", "-m", "Rename approved file"])
            a = try await CleanMergeFixture.git(clone, ["rev-parse", "HEAD"])
        } else {
            a = try await CleanMergeFixture.commit(clone, file: file,
                text: original.replacingOccurrences(of: "line 4\n", with: "approved line\n"))
        }
        try await CleanMergeFixture.git(clone, ["checkout", "-b", "fresh-base", root])
        let b = try await CleanMergeFixture.commit(clone, file: file,
            text: original.replacingOccurrences(of: "line 4\n", with: "base line\n"))
        try await CleanMergeFixture.git(clone, ["checkout", "fresh-approved"])
        if !rename {
            try CleanMergeFixture.write(clone, ".gitattributes", "notes.txt merge=union\n")
            #expect(try await CleanMergeFixture.git(clone, ["ls-files", ".gitattributes"]).isEmpty)
        }
        let tree = try await CleanMergeFixture.git(clone, ["merge-tree", "--write-tree", a, b])
        try #require(tree.count == 40 && tree.allSatisfy(\.isHexDigit))
        let head = try await seed.chosenCommit(tree: tree, parents: [a, b])
        let f = CleanMergeFixture(root: seed.root, clone: clone, origin: seed.origin,
            base0: root, a: a, base1: b, other: seed.other, head: head)
        try approvalPage(f)
        return f
    }
}
