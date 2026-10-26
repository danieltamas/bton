import BtonCore
import Foundation
import Testing

@Test(ProcessBound()) func decodesOpenPullRequestsFromGraphQL() throws {
    let data = try FlowFixture.graphql(labels: ["turn:lead"], assignees: ["dev-b"], comments: [
        .init(body: "## Review: changes needed (head d67db2a8)\n\n| ID | ...", author: "dev-b")
    ])
    let result = try GitHubClient.decodeOpenPullRequests(data, repo: "o/r")
    #expect(result.viewer == "lead-dev")
    #expect(result.defaultBranch == "main")
    #expect(result.pullRequests.count == 1)
    let pr = try #require(result.pullRequests.first)
    #expect(pr.id == "o/r#325")
    #expect(pr.repo == "o/r")
    #expect(pr.number == 325)
    #expect(pr.title == "Synthetic PR")
    #expect(pr.author == "dev-b")
    #expect(pr.authorAssociation == "OWNER")
    #expect(pr.url.absoluteString == "https://github.com/o/r/pull/325")
    #expect(pr.headSha == FlowFixture.head)
    #expect(pr.headRef == "feat/x")
    #expect(pr.baseRef == "develop")
    #expect(pr.body == "**Tier:** feature")
    #expect(!pr.isDraft)
    #expect(pr.labels == ["turn:lead"])
    #expect(pr.assignees == ["dev-b"])
    #expect(pr.move == nil)
    #expect(pr.updatedAt == ISO8601DateFormatter().date(from: "2026-10-19T11:00:00Z"))
    #expect(pr.comments.count == 1)
    #expect(pr.comments.first?.author == "dev-b")
    #expect(pr.comments.first?.body == "## Review: changes needed (head d67db2a8)\n\n| ID | ...")
    #expect(pr.comments.first?.createdAt == ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z"))
}

@Test(ProcessBound()) func onlyOwnerSlashNameIsARepo() {
    #expect(BtonConfig.isRepoSlug("example-org/app"))
    #expect(BtonConfig.isRepoSlug("example-org/bton"))
    #expect(!BtonConfig.isRepoSlug("app.example"))
    #expect(!BtonConfig.isRepoSlug("https://github.com/example-org/bton"))
    #expect(!BtonConfig.isRepoSlug("a/b --json x"))
}

@Test(ProcessBound()) func configSurvivesASaveAndLoad() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("state").path],
                        homeDirectory: root)
    let legacyURL = root.appendingPathComponent("legacy.json")
    var config = BtonConfig.initial
    config.repos = [WatchedRepo(slug: "example-org/bton", path: root.appendingPathComponent("clone").path)]
    try config.save(to: home.configURL)
    let loaded = try BtonConfig.loadOrCreate(home: home, legacyURL: legacyURL)
    #expect(loaded.repos == config.repos)
}

@Test(ProcessBound()) func costIsTokensTimesPricePerMillion() {
    let price = ModelPrice(input: 5, cacheRead: Decimal(string: "0.5")!, cacheWrite: Decimal(string: "6.25")!, output: 25)
    let usage = TokenUsage(input: 1_000_000, cacheRead: 2_000_000, cacheWrite: 0, output: 100_000)
    #expect(price.cost(of: usage) == Decimal(string: "8.5")!)
}

@Test(ProcessBound()) func scheduleRunsNowWhenNeverRunAndWaitsOtherwise() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var entry = ScheduleEntry(name: "poll", everyMinutes: 5, enabled: true)
    #expect(entry.nextRun(after: now) == now)
    entry.lastRun = now
    #expect(entry.nextRun(after: now) == now.addingTimeInterval(300))
}
