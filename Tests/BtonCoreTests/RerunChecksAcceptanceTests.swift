@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct RerunChecksAcceptanceTests {
    @Test func failedRunsKeepsOnlyRetryableConclusionsInOrder() throws {
        let data = Data("""
        [{"databaseId":1,"workflowName":"gate","conclusion":"failure"},
         {"databaseId":2,"workflowName":"lint","conclusion":"success"},
         {"databaseId":3,"workflowName":"e2e","conclusion":"cancelled"},
         {"databaseId":4,"workflowName":"docs","conclusion":"skipped"},
         {"databaseId":5,"workflowName":"slow","conclusion":"timed_out"},
         {"databaseId":6,"workflowName":"advisory","conclusion":"neutral"},
         {"databaseId":7,"workflowName":"boot","conclusion":"startup_failure"}]
        """.utf8)
        let runs = try GitHubClient.failedRuns(data)
        #expect(runs.map(\.id) == [1, 3, 5, 7])
        #expect(runs.map(\.workflow) == ["gate", "e2e", "slow", "boot"])
    }

    @Test func rerunFailedRunsListsExactCommitThenRerunsFailuresInOrder() async throws {
        let fixture = try RerunChecksFixture(list: RerunChecksFixture.mixedRuns)
        defer { fixture.remove() }
        let workflows = try await GitHubClient(ghPath: fixture.gh.path)
            .rerunFailedRuns(repo: "owner/a", sha: "abc123")
        #expect(workflows == ["gate", "e2e"])
        #expect(try fixture.calls() == [
            RerunChecksFixture.listArguments,
            ["run", "rerun", "1", "--repo", "owner/a", "--failed"],
            ["run", "rerun", "3", "--repo", "owner/a", "--failed"]
        ])
    }

    @Test func rerunFailedRunsThrowsNoFailedRunWithShaWithoutRerunning() async throws {
        let fixture = try RerunChecksFixture(list: """
        [{"databaseId":2,"workflowName":"lint","conclusion":"success"}]
        """)
        defer { fixture.remove() }
        do {
            _ = try await GitHubClient(ghPath: fixture.gh.path)
                .rerunFailedRuns(repo: "owner/a", sha: "abc123")
            Issue.record("Expected noFailedRun")
        } catch let GitHubClient.Failure.noFailedRun(sha) {
            #expect(sha == "abc123")
        }
        #expect(try fixture.calls() == [RerunChecksFixture.listArguments])
    }

    @Test func rerunFailedRunsThrowsGhFailedOnNonzeroRerunExit() async throws {
        let fixture = try RerunChecksFixture(list: RerunChecksFixture.mixedRuns, rerunStatus: 23)
        defer { fixture.remove() }
        do {
            _ = try await GitHubClient(ghPath: fixture.gh.path)
                .rerunFailedRuns(repo: "owner/a", sha: "abc123")
            Issue.record("Expected ghFailed")
        } catch let GitHubClient.Failure.ghFailed(status, stderr) {
            #expect(status == 23)
            #expect(stderr == "Synthetic rerun failure\n")
        }
        #expect(try fixture.calls() == [
            RerunChecksFixture.listArguments,
            ["run", "rerun", "1", "--repo", "owner/a", "--failed"]
        ])
    }
}

private struct RerunChecksFixture {
    let root: URL
    let gh: URL
    let arguments: URL

    static let mixedRuns = """
    [{"databaseId":1,"workflowName":"gate","conclusion":"failure"},{"databaseId":2,"workflowName":"lint","conclusion":"success"},{"databaseId":3,"workflowName":"e2e","conclusion":"cancelled"}]
    """
    static let listArguments = ["run", "list", "--repo", "owner/a", "--commit", "abc123",
                                "--limit", "50", "--json", "databaseId,workflowName,conclusion"]

    init(list: String, rerunStatus: Int = 0) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-rerun-checks-\(UUID())")
        gh = root.appendingPathComponent("gh")
        arguments = root.appendingPathComponent("arguments")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" >> '\(arguments.path)'
        printf '\\n' >> '\(arguments.path)'
        case "$1:$2" in
            run:list)
                cat <<'JSON'
        \(list)
        JSON
                ;;
            run:rerun)
                if [ '\(rerunStatus)' -ne 0 ]; then
                    printf 'Synthetic rerun failure\\n' >&2
                fi
                exit \(rerunStatus)
                ;;
            *) echo 'Unexpected synthetic gh invocation' >&2; exit 91 ;;
        esac
        """
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
    }

    func calls() throws -> [[String]] {
        try String(contentsOf: arguments, encoding: .utf8)
            .components(separatedBy: "\n\n")
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\n") }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
