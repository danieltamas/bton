@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CleanMergeAcceptanceTests {
    private let a = String(repeating: "a", count: 40)
    private let b = String(repeating: "b", count: 40)
    private let m = String(repeating: "c", count: 40)
    private func short(_ sha: String) -> String { CleanMergeFixture.short(sha) }

    @Test(arguments: [false, true], [false, true])
    func onlyVerifiedCarriedHeadsAuthorizeApproval(carried: Bool, abbreviated: Bool) throws {
        let flow = try CleanMergeFixture.flow()
        let review = abbreviated ? short(a) : a
        var pr = try FlowFixture.pr(tier: "small", head: m, comments: [.init(body: "## Review: approve (head \(review))")])
        pr.mergeOnlyAncestors = [a, b]
        pr.carriedHeads = carried ? [a] : []
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == (carried ? "merge" : "review"))
        let reason = "the approval of \(short(a)) does not carry to \(short(m)): no clean merge of the base leads to it"
        #expect(FlowEngine.uncarriedApproval(of: pr, flow: flow) == (carried ? nil : reason))
        if !carried {
            pr.carryRefusal = "x"
            #expect(FlowEngine.move(for: pr, flow: flow)?.name == "review")
            #expect(FlowEngine.uncarriedApproval(of: pr, flow: flow) ==
                "the approval of \(short(a)) does not carry to \(short(m)): x")
        }
    }

    @Test(arguments: [false, true])
    func changesNeverReportAnUncarriedApproval(carried: Bool) throws {
        let flow = try CleanMergeFixture.flow()
        var pr = try FlowFixture.pr(tier: "small", head: m, comments: [.init(body: "## Review: changes (head \(a))")])
        pr.mergeOnlyAncestors = [a, b]
        pr.carriedHeads = carried ? [a] : []
        if carried { #expect(FlowEngine.move(for: pr, flow: flow)?.name == "fix") }
        #expect(FlowEngine.uncarriedApproval(of: pr, flow: flow) == nil)
    }

    @Test func ordinaryNewCommitAsksForReviewWithoutCarryWarning() throws {
        let flow = try CleanMergeFixture.flow()
        let pr = try FlowFixture.pr(tier: "small", head: m, comments: [.init(body: "## Review: approve (head \(a))")])
        #expect(pr.baseSha == nil)
        #expect(pr.carriedHeads.isEmpty)
        #expect(pr.carryRefusal == nil)
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "review")
        #expect(FlowEngine.uncarriedApproval(of: pr, flow: flow) == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func directHeadApprovalAlwaysCounts(carried: Bool, claimed: Bool) throws {
        let flow = try CleanMergeFixture.flow()
        var pr = try FlowFixture.pr(tier: "small", head: m, comments: [.init(body: "## Review: approve (head \(m))")])
        pr.carriedHeads = carried ? [a] : []
        pr.mergeOnlyAncestors = claimed ? [a, b] : []
        pr.carryRefusal = "a previous merge was refused"
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "merge")
        #expect(FlowEngine.uncarriedApproval(of: pr, flow: flow) == nil)
    }

    @Test(arguments: ["present", "absent", "null"])
    func decodeRecordsBaseTipButNeverTrustsMergeClaim(base: String) throws {
        var node = CleanMergeFixture.node(head: m, base: b, parents: [a, b])
        if base == "absent" { node.removeValue(forKey: "baseRef") }
        if base == "null" { node["baseRef"] = NSNull() }
        let result = try GitHubClient.decodeOpenPullRequests(CleanMergeFixture.payload([node]), repo: "o/r")
        let pr = try #require(result.pullRequests.first)
        #expect(pr.baseSha == (base == "present" ? b : nil))
        #expect(!pr.mergeOnlyAncestors.isEmpty)
        #expect(pr.carriedHeads.isEmpty)
        #expect(pr.carryRefusal == nil)
    }

    @Test func queryRequestsTheBaseTargetOid() {
        #expect(GitHubClient.openPullRequestsQuery.range(
            of: #"\bbaseRef\s*\{\s*target\s*\{\s*oid\b"#, options: .regularExpression) != nil)
    }

    @Test func onlyTheLatestReviewCanExplainAnUncarriedApproval() throws {
        let flow = try CleanMergeFixture.flow()
        for latest in ["changes", "approve"] {
            let reviewed = latest == "changes" ? a : b
            var pr = try FlowFixture.pr(tier: "small", head: m, comments: [
                .init(body: "## Review: approve (head \(a))", hour: 12),
                .init(body: "## Review: \(latest) (head \(reviewed))", hour: 13)])
            pr.mergeOnlyAncestors = [a]
            #expect(FlowEngine.uncarriedApproval(of: pr, flow: flow) == nil)
        }
    }

    @Test func cleanMergeAndLaterBaseTipCarryApproval() async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        let first = try await f.read()
        #expect(first.carriedHeads == [f.a])
        #expect(first.carryRefusal == nil)
        try await CleanMergeFixture.git(f.clone, ["checkout", "main"])
        let base2 = try await CleanMergeFixture.commit(f.clone, file: "base2.txt", text: "later base\n")
        try f.page([f.node(base: base2)])
        let later = try await f.read()
        #expect(later.carriedHeads == [f.a])
        #expect(later.carryRefusal == nil)
    }

    @Test(arguments: [false, true])
    func remoteOnlyMergeFetchPreservesCloneState(existingFetchHead: Bool) async throws {
        let f = try await CleanMergeFixture.make(remoteOnly: true)
        defer { f.remove() }
        try await CleanMergeFixture.git(f.clone, ["cat-file", "-t", f.head], status: 128)
        let fetchHead = f.clone.appendingPathComponent(".git/FETCH_HEAD")
        if existingFetchHead { try Data("sentinel fetch head\n".utf8).write(to: fetchHead) }
        else { #expect(!FileManager.default.fileExists(atPath: fetchHead.path)) }
        try CleanMergeFixture.write(f.clone, "staged.txt", "staged content\n")
        try await CleanMergeFixture.git(f.clone, ["add", "staged.txt"])
        try CleanMergeFixture.write(f.clone, "a.txt", "local uncommitted edit\n")
        let refs = try await CleanMergeFixture.git(f.clone, ["for-each-ref"])
        let status = try await CleanMergeFixture.git(f.clone, ["status", "--porcelain"])
        let index = try Data(contentsOf: f.clone.appendingPathComponent(".git/index"))
        let before = try? Data(contentsOf: fetchHead)
        let pr = try await f.read()
        #expect(pr.carriedHeads == [f.a])
        #expect(pr.carryRefusal == nil)
        #expect(try await CleanMergeFixture.git(f.clone, ["for-each-ref"]) == refs)
        #expect(try Data(contentsOf: f.clone.appendingPathComponent(".git/index")) == index)
        #expect(try await CleanMergeFixture.git(f.clone, ["status", "--porcelain"]) == status)
        #expect((try? Data(contentsOf: fetchHead)) == before)
        #expect(try String(contentsOf: f.clone.appendingPathComponent("a.txt"), encoding: .utf8) == "local uncommitted edit\n")
        #expect(try String(contentsOf: f.clone.appendingPathComponent("staged.txt"), encoding: .utf8) == "staged content\n")
    }

    @Test(arguments: [false, true])
    func mergeChainKeepsOnlyVerifiedLinks(broken: Bool) async throws {
        let f = try await CleanMergeFixture.make(conflict: broken)
        defer { f.remove() }
        let next = try await f.nextMerge(2)
        try f.page([f.node(head: next.head, base: next.base, parents: [f.head, next.base])])
        let pr = try await f.read()
        #expect(pr.carriedHeads == (broken ? [f.head] : [f.head, f.a]))
        #expect(pr.carryRefusal == (broken ? "\(short(f.head)) resolves a conflict by hand" : nil))
    }

    @Test func conflictResolutionCannotCarryApproval() async throws {
        let f = try await CleanMergeFixture.make(conflict: true)
        defer { f.remove() }
        let pr = try await f.read()
        #expect(pr.carriedHeads.isEmpty)
        #expect(pr.carryRefusal == "\(short(f.head)) resolves a conflict by hand")
    }

    @Test(arguments: ["ordinary", "replace", "lying-parents"])
    func editedMergeCannotCarryApprovalEvenWithMisleadingMetadata(mode: String) async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        let edited = try await f.editedMerge()
        if mode == "replace" { try await CleanMergeFixture.git(f.clone, ["replace", edited, f.head]) }
        let parents = mode == "lying-parents" ? [f.base1, f.a] : [f.a, f.base1]
        try f.page([f.node(head: edited, parents: parents)])
        let pr = try await f.read()
        #expect(pr.carriedHeads.isEmpty)
        #expect(pr.carryRefusal == "\(short(edited)) is not git's own merge of its parents")
    }

    @Test(arguments: ["other", "swapped", "octopus"])
    func onlyTwoParentsWithBaseSecondCanCarryApproval(shape: String) async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        let parents: [String]
        let tree: String
        if shape == "other" {
            try await CleanMergeFixture.git(f.clone, ["checkout", "-b", "attack", f.a])
            try await CleanMergeFixture.git(f.clone, ["merge", "--no-ff", "-m", "Other branch", f.other])
            tree = try await CleanMergeFixture.git(f.clone, ["rev-parse", "HEAD^{tree}"])
            parents = [f.a, f.other]
        } else {
            tree = try await CleanMergeFixture.git(f.clone, ["rev-parse", "\(f.head)^{tree}"])
            parents = shape == "swapped" ? [f.base1, f.a] : [f.a, f.base1, f.other]
        }
        let head = try await f.chosenCommit(tree: tree, parents: parents)
        try f.page([f.node(head: head, parents: parents)])
        let pr = try await f.read()
        #expect(pr.carriedHeads.isEmpty)
        let reason = shape == "octopus" ? "\(short(head)) has 3 parents" :
            "\(short(head)) merges \(short(parents[1])), which is not in main"
        #expect(pr.carryRefusal == reason)
    }

    @Test(arguments: ["octopus", "conflict", "edited"])
    func refusalPrecedenceWinsOverWrongBase(kind: String) async throws {
        let f = try await CleanMergeFixture.make(conflict: kind != "edited")
        defer { f.remove() }
        let head: String
        let parents: [String]
        let reason: String
        if kind == "octopus" {
            let tree = try await CleanMergeFixture.git(f.clone, ["rev-parse", "\(f.head)^{tree}"])
            parents = [f.a, f.base1, f.other]
            head = try await f.chosenCommit(tree: tree, parents: parents)
            reason = "has 3 parents"
        } else {
            head = kind == "edited" ? try await f.editedMerge() : f.head
            parents = [f.a, f.base1]
            reason = kind == "edited" ? "is not git's own merge of its parents" : "resolves a conflict by hand"
        }
        try f.page([f.node(head: head, base: f.base0, parents: parents)])
        let pr = try await f.read()
        #expect(pr.carriedHeads.isEmpty)
        #expect(pr.carryRefusal == "\(short(head)) \(reason)")
    }

    @Test(arguments: ["clone", "base", "both", "not-repository"])
    func missingPrerequisitesFailClosedWithOrderedReasons(missing: String) async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        var node = f.node()
        if missing == "base" || missing == "both" { node["baseRef"] = NSNull() }
        try f.page([node])
        let empty = f.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let clone: URL? = (missing == "clone" || missing == "both") ? nil :
            (missing == "not-repository" ? empty : f.clone)
        let result = try await f.client.openPullRequests(repo: "synthetic/project", clone: clone)
        let pr = try #require(result.pullRequests.first)
        try CleanMergeFixture.refusal(pr, at: f.head)
        if missing != "not-repository" {
            let reason = missing == "base" ? "GitHub did not name the tip of main" : "no clone of the repo on this Mac"
            #expect(pr.carryRefusal == "could not check \(short(f.head)): \(reason)")
        }
    }

    @Test func failedFetchIsRetriedOnTheNextRead() async throws {
        let f = try await CleanMergeFixture.make(remoteOnly: true)
        defer { f.remove() }
        let client = f.client
        try await CleanMergeFixture.git(f.clone, ["remote", "set-url", "origin", f.root.appendingPathComponent("absent.git").path])
        try CleanMergeFixture.refusal(try await f.read(client), at: f.head)
        try await CleanMergeFixture.git(f.clone, ["remote", "set-url", "origin", f.origin.path])
        let recovered = try await f.read(client)
        #expect(recovered.carriedHeads == [f.a])
        #expect(recovered.carryRefusal == nil)
    }

    @Test(arguments: [false, true])
    func retargetChecksTheBaseOnEveryRead(allowedFirst: Bool) async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        try await CleanMergeFixture.git(f.clone, ["checkout", "-b", "attack", f.a])
        try await CleanMergeFixture.git(f.clone, ["merge", "--no-ff", "-m", "Other", f.other])
        let head = try await CleanMergeFixture.git(f.clone, ["rev-parse", "HEAD"])
        let client = f.client
        for allowed in [allowedFirst, !allowedFirst] {
            try f.page([f.node(head: head, base: allowed ? f.other : f.base1,
                branch: allowed ? "other" : "main", parents: [f.a, f.other])])
            let pr = try await f.read(client)
            #expect(pr.carriedHeads == (allowed ? [f.a] : []))
            #expect(pr.carryRefusal == (allowed ? nil : "\(short(head)) merges \(short(f.other)), which is not in main"))
        }
    }

    @Test func rewoundBaseInvalidatesEarlierCarry() async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        let client = f.client
        #expect(try await f.read(client).carriedHeads == [f.a])
        try f.page([f.node(base: f.base0)])
        let pr = try await f.read(client)
        #expect(pr.carriedHeads.isEmpty)
        #expect(pr.carryRefusal == "\(short(f.head)) merges \(short(f.base1)), which is not in main")
    }

    @Test func oneParentNeedsNoCloneCheck() async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        try f.page([f.node(head: f.a, parents: [f.base0])])
        let empty = f.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let result = try await f.client.openPullRequests(repo: "synthetic/project", clone: empty)
        let pr = try #require(result.pullRequests.first)
        #expect(pr.mergeOnlyAncestors.isEmpty)
        #expect(pr.carriedHeads.isEmpty)
        #expect(pr.carryRefusal == nil)
    }

    @Test(arguments: ["option", "short"])
    func invalidHeadCannotBecomeAGitOption(kind: String) async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        let marker = f.root.appendingPathComponent("injected")
        let head = kind == "option" ? "--upload-pack=touch \(marker.path)" : String(repeating: "d", count: 39)
        try f.page([f.node(head: head)])
        let pr = try await f.read()
        try CleanMergeFixture.refusal(pr, at: head)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: ["--upload-pack=x", String(repeating: "d", count: 39)])
    func invalidBaseTipFailsClosed(base: String) async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        try f.page([f.node(base: base)])
        try CleanMergeFixture.refusal(try await f.read(), at: f.head)
    }

    @Test(arguments: [false, true])
    func repeatedReadPreservesCleanAndConflictingVerdicts(conflict: Bool) async throws {
        let f = try await CleanMergeFixture.make(conflict: conflict)
        defer { f.remove() }
        let client = f.client
        for _ in 0..<2 {
            let pr = try await f.read(client)
            #expect(pr.carriedHeads == (conflict ? [] : [f.a]))
            #expect(pr.carryRefusal == (conflict ? "\(short(f.head)) resolves a conflict by hand" : nil))
        }
    }

    @Test(arguments: [false, true])
    func missingObjectDoesNotPoisonAnotherPR(missingFirst: Bool) async throws {
        let f = try await CleanMergeFixture.make(remoteOnly: true)
        defer { f.remove() }
        let missing = String(repeating: "d", count: 40)
        let bad = f.node(head: missing, number: 8)
        try f.page(missingFirst ? [bad, f.node()] : [f.node(), bad])
        let result = try await f.client.openPullRequests(repo: "synthetic/project", clone: f.clone)
        #expect(result.pullRequests.count == 2)
        let good = try #require(result.pullRequests.first { $0.number == 7 })
        #expect(good.carriedHeads == [f.a])
        #expect(good.carryRefusal == nil)
        try CleanMergeFixture.refusal(try #require(result.pullRequests.first { $0.number == 8 }), at: missing)
    }

    @Test(arguments: [10, 11])
    func walkStopsAtTenVerifiedLinks(length: Int) async throws {
        let f = try await CleanMergeFixture.make()
        defer { f.remove() }
        var heads = [f.a, f.head]
        var base = f.base1
        for index in 2...length {
            let next = try await f.nextMerge(index)
            heads.append(next.head)
            base = next.base
        }
        let head = try #require(heads.last)
        try f.page([f.node(head: head, base: base, parents: [heads[heads.count - 2], base])])
        let pr = try await f.read()
        let expected = Array(heads.dropLast().reversed().prefix(10))
        #expect(pr.carriedHeads == expected)
        #expect(pr.carriedHeads.count == 10)
        #expect(pr.carriedHeads.contains(f.a) == (length == 10))
        #expect(pr.carryRefusal == (length == 10 ? nil :
            "could not check \(short(try #require(expected.last))): more than 10 merge commits in a row"))
    }
}
