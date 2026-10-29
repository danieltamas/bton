@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct ResolveChecksAcceptanceTests {
    @Test func dispatchChecksFalseLoadsWithoutChangingAbsentOrTrueValues() throws {
        let data = Data("""
        {
          "version": 1,
          "base": "main",
          "tier": {"marker": "Tier:", "values": ["feature"], "default": "feature"},
          "reviews": {"feature": [{"heading": "## Review:"}]},
          "fixed": "## Fixed:",
          "moves": [
            {"move": "resolve", "when": ["conflicting"], "who": "author"},
            {"move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author"},
            {"move": "merge", "when": ["approved_current_head"], "who": "author"}
          ],
          "dispatch": {
            "resolve": {"agent": "synthetic", "prompt": "Resolve conflicts", "checks": false},
            "fix": {"agent": "synthetic", "prompt": "Address review"},
            "merge": {"command": ["true"], "checks": true}
          },
          "checks": {"beforeSession": [["false"]], "beforeMerge": [["false"]]}
        }
        """.utf8)

        guard case let .ready(flow) = Flow.load(data) else {
            Issue.record("A version-1 flow with dispatch.resolve.checks false must load as ready")
            return
        }
        let resolve = try #require(flow.dispatch["resolve"])
        let fix = try #require(flow.dispatch["fix"])
        let merge = try #require(flow.dispatch["merge"])
        #expect(resolve.checks == RuleChecks.none)
        #expect(fix.checks == nil)
        #expect(merge.checks == RuleChecks.flow)
        #expect(flow.checks?.beforeSession == [["false"]])
        #expect(flow.checks?.beforeMerge == [["false"]])
    }
}
