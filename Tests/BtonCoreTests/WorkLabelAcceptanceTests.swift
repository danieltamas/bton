@testable import BtonCore
import Foundation
import Testing

struct WorkLabelAcceptanceTests {
    @Test func labelNameValidationTable() {
        let valid = ["a", String(repeating: "x", count: 50), "Bton working", "équipe:en/cours-1", String(repeating: "é", count: 50)]
        let invalid = ["", String(repeating: "x", count: 51), "a,b", " leading", "trailing ", "\twork", "work\n", "a\tb", "a\nb", "a\rb", "a\0b", "a\u{7f}b", "a\u{85}b", "\u{a0}work", "work\u{a0}"]
        for name in valid { #expect(WatchedRepo.isLabelName(name), "Expected valid: \(name.debugDescription)") }
        for name in invalid { #expect(!WatchedRepo.isLabelName(name), "Expected invalid: \(name.debugDescription)") }
    }

    @Test func configRoundTripPreservesWorkLabelAndLegacyDefaultsOff() throws {
        var config = try WorkLabelFixture.config()
        #expect(config.repos[0].workLabel == nil)
        config.repos[0].workLabel = "Bton: en cours"
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BtonConfig.self, from: encoded)
        #expect(decoded.repos[0].workLabel == "Bton: en cours")
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let repos = try #require(object["repos"] as? [[String: Any]])
        #expect(repos[0]["workLabel"] as? String == "Bton: en cours")
        config.repos[0].workLabel = nil
        let off = try JSONDecoder().decode(BtonConfig.self, from: JSONEncoder().encode(config))
        #expect(off.repos[0].workLabel == nil)
        let explicitNull = try WorkLabelFixture.config(labelJSON: ",\"workLabel\":null")
        #expect(explicitNull.repos[0].workLabel == nil)
    }

    @Test func labelLookupMatchesWatchedSlugCaseInsensitively() throws {
        var config = try WorkLabelFixture.config()
        config.repos[0].workLabel = "Bton Working"
        #expect(WorkLabels.label(for: "SYNTHETIC-TEAM/DEMO", in: config) == "Bton Working")
        #expect(WorkLabels.label(for: "synthetic-team/other", in: config) == nil)
        config.repos[0].workLabel = nil
        #expect(WorkLabels.label(for: "synthetic-team/demo", in: config) == nil)
    }

    @Test func addLabelSuccessMakesExactlyOneCall() async throws {
        let fixture = try WorkLabelFixture(statuses: [0])
        defer { fixture.remove() }
        try await fixture.github.addLabel(WorkLabelFixture.label, repo: WorkLabelFixture.repo, number: 17)
        #expect(try fixture.calls() == [WorkLabelFixture.edit("--add-label")])
    }

    @Test(arguments: [0, 29])
    func addLabelCreatesThenRetriesEvenWhenCreateFails(createStatus: Int) async throws {
        let fixture = try WorkLabelFixture(statuses: [23, createStatus, 0])
        defer { fixture.remove() }
        try await fixture.github.addLabel(WorkLabelFixture.label, repo: WorkLabelFixture.repo, number: 17)
        #expect(try fixture.calls() == WorkLabelFixture.retryCalls)
    }

    @Test func addLabelSecondFailureThrowsAfterExactRetrySequence() async throws {
        let fixture = try WorkLabelFixture(statuses: [23, 0, 31])
        defer { fixture.remove() }
        var threw = false
        do { try await fixture.github.addLabel(WorkLabelFixture.label, repo: WorkLabelFixture.repo, number: 17) }
        catch { threw = true }
        #expect(threw)
        #expect(try fixture.calls() == WorkLabelFixture.retryCalls)
    }

    @Test func setAddsAndRemovesLabelOnPR() async throws {
        let fixture = try WorkLabelFixture(statuses: [0, 0])
        defer { fixture.remove() }
        let item = try #require(LeaseItem("pr-17"))
        var notes: [String] = []
        await WorkLabels.set(true, label: WorkLabelFixture.label, item: item, repo: WorkLabelFixture.repo,
                             github: fixture.github, note: { notes.append($0) })
        await WorkLabels.set(false, label: WorkLabelFixture.label, item: item, repo: WorkLabelFixture.repo,
                             github: fixture.github, note: { notes.append($0) })
        #expect(try fixture.calls() == [WorkLabelFixture.edit("--add-label"), WorkLabelFixture.edit("--remove-label")])
        #expect(notes.isEmpty)
    }

    @Test func setWithoutLabelOrForNonPRMakesNoCalls() async throws {
        let fixture = try WorkLabelFixture(statuses: [])
        defer { fixture.remove() }
        var notes: [String] = []
        for on in [true, false] {
            for (label, text) in [(nil as String?, "pr-17"), (WorkLabelFixture.label, "schedule-17"), (WorkLabelFixture.label, "issue-17")] {
                await WorkLabels.set(on, label: label, item: try #require(LeaseItem(text)), repo: WorkLabelFixture.repo,
                                     github: fixture.github, note: { notes.append($0) })
            }
        }
        #expect(try fixture.calls().isEmpty)
        #expect(notes.isEmpty)
    }

    @Test(arguments: [true, false])
    func setFailureProducesOneLineNoteWithoutThrowing(on: Bool) async throws {
        let fixture = try WorkLabelFixture(statuses: [23, 29, 31])
        defer { fixture.remove() }
        var notes: [String] = []
        await WorkLabels.set(on, label: WorkLabelFixture.label, item: try #require(LeaseItem("pr-17")),
                             repo: WorkLabelFixture.repo, github: fixture.github, note: { notes.append($0) })
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let multiline = note.contains { $0.isNewline }
        #expect(!multiline)
        #expect(try fixture.calls() == (on ? WorkLabelFixture.retryCalls : [WorkLabelFixture.edit("--remove-label")]))
    }

    @Test func staleFiltersCaseInsensitivelyAndKeepsHeldAndFailedReads() async {
        var reads: [Int] = []
        let prs = [WorkLabelFixture.pr(8, labels: ["unrelated"]), WorkLabelFixture.pr(7, labels: ["BTON WORKING"]),
                   WorkLabelFixture.pr(4, labels: ["bton working"]), WorkLabelFixture.pr(9, labels: ["Bton Working"]),
                   WorkLabelFixture.pr(2, labels: ["Bton Working"]), WorkLabelFixture.pr(3, labels: ["Bton Working extra"])]
        let result = await WorkLabels.stale(prs, label: WorkLabelFixture.label, state: { number in
            reads.append(number)
            switch number {
            case 7: return .free(WorkLabelFixture.record(released: true))
            case 4: return .held(WorkLabelFixture.record(released: false))
            case 9: throw LeaseError.failed("Synthetic read failure")
            default: return .absent
            }
        })
        #expect(reads == [7, 4, 9, 2])
        #expect(result == [7, 2])
    }

    @Test func staleCapsLeaseReadsAtTenIncludingHeldAndFailedReads() async {
        #expect(WorkLabels.maxReadsPerSync == 10)
        var reads: [Int] = []
        let numbers = [31, 12, 25, 14, 29, 16, 27, 18, 23, 20, 99, 98]
        let prs = numbers.flatMap { [WorkLabelFixture.pr($0 + 100, labels: []), WorkLabelFixture.pr($0, labels: [WorkLabelFixture.label])] }
        let result = await WorkLabels.stale(prs, label: WorkLabelFixture.label, state: { number in
            reads.append(number)
            if number == 31 { return .held(WorkLabelFixture.record(released: false)) }
            if number == 12 { throw LeaseError.failed("Synthetic read failure") }
            return .absent
        })
        #expect(reads == Array(numbers.prefix(10)))
        #expect(result == Array(numbers.prefix(10).dropFirst(2)))
    }
}

private struct WorkLabelFixture {
    static let repo = "synthetic-team/demo"
    static let label = "Bton Working"
    let root: URL
    let gh: URL
    let arguments: URL
    var github: GitHubClient { GitHubClient(ghPath: gh.path) }

    init(statuses: [Int]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-work-label-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        gh = root.appendingPathComponent("gh")
        arguments = root.appendingPathComponent("arguments")
        let counter = root.appendingPathComponent("count")
        let cases = statuses.enumerated().map { "\($0.offset + 1)) exit \($0.element) ;;" }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" >> '\(arguments.path)'
        printf '\\036\\n' >> '\(arguments.path)'
        n=0
        if [ -f '\(counter.path)' ]; then read -r n < '\(counter.path)'; fi
        n=$((n + 1))
        printf '%s\\n' "$n" > '\(counter.path)'
        case "$n" in
        \(cases)
        *) exit 97 ;;
        esac
        """
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func calls() throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: arguments.path) else { return [] }
        return try String(contentsOf: arguments, encoding: .utf8).components(separatedBy: "\u{1e}\n")
            .filter { !$0.isEmpty }.map { Array($0.components(separatedBy: "\n").dropLast()) }
    }
    static func edit(_ flag: String) -> [String] { ["pr", "edit", "17", "--repo", repo, flag, label] }
    static var retryCalls: [[String]] {
        [edit("--add-label"), ["label", "create", label, "--repo", repo, "--description", "A Bton is working on this PR"], edit("--add-label")]
    }
    static func config(labelJSON: String = "") throws -> BtonConfig {
        try JSONDecoder().decode(BtonConfig.self, from: Data("""
        {"repos":[{"slug":"synthetic-team/demo"\(labelJSON)}],"pollSeconds":60,"maxAgents":0,"agents":{},"schedules":[]}
        """.utf8))
    }
    static func record(released: Bool) -> LeaseRecord {
        LeaseRecord(holder: "synthetic-worker", host: "synthetic-host", job: UUID(),
                    expires: Date(timeIntervalSince1970: 2_000_000_000), released: released)
    }
    static func pr(_ number: Int, labels: [String]) -> PullRequest {
        PullRequest(repo: repo, number: number, title: "Synthetic PR", author: "synthetic-author",
                    authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/\(number)")!,
                    headSha: "synthetic-head", headRef: "synthetic-branch", baseRef: "main", body: "",
                    isDraft: false, labels: labels, assignees: [], comments: [], updatedAt: Date(timeIntervalSince1970: 1))
    }
}
