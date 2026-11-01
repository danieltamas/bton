@testable import BtonCore
import Foundation
import Testing

/// An issue labelled to stay open (`verify:prod`) stays open when a PR that says `Fixes #n`
/// merges: the merge move turns that keyword into `Refs` in the PR's body first, asks GitHub
/// again what the merge closes, and refuses to merge when it cannot tell or the issue would
/// still close.
@Suite(ProcessBound())
struct KeepOpenAcceptanceTests {
    private let repo = "owner/repo"

    @Test func everyClosingFormOfThisRepoIsFoundAndOthersAreNot() {
        let body = """
        Fixes #673, closes: #5 and Resolved owner/repo#9.
        fixed https://github.com/owner/repo/issues/12
        Fixes
        #77
        Refs #2, prefixes #3, fixes other/repo#4, fixes #15x, see #16.
        """
        #expect(KeepOpen.references(in: body, repo: repo) == [673, 5, 9, 12, 77])
    }

    @Test func onlyTheKeptIssuesKeywordChangesAndTheReferenceStays() {
        let body = "## Change\n\nFixes #673 (option A), closes #5.\nCloses:  #673 again.\nRefs #2.\n"
        let kept = KeepOpen.neutralised(body, keeping: [673], repo: repo)
        #expect(kept == "## Change\n\nRefs #673 (option A), closes #5.\nRefs:  #673 again.\nRefs #2.\n")
        #expect(KeepOpen.neutralised(body, keeping: [], repo: repo) == body)
        #expect(KeepOpen.references(in: kept, repo: repo) == [5])
    }

    @Test func theFlowNamesTheLabelsAndRefusesAnEmptyList() throws {
        var flow = try #require(JSONSerialization.jsonObject(with: FlowFixture.data("team")) as? [String: Any])
        guard case let .ready(team) = Flow.load(try JSONSerialization.data(withJSONObject: flow)) else {
            Issue.record("the team example must load"); return
        }
        #expect(team.keepOpen?.labels == ["verify:prod"])
        flow["keepOpen"] = ["labels": [" "]]
        guard case let .invalid(message) = Flow.load(try JSONSerialization.data(withJSONObject: flow)) else {
            Issue.record("an empty label must be invalid"); return
        }
        #expect(message.contains("keepOpen.labels"))
        flow["keepOpen"] = nil
        guard case let .ready(without) = Flow.load(try JSONSerialization.data(withJSONObject: flow)) else {
            Issue.record("a flow without the key must load"); return
        }
        #expect(without.keepOpen == nil)
    }

    @Test func closingReferencesDecodeWithTheirLabelsAndRefuseACutList() throws {
        let json = #"{"data":{"repository":{"pullRequest":{"body":"Fixes #1","closingIssuesReferences":{"totalCount":2,"nodes":[{"number":1,"labels":{"nodes":[{"name":"verify:prod"}]}},{"number":2,"labels":{"nodes":[]}}]}}}}}"#
        let read = try GitHubClient.decodeClosingReferences(Data(json.utf8))
        #expect(read.body == "Fixes #1")
        #expect(read.issues == [.init(number: 1, labels: ["verify:prod"]), .init(number: 2, labels: [])])
        let cut = json.replacingOccurrences(of: "\"totalCount\":2", with: "\"totalCount\":51")
        #expect(throws: GitHubClient.Failure.self) { try GitHubClient.decodeClosingReferences(Data(cut.utf8)) }
    }

    @Test func theFeatureJobLinksIssuesWithRefs() {
        let prompt = FeatureJob.prompt(repo: repo, base: "develop", branch: "bton/features-1", tier: "feature", loads: true)
        #expect(prompt.contains("only as `Refs #n`, never after `fixes`, `closes` or `resolves`"))
    }

    @Test func theMergeRewritesTheKeptIssuesKeywordAndRunsTheCommand() async throws {
        let fixture = try await KeepOpenRunFixture.make()
        defer { fixture.cleanup() }
        let id = try await fixture.start()
        let job = try await fixture.finished(id)
        #expect(job.status == .succeeded, "\(job.detail ?? "")")
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path), "the merge command ran")
        #expect(fixture.edited == "Refs\n#673\nRefs #2\ncloses #5\n")
        #expect(fixture.ghCalls.contains("pr edit 7 --repo \(fixture.pr.repo) --body-file"))
        #expect(fixture.log(id).contains("kept open: #673 (verify:prod)"))
        // The order: the head read, GitHub's closing references, the edit, then the command.
        let calls = fixture.ghCalls
        let head = try #require(calls.range(of: "--json headRefOid"))
        let closing = try #require(calls.range(of: "closingIssuesReferences"))
        let edit = try #require(calls.range(of: "pr edit"))
        #expect(head.lowerBound < closing.lowerBound && closing.lowerBound < edit.lowerBound)
        #expect(calls.components(separatedBy: "closingIssuesReferences").count == 4, "read before, right before the save, and after it")
    }

    @Test func aReadThatFailsRefusesTheMerge() async throws {
        let fixture = try await KeepOpenRunFixture.make()
        defer { fixture.cleanup() }
        try Data().write(to: fixture.root.appendingPathComponent("closing-fails"))
        let id = try await fixture.start()
        let job = try await fixture.finished(id)
        #expect(job.status == .failed)
        #expect(job.detail == "could not read what the PR closes before the merge; nothing was run")
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path), "the merge command must not run")
        #expect(!fixture.ghCalls.contains("pr edit"), "the body is not rewritten either")
    }

    @Test func anIssueGitHubWouldStillCloseAfterTheRewriteRefusesTheMerge() async throws {
        let fixture = try await KeepOpenRunFixture.make()
        defer { fixture.cleanup() }
        try Data().write(to: fixture.root.appendingPathComponent("closing-still"))
        let id = try await fixture.start()
        let job = try await fixture.finished(id)
        #expect(job.status == .failed)
        #expect(job.detail == "#673 would still close on merge after the rewrite: edit the PR's body by hand; nothing was run")
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path), "the merge command must not run")
    }

    @Test func aBodyThatClosesNothingKeptIsMergedAsItIs() async throws {
        let fixture = try await KeepOpenRunFixture.make()
        defer { fixture.cleanup() }
        try "Refs #673\ncloses #5\n".write(to: fixture.root.appendingPathComponent("pr-body"), atomically: true, encoding: .utf8)
        let id = try await fixture.start()
        let job = try await fixture.finished(id)
        #expect(job.status == .succeeded, "\(job.detail ?? "")")
        #expect(!fixture.ghCalls.contains("pr edit"))
        #expect(fixture.log(id).contains("the merge closes #5: none is labelled to stay open"))
    }
}

/// A merge move whose command is a script, with a gh stub that answers the head read, GitHub's
/// closing references (computed from the body file as one string, a line break after the keyword
/// included, as GitHub does) and the body edit, and
/// records every call. `closing-fails` makes the references read fail; `closing-still` makes
/// GitHub list #673 whatever the body says.
private struct KeepOpenRunFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let pr: PullRequest

    var root: URL { base.leases.root }
    var marker: URL { root.appendingPathComponent("marker") }
    var edited: String { (try? String(contentsOf: root.appendingPathComponent("edited"), encoding: .utf8)) ?? "" }
    var ghCalls: String { (try? String(contentsOf: root.appendingPathComponent("gh-seen"), encoding: .utf8)) ?? "" }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        do {
            let runner = ProcessRunner()
            let pushed = try await runner.run("/usr/bin/git",
                ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(120))
            try #require(pushed.status == 0, "PR ref setup: \(pushed.stderr)")
            let head = try await runner.run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(120))
            try #require(head.status == 0)
            let sha = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var pr = PullRequest(repo: base.leases.repo, number: 7, title: "Synthetic PR", author: "owner",
                authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
                headSha: sha, headRef: "feature", baseRef: "main", body: "stale copy: Fixes #673", isDraft: false,
                labels: [], assignees: [], comments: [], updatedAt: .now)
            pr.mergeable = true
            try "Fixes\n#673\nRefs #2\ncloses #5\n".write(to: base.leases.root.appendingPathComponent("pr-body"),
                                                        atomically: true, encoding: .utf8)
            let gh = base.leases.root.appendingPathComponent("gh")
            let original = try String(contentsOf: gh, encoding: .utf8)
            let handler = #"""
            cd "$(dirname "$0")"
            printf '%s\n' "$*" >> gh-seen
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              printf '{"headRefOid":"%s","state":"OPEN"}' "$HEAD_SHA"
              exit 0
            fi
            if [ "${1-}" = pr ] && [ "${2-}" = edit ]; then
              while [ $# -gt 0 ]; do [ "$1" = --body-file ] && { cp "$2" edited; cp "$2" pr-body; }; shift; done
              exit 0
            fi
            case "$*" in
              *closingIssuesReferences*)
                [ -f closing-fails ] && { echo "gh: boom" >&2; exit 1; }
                body=$(awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); print $0 "\\n"}' pr-body)
                nums=$(tr '\n' ' ' < pr-body | grep -oiE '(^|[^a-z])(fix(es|ed)?|close[sd]?|resolve[sd]?):? *#[0-9]+' | grep -oE '[0-9]+$' | sort -un)
                [ -f closing-still ] && nums="673 $nums"
                nodes=""
                for n in $nums; do
                  if [ "$n" = 673 ]; then l='{"name":"stage:review"},{"name":"verify:prod"}'; else l='{"name":"bug"}'; fi
                  nodes="$nodes${nodes:+,}{\"number\":$n,\"labels\":{\"nodes\":[$l]}}"
                done
                count=$(echo $nums | wc -w | tr -d ' ')
                printf '{"data":{"repository":{"pullRequest":{"body":"%s","closingIssuesReferences":{"totalCount":%s,"nodes":[%s]}}}}}' "$body" "$count" "$nodes"
                exit 0;;
            esac
            if [ "${1-}" != api ]; then exit 0; fi
            """#
            try original.replacingOccurrences(of: "set -eu", with: "set -eu\nHEAD_SHA=\(sha)\n" + handler)
                .write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            let github = GitHubClient(ghPath: gh.path)
            let remote = base.leases.root.appendingPathComponent("origin.git").path
            let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture",
                github: github, remoteURL: { _ in remote })
            let store = try JobStore(home: base.home)
            return Self(base: base, store: store,
                dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }), pr: pr)
        } catch { try? FileManager.default.removeItem(at: base.leases.root); throw error }
    }

    func start() async throws -> UUID {
        let command = ["/bin/sh", "-c", "touch \"$MARKER\""]
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:"]]], "fixed": "## Fixed:", "moves": [],
            "dispatch": ["merge": ["command": command]],
            "keepOpen": ["labels": ["verify:prod"]]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: "merge", owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: "merge", head: pr.headSha),
            agent: nil, prompt: nil, command: command, postComment: false, timeout: .seconds(20))
        let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow, agents: [:],
            environment: ["MARKER": marker.path])
        guard case .started = outcome else { throw DispatchError.worktree("Fixture job did not start: \(outcome)") }
        return try #require(store.all().first?.id)
    }

    func log(_ id: UUID) -> String { (try? String(contentsOf: store.logURL(id), encoding: .utf8)) ?? "" }

    func finished(_ id: UUID) async throws -> Job {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline, !store.all().contains(where: { $0.id == id && $0.status != .running }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        return try #require(store.all().first { $0.id == id && $0.status != .running }, "Job must finish")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
