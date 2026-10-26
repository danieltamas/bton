import Foundation
import Testing
import BtonCore

// Pure acceptance contracts: fixed dates, no network or wall-clock waits.
@Suite(ProcessBound())
struct ReleaseCheckAcceptanceTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let release = BtonRelease.build(version: "0.5.0", source: nil)

    @Test func freshCheckIsDueAndShowsNothing() {
        let check = ReleaseCheck()
        #expect(ReleaseCheck.interval == 900)
        #expect(check.standing == nil)
        #expect(check.failure == nil)
        #expect(check.lastAttempt == nil)
        #expect(check.newerRelease == nil)
        #expect(check.isDue(now: checkedAt))
    }

    @Test func successfulCheckIsReusedUntilExactlyFifteenMinutes() {
        var check = ReleaseCheck()
        check.record(latestTag: "v0.5.1", build: release, at: checkedAt)

        #expect(check.standing == .behind(latest: "v0.5.1"))
        #expect(check.newerRelease == "v0.5.1")
        #expect(check.failure == nil)
        #expect(check.lastAttempt == checkedAt)
        #expect(!check.isDue(now: checkedAt))
        #expect(!check.isDue(now: checkedAt.addingTimeInterval(899)))
        #expect(check.isDue(now: checkedAt.addingTimeInterval(900)))
        #expect(check.isDue(now: checkedAt.addingTimeInterval(901)))
    }

    @Test func firstFailureAlsoWaitsFifteenMinutesBeforeRetrying() {
        var check = ReleaseCheck()
        check.record(failure: "Network unavailable", at: checkedAt)

        #expect(check.standing == nil)
        #expect(check.newerRelease == nil)
        #expect(check.failure == "Network unavailable")
        #expect(check.lastAttempt == checkedAt)
        #expect(!check.isDue(now: checkedAt))
        #expect(!check.isDue(now: checkedAt.addingTimeInterval(899)))
        #expect(check.isDue(now: checkedAt.addingTimeInterval(900)))
    }

    @Test func failurePreservesIndicatorAndRestartsWaitFromFailedAttempt() {
        var check = ReleaseCheck()
        check.record(latestTag: "v0.5.1", build: release, at: checkedAt)
        let failedAt = checkedAt.addingTimeInterval(900)
        check.record(failure: "Request timed out", at: failedAt)

        #expect(check.standing == .behind(latest: "v0.5.1"))
        #expect(check.newerRelease == "v0.5.1")
        #expect(check.failure == "Request timed out")
        #expect(check.lastAttempt == failedAt)
        #expect(!check.isDue(now: failedAt))
        #expect(!check.isDue(now: failedAt.addingTimeInterval(899)))
        #expect(check.isDue(now: failedAt.addingTimeInterval(900)))
    }

    @Test func forcedSuccessBeforeDueClearsFailureAndReplacesAnswer() {
        var check = ReleaseCheck()
        check.record(latestTag: "v0.5.1", build: release, at: checkedAt)
        check.record(failure: "Offline", at: checkedAt.addingTimeInterval(10))
        let retriedAt = checkedAt.addingTimeInterval(20)
        #expect(!check.isDue(now: retriedAt))

        // About's Check again records a result without consulting isDue.
        check.record(latestTag: "v0.5.0", build: release, at: retriedAt)
        #expect(check.standing == .latest)
        #expect(check.newerRelease == nil)
        #expect(check.failure == nil)
        #expect(check.lastAttempt == retriedAt)
        #expect(!check.isDue(now: retriedAt.addingTimeInterval(899)))
        #expect(check.isDue(now: retriedAt.addingTimeInterval(900)))
    }

    @Test func indicatorOnlyShowsTagForBehindStanding() {
        let rows: [(String, String?, String, BtonRelease.Standing, String?)] = [
            ("0.5.0", nil, "v0.5.1", .behind(latest: "v0.5.1"), "v0.5.1"),
            ("0.5.0", nil, "0.5.1", .behind(latest: "0.5.1"), "0.5.1"),
            ("0.5.0", nil, "v0.5.0", .latest, nil),
            ("0.6.0", nil, "v0.5.0", .ahead, nil),
            ("development", nil, "v0.5.0", .unknown, nil),
            ("0.5.0", nil, "invalid-tag", .unknown, nil),
            ("0.5.0", "v0.5.0-3-gabcdef1", "v0.5.0", .ahead, nil),
        ]
        var check = ReleaseCheck()
        for (version, source, tag, standing, newerRelease) in rows {
            let build = BtonRelease.build(version: version, source: source)
            check.record(latestTag: tag, build: build, at: checkedAt)
            #expect(check.standing == standing)
            #expect(check.newerRelease == newerRelease)
        }
    }

    @Test func clockGoingBackMakesSuccessfulAndFailedChecksDue() {
        var success = ReleaseCheck()
        success.record(latestTag: "v0.5.0", build: release, at: checkedAt)
        var failure = ReleaseCheck()
        failure.record(failure: "Offline", at: checkedAt)

        for check in [success, failure] {
            #expect(check.isDue(now: checkedAt.addingTimeInterval(-1)))
            #expect(!check.isDue(now: checkedAt))
        }
    }
}
