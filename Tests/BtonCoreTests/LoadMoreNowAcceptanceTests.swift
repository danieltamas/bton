@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct LoadMoreNowAcceptanceTests {
    @Test func a() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        let first = await engine.tick(dispatching: false)
        #expect(first.problem == nil)
        #expect(first.triage.map(\.number) == [1])
        #expect(first.issuesMore == [IssuePagingPayload.repo])

        try f.clearCalls()
        let page = try #require(await engine.readMoreIssues(repo: IssuePagingPayload.repo))
        #expect(Set(page.triage.map(\.number)) == [1, 2])
        #expect(page.triage.count == 2)
        #expect(page.more == false)
        try f.expectTwoPageCalls()
        let pages = await engine.issuePages
        #expect(pages[IssuePagingPayload.repo] == 2)
    }

    @Test func b() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        let first = await engine.tick(dispatching: false)
        #expect(first.problem == nil)
        #expect(first.triage.map(\.number) == [1])
        #expect(first.issuesMore == [IssuePagingPayload.repo])

        // Page 1 changing must not replace the previous list when page 2 fails.
        try IssuePagingPayload.page([99], next: "C2").write(to: f.file("page-1.json"))
        try Data().write(to: f.file("fail-page-2"))
        try f.clearCalls()
        let page = await engine.readMoreIssues(repo: IssuePagingPayload.repo)
        #expect(page == nil)
        try f.expectTwoPageCalls()

        let failed = await engine.tick(dispatching: false)
        #expect(failed.problem == nil)
        #expect(failed.triage.map(\.number) == [1])
        #expect(failed.triage == first.triage)
        #expect(failed.issuesMore == [IssuePagingPayload.repo])
    }
}
