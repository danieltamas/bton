@testable import BtonCore
import Foundation
import Testing

private enum ScheduleChangeGateFixture {
    static let repo = "acme/widget"
    static let now = Date(timeIntervalSince1970: 120_030)

    static func entry(onlyOnChange: Bool? = true) -> ScheduleEntry {
        var entry = ScheduleEntry(name: "Daily check", everyMinutes: 10, enabled: true,
                                  repo: repo, agent: "codex", prompt: "Inspect the synthetic widget.", number: 7)
        entry.onlyOnChange = onlyOnChange
        return entry
    }

    static func job(repo: String = ScheduleChangeGateFixture.repo, item: String = "schedule-7",
                    startedAt: Date, endedAt: Date? = nil, status: Job.Status = .succeeded) -> Job {
        Job(id: UUID(), key: JobKey(repo: repo, item: item, move: "schedule", head: "old-minute"),
            agent: "codex", startedAt: startedAt, endedAt: endedAt, status: status)
    }

    static func candidates(_ entry: ScheduleEntry, jobs: [Job] = [],
                           now: Date = ScheduleChangeGateFixture.now, runNow: Set<String> = [],
                           changedAt: Date? = nil) -> [DispatchCandidate] {
        DispatchPlanner.scheduled([entry], jobs: jobs, repo: repo, defaultBranch: "main",
                                  me: "octo", now: now, runNow: runNow, changedAt: changedAt)
    }
}

@Suite(ProcessBound())
struct ScheduleChangeGateAcceptanceTests {
    @Test func scheduleOnlyOnChangeAbsentJSONDecodesAsNil() throws {
        let json = Data(#"{"name":"Daily check","everyMinutes":10,"enabled":true}"#.utf8)
        let entry = try JSONDecoder().decode(ScheduleEntry.self, from: json)
        #expect(entry.onlyOnChange == nil)
        #expect(ScheduleEntry(name: "Daily check", everyMinutes: 10, enabled: true).onlyOnChange == nil)
    }

    @Test func scheduleOnlyOnChangeCodablePreservesOptionalBoolean() throws {
        for flag: Bool? in [nil, false, true] {
            let entry = ScheduleChangeGateFixture.entry(onlyOnChange: flag)
            let encoded = try JSONEncoder().encode(entry)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if let flag {
                #expect((object["onlyOnChange"] as? Bool) == flag)
            } else {
                #expect((object["onlyOnChange"] as? Bool) != true)
            }
            let decoded = try JSONDecoder().decode(ScheduleEntry.self, from: encoded)
            #expect(decoded.onlyOnChange == flag)
        }
    }

    @Test func scheduledNilAndFalseIgnoreChangesAndPreserveIntervalAndEnabled() {
        let now = ScheduleChangeGateFixture.now
        let start = now.addingTimeInterval(-600)
        let job = ScheduleChangeGateFixture.job(startedAt: start, endedAt: start.addingTimeInterval(60))
        for flag: Bool? in [nil, false] {
            var entry = ScheduleChangeGateFixture.entry(onlyOnChange: flag)
            for changedAt: Date? in [nil, start.addingTimeInterval(-1), job.endedAt, now] {
                #expect(ScheduleChangeGateFixture.candidates(entry, changedAt: changedAt).count == 1)
                #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job],
                                                            now: now.addingTimeInterval(-1), changedAt: changedAt).isEmpty)
                #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job], changedAt: changedAt).count == 1)
                entry.enabled = false
                #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job], changedAt: changedAt).isEmpty)
                entry.enabled = true
            }
        }
    }

    @Test func scheduledOnlyOnChangeNeverRunNeedsNoChangeTimestamp() {
        let entry = ScheduleChangeGateFixture.entry()
        let now = ScheduleChangeGateFixture.now
        for changedAt: Date? in [nil, now.addingTimeInterval(-3600), now] {
            #expect(ScheduleChangeGateFixture.candidates(entry, changedAt: changedAt).count == 1)
        }
        let unrelated = [
            ScheduleChangeGateFixture.job(repo: "acme/other", startedAt: now),
            ScheduleChangeGateFixture.job(item: "schedule-8", startedAt: now)
        ]
        #expect(ScheduleChangeGateFixture.candidates(entry, jobs: unrelated).count == 1)
    }

    @Test func scheduledOnlyOnChangeRequiresStrictlyAfterSuccessfulStart() {
        let now = ScheduleChangeGateFixture.now
        let start = now.addingTimeInterval(-900)
        let end = now.addingTimeInterval(-300)
        let job = ScheduleChangeGateFixture.job(startedAt: start, endedAt: end)
        let entry = ScheduleChangeGateFixture.entry()
        for changedAt: Date? in [nil, start.addingTimeInterval(-1), start] {
            #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job], changedAt: changedAt).isEmpty)
        }
        for change in [start.addingTimeInterval(1), end.addingTimeInterval(-1), end, end.addingTimeInterval(1)] {
            #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job], changedAt: change).count == 1)
        }
    }

    @Test func scheduledOnlyOnChangeStillRequiresExactIntervalBoundary() {
        let now = ScheduleChangeGateFixture.now
        let start = now.addingTimeInterval(-600)
        let end = start.addingTimeInterval(60)
        let job = ScheduleChangeGateFixture.job(startedAt: start, endedAt: end)
        let entry = ScheduleChangeGateFixture.entry()
        let change = end.addingTimeInterval(1)
        #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job],
                                                    now: now.addingTimeInterval(-1), changedAt: change).isEmpty)
        #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job], changedAt: change).count == 1)
        #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job],
                                                    now: now.addingTimeInterval(1), changedAt: change).count == 1)
    }

    @Test func scheduledOnlyOnChangeUsesSuccessfulStartWithoutEnd() {
        let start = ScheduleChangeGateFixture.now.addingTimeInterval(-600)
        let job = ScheduleChangeGateFixture.job(startedAt: start)
        let entry = ScheduleChangeGateFixture.entry()
        for changedAt: Date? in [nil, start.addingTimeInterval(-1), start] {
            #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job], changedAt: changedAt).isEmpty)
        }
        #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job],
                                                    changedAt: start.addingTimeInterval(1)).count == 1)
    }

    @Test func scheduledOnlyOnChangeHistoryMatchesRepoIgnoringCaseAndExactItem() {
        let now = ScheduleChangeGateFixture.now
        let end = now.addingTimeInterval(-300)
        let matching = ScheduleChangeGateFixture.job(repo: "ACME/WIDGET",
                                                     startedAt: now.addingTimeInterval(-900), endedAt: end)
        let unrelated = [
            ScheduleChangeGateFixture.job(repo: "acme/other", startedAt: now, endedAt: now),
            ScheduleChangeGateFixture.job(item: "schedule-8", startedAt: now, endedAt: now)
        ]
        let entry = ScheduleChangeGateFixture.entry()
        #expect(ScheduleChangeGateFixture.candidates(entry, jobs: unrelated + [matching]).isEmpty)
        #expect(ScheduleChangeGateFixture.candidates(entry, jobs: unrelated + [matching],
                                                    changedAt: matching.startedAt.addingTimeInterval(1)).count == 1)
    }

    @Test func scheduledOnlyOnChangeUsesNewestSuccessfulStartRegardlessOfEndsOrArrayOrder() {
        let now = ScheduleChangeGateFixture.now
        let latestEnd = now.addingTimeInterval(-300)
        let latest = ScheduleChangeGateFixture.job(startedAt: now.addingTimeInterval(-900), endedAt: latestEnd)
        let entry = ScheduleChangeGateFixture.entry()
        for olderEnd in [now.addingTimeInterval(-1200), now.addingTimeInterval(-100)] {
            let older = ScheduleChangeGateFixture.job(startedAt: now.addingTimeInterval(-1800), endedAt: olderEnd)
            for jobs in [[older, latest], [latest, older]] {
                #expect(ScheduleChangeGateFixture.candidates(entry, jobs: jobs,
                                                            changedAt: latest.startedAt).isEmpty)
                #expect(ScheduleChangeGateFixture.candidates(entry, jobs: jobs,
                                                            changedAt: latest.startedAt.addingTimeInterval(1)).count == 1)
            }
        }
    }

    @Test func scheduledOnlyOnChangeWithoutSuccessPassesGateButStillRequiresInterval() {
        let now = ScheduleChangeGateFixture.now
        let start = now.addingTimeInterval(-600)
        let entry = ScheduleChangeGateFixture.entry()
        for status: Job.Status in [.failed, .cancelled, .running] {
            let latest = ScheduleChangeGateFixture.job(startedAt: start, endedAt: now, status: status)
            let older = ScheduleChangeGateFixture.job(startedAt: start.addingTimeInterval(-600),
                                                       endedAt: start, status: .failed)
            for jobs in [[older, latest], [latest, older]] {
                for changedAt: Date? in [nil, start.addingTimeInterval(-1), start, now] {
                    #expect(ScheduleChangeGateFixture.candidates(entry, jobs: jobs,
                                                                now: now.addingTimeInterval(-1), changedAt: changedAt).isEmpty)
                    #expect(ScheduleChangeGateFixture.candidates(entry, jobs: jobs, changedAt: changedAt).count == 1)
                }
            }
        }
    }

    @Test func scheduledOnlyOnChangeRetriesChangesSinceSuccessAfterUnsuccessfulJobs() {
        let now = ScheduleChangeGateFixture.now
        let successStart = now.addingTimeInterval(-1800)
        let success = ScheduleChangeGateFixture.job(repo: "ACME/WIDGET", startedAt: successStart,
                                                     endedAt: successStart.addingTimeInterval(300))
        let entry = ScheduleChangeGateFixture.entry()
        for status: Job.Status in [.failed, .cancelled, .running] {
            let latest = ScheduleChangeGateFixture.job(startedAt: now.addingTimeInterval(-600),
                                                        endedAt: now.addingTimeInterval(-300), status: status)
            for jobs in [[success, latest], [latest, success]] {
                for changedAt: Date? in [nil, successStart.addingTimeInterval(-1), successStart] {
                    #expect(ScheduleChangeGateFixture.candidates(entry, jobs: jobs, changedAt: changedAt).isEmpty)
                }
                let change = successStart.addingTimeInterval(1)
                #expect(ScheduleChangeGateFixture.candidates(entry, jobs: jobs,
                                                            now: now.addingTimeInterval(-1), changedAt: change).isEmpty)
                #expect(ScheduleChangeGateFixture.candidates(entry, jobs: jobs, changedAt: change).count == 1)
            }
        }
    }

    @Test func scheduledRunNowOverridesChangeGateIntervalAndDisabledStateForItsItem() {
        let now = ScheduleChangeGateFixture.now
        let job = ScheduleChangeGateFixture.job(startedAt: now, endedAt: now)
        for flag: Bool? in [nil, false, true] {
            var entry = ScheduleChangeGateFixture.entry(onlyOnChange: flag)
            for enabled in [false, true] {
                entry.enabled = enabled
                for changedAt: Date? in [nil, now.addingTimeInterval(-1), now] {
                    #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job], runNow: ["schedule-7"],
                                                                changedAt: changedAt).count == 1)
                    #expect(ScheduleChangeGateFixture.candidates(entry, jobs: [job], runNow: ["schedule-8"],
                                                                changedAt: changedAt).isEmpty)
                }
            }
        }
    }
}
