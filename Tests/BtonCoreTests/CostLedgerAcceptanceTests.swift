import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CostLedgerAcceptanceTests {
    @Test func foldIsIdempotentAndUsesTheMonthOfJobStart() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let september = CostLedgerFixture.job(start: "2026-09-30T23:00:00Z", end: "2026-10-01T01:00:00Z", cost: 4)
        let october = CostLedgerFixture.job(start: "2026-10-02T12:00:00Z", cost: 6)
        let command = CostLedgerFixture.job(start: "2026-10-02T13:00:00Z", agent: nil, usage: [:], cost: nil)
        #expect(CostLedger.directory(home: home).standardizedFileURL == root.appendingPathComponent("costs").standardizedFileURL)
        #expect(try CostLedger.fold([october, september, command, october], home: home,
                                    prices: CostLedgerFixture.prices, calendar: CostLedgerFixture.calendar) == 3)
        let before = CostLedger.load(home: home)
        #expect(before.unreadable.isEmpty)
        #expect(before.ledgers.map(\.month) == ["2026-09", "2026-10"])
        #expect(before.ledgers.flatMap(\.rows).reduce(0) { $0 + $1.jobs } == 3)
        #expect(before.ledgers.flatMap(\.rows).reduce(Decimal.zero) { $0 + $1.cost } == 10)
        let commandRow = try #require(before.ledgers.flatMap(\.rows).first { $0.agent == "command" })
        #expect(commandRow.jobs == 1 && commandRow.cost == 0 && commandRow.unpriced == 0)
        #expect(commandRow.models.isEmpty)
        let bytes = try before.ledgers.map {
            try Data(contentsOf: CostLedger.directory(home: home).appendingPathComponent("\($0.month).json"))
        }
        #expect(try CostLedger.fold([september, october, command], home: home,
                                    prices: CostLedgerFixture.prices, calendar: CostLedgerFixture.calendar) == 0)
        for (ledger, original) in zip(before.ledgers, bytes) {
            let file = CostLedger.directory(home: home).appendingPathComponent("\(ledger.month).json")
            #expect(try Data(contentsOf: file) == original)
        }
        #expect(Set(CostLedger.load(home: home).ledgers.flatMap(\.folded)) == Set([september.id, october.id, command.id]))
    }

    @Test func runningJobIsNotFolded() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let running = CostLedgerFixture.job(status: .running, cost: 20)
        let finished = CostLedgerFixture.job(cost: 3)
        #expect(try CostLedger.fold([running, finished], home: home, prices: CostLedgerFixture.prices,
                                    calendar: CostLedgerFixture.calendar) == 1)
        let ledger = try #require(CostLedger.load(home: home).ledgers.first)
        #expect(ledger.folded == Set([finished.id]))
        #expect(ledger.rows.reduce(0) { $0 + $1.jobs } == 1)
        #expect(ledger.rows.reduce(Decimal.zero) { $0 + $1.cost } == 3)
    }

    @Test func unpricedJobKeepsTokensWithoutAddingAnyCost() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let usage = ["synthetic-a": TokenUsage(input: 100, cacheRead: 200, cacheWrite: 300, output: 40),
                     "unknown": TokenUsage(input: 11, cacheRead: 22, cacheWrite: 33, output: 44)]
        let job = CostLedgerFixture.job(usage: usage, cost: nil)
        #expect(try CostLedger.fold([job], home: home, prices: CostLedgerFixture.prices,
                                    calendar: CostLedgerFixture.calendar) == 1)
        let ledger = try #require(CostLedger.load(home: home).ledgers.first)
        let row: CostLedger.Row = try #require(ledger.rows.first)
        #expect(row.jobs == 1 && row.unpriced == 1 && row.cost == 0)
        #expect(Set(row.models.keys) == Set(usage.keys))
        for (model, tokens) in usage {
            let share: CostLedger.ModelShare = try #require(row.models[model])
            #expect(share.jobs == 1 && share.usage == tokens && share.cost == 0)
        }
    }

    @Test func pricedJobSplitsItsRecordedCostInTokenCostProportion() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        // Current token prices value A at $2 and B at $6; the recorded job cost is $10.
        let job = CostLedgerFixture.job(usage: CostLedgerFixture.twoModels, cost: 10)
        #expect(try CostLedger.fold([job], home: home, prices: CostLedgerFixture.prices,
                                    calendar: CostLedgerFixture.calendar) == 1)
        let ledger = try #require(CostLedger.load(home: home).ledgers.first)
        let row: CostLedger.Row = try #require(ledger.rows.first)
        let a: CostLedger.ModelShare = try #require(row.models["synthetic-a"])
        let b: CostLedger.ModelShare = try #require(row.models["synthetic-b"])
        #expect(row.day == "2026-10-15" && row.repo == job.key.repo && row.move == job.key.move)
        #expect(row.agent == job.agent && row.jobs == 1 && row.unpriced == 0 && row.cost == 10)
        #expect(a.jobs == 1 && a.usage == CostLedgerFixture.twoModels["synthetic-a"])
        #expect(b.jobs == 1 && b.usage == CostLedgerFixture.twoModels["synthetic-b"])
        #expect(a.cost == Decimal(string: "2.5") && b.cost == Decimal(string: "7.5"))
        #expect(row.models.values.reduce(Decimal.zero) { $0 + $1.cost } == row.cost)
    }

    @Test func badMonthFileIsPreservedAndNamedByLoad() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let directory = CostLedger.directory(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("2026-10.json")
        let original = Data(#"{"month":"2026-10","rows":"corrupt","folded":[]}"#.utf8)
        try original.write(to: file)
        let job = CostLedgerFixture.job(cost: 5)
        #expect(throws: (any Error).self) {
            try CostLedger.fold([job], home: home, prices: CostLedgerFixture.prices, calendar: CostLedgerFixture.calendar)
        }
        #expect(try Data(contentsOf: file) == original)
        let result = CostLedger.load(home: home)
        #expect(result.ledgers.isEmpty)
        #expect(result.unreadable == ["2026-10.json"])
    }

    @Test func retireOnlyRemovesFoldedOldRecordsAndPreservesEachTuplesLatestAndLatestSuccess() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let store = try JobStore(home: home)
        let now = CostLedgerFixture.now
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        let oldFailure = CostLedgerFixture.agedJob(ended: cutoff.addingTimeInterval(-4 * 86_400), status: .failed)
        let oldSuccess = CostLedgerFixture.agedJob(ended: cutoff.addingTimeInterval(-3 * 86_400))
        let latestSuccess = CostLedgerFixture.agedJob(ended: cutoff.addingTimeInterval(-2 * 86_400))
        let latest = CostLedgerFixture.agedJob(ended: cutoff.addingTimeInterval(-86_400), status: .failed)
        let exact = CostLedgerFixture.agedJob(ended: cutoff, item: "pr-boundary", status: .failed)
        let recent = CostLedgerFixture.agedJob(ended: cutoff.addingTimeInterval(1), item: "pr-boundary", status: .failed)
        let boundaryLatest = CostLedgerFixture.agedJob(ended: now.addingTimeInterval(-86_400), item: "pr-boundary")
        let otherRepo = CostLedgerFixture.agedJob(ended: oldFailure.endedAt!, repo: "synthetic/other", status: .failed)
        let otherItem = CostLedgerFixture.agedJob(ended: oldFailure.endedAt!, item: "pr-other", status: .failed)
        let otherMove = CostLedgerFixture.agedJob(ended: oldFailure.endedAt!, move: "fix", status: .failed)
        let jobs = [latest, oldFailure, recent, latestSuccess, oldSuccess, exact, boundaryLatest, otherRepo, otherItem, otherMove]
        let directory = root.appendingPathComponent("jobs")
        let suffixes = ["out", "log", "exit", "helpers", "mcp.json", "second.out", "second.log",
                        "second.exit", "stop", "session.md", "session-so-far.md"]
        for job in jobs {
            try store.save(job)
            for suffix in suffixes {
                try Data("synthetic artifact".utf8).write(to: directory.appendingPathComponent("\(job.id.uuidString).\(suffix)"))
            }
        }
        // A record already folded before a previous retirement stopped must still be removed.
        #expect(try CostLedger.fold([oldFailure], home: home, prices: CostLedgerFixture.prices,
                                    calendar: CostLedgerFixture.calendar) == 1)
        #expect(try store.retire(now: now, olderThan: 90, prices: CostLedgerFixture.prices) == 2)
        let removed = Set([oldFailure.id, oldSuccess.id])
        #expect(Set(store.all().map(\.id)) == Set(jobs.map(\.id)).subtracting(removed))
        let folded = Set(CostLedger.load(home: home).ledgers.flatMap(\.folded))
        #expect(removed.isSubset(of: folded))
        for job in jobs {
            for suffix in ["json"] + suffixes {
                let file = directory.appendingPathComponent("\(job.id.uuidString).\(suffix)")
                #expect(FileManager.default.fileExists(atPath: file.path) == !removed.contains(job.id))
            }
        }
        #expect(try store.retire(now: now, olderThan: 90, prices: CostLedgerFixture.prices) == 0)

        // A corrupt ledger blocks retirement of its records, rather than discarding their history.
        let blocked = CostLedgerFixture.agedJob(ended: CostLedgerFixture.date("2026-06-01T12:00:00Z"), status: .failed)
        try store.save(blocked)
        let artifact = store.outputURL(blocked.id)
        try Data("keep me".utf8).write(to: artifact)
        let badMonth = CostLedger.directory(home: home).appendingPathComponent("2026-06.json")
        let corrupt = Data("not a ledger".utf8)
        try corrupt.write(to: badMonth)
        #expect(throws: (any Error).self) {
            try store.retire(now: now, olderThan: 90, prices: CostLedgerFixture.prices)
        }
        #expect(store.all().contains { $0.id == blocked.id })
        #expect(try Data(contentsOf: artifact) == Data("keep me".utf8))
        #expect(try Data(contentsOf: badMonth) == corrupt)
    }

    @Test func retireNeverRemovesOrFoldsRunningJobs() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let store = try JobStore(home: home)
        let noEnd = CostLedgerFixture.job(start: "2026-01-01T12:00:00Z", status: .running)
        let staleEnd = CostLedgerFixture.agedJob(ended: CostLedgerFixture.date("2026-01-02T12:00:00Z"), status: .running)
        let newer = CostLedgerFixture.agedJob(ended: CostLedgerFixture.date("2026-01-03T12:00:00Z"))
        for job in [noEnd, staleEnd, newer] { try store.save(job) }
        for job in [noEnd, staleEnd] { try Data("running".utf8).write(to: store.outputURL(job.id)) }
        #expect(try store.retire(now: CostLedgerFixture.now, olderThan: 90, prices: CostLedgerFixture.prices) == 0)
        #expect(Set(store.all().map(\.id)) == Set([noEnd.id, staleEnd.id, newer.id]))
        let folded = Set(CostLedger.load(home: home).ledgers.flatMap(\.folded))
        for job in [noEnd, staleEnd] {
            #expect(!folded.contains(job.id))
            #expect(try Data(contentsOf: store.outputURL(job.id)) == Data("running".utf8))
        }
    }

    @Test func reportDaysIncludesEveryDayAndZerosAndRetainedJobDetails() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let folded = CostLedgerFixture.job(start: "2026-10-30T23:59:00Z", cost: 4)
        _ = try CostLedger.fold([folded], home: home, prices: CostLedgerFixture.prices, calendar: CostLedgerFixture.calendar)
        let unpriced = CostLedgerFixture.job(start: "2026-11-01T00:00:00Z", cost: nil)
        let early = CostLedgerFixture.job(start: "2026-11-03T00:00:00Z", cost: 3)
        let late = CostLedgerFixture.job(start: "2026-11-03T11:00:00Z", cost: 7)
        let tomorrow = CostLedgerFixture.job(start: "2026-11-04T00:00:00Z", cost: 99)
        let report = CostReport(ledgers: CostLedger.load(home: home).ledgers,
                                jobs: [late, folded, tomorrow, unpriced, early], prices: CostLedgerFixture.prices,
                                now: CostLedgerFixture.now, calendar: CostLedgerFixture.calendar)
        let days = report.days(last: 5)
        #expect(days.map(\.date) == ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03"].map {
            CostLedgerFixture.date("\($0)T00:00:00Z")
        })
        #expect(days.map(\.cost) == [4, 0, 0, 0, 10])
        #expect(days.map(\.jobs) == [1, 0, 1, 0, 2])
        #expect(days.map(\.unpriced) == [0, 0, 1, 0, 0])
        #expect(report.jobs(on: CostLedgerFixture.now).map(\.id) == [late.id, early.id])
        #expect(report.jobs(on: folded.startedAt).map(\.id) == [folded.id])
        #expect(report.jobs(on: CostLedgerFixture.date("2026-11-02T12:00:00Z")).isEmpty)
    }

    @Test func reportHatRowsUseHatOwnershipAndOther() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let from = CostLedgerFixture.date("2026-10-01T00:00:00Z")
        let to = CostLedgerFixture.date("2026-11-01T00:00:00Z")
        var jobs: [Job] = []
        for hat in Hat.allCases {
            for move in hat.moves {
                #expect(Hats.hat(for: move) == hat)
                jobs.append(CostLedgerFixture.job(move: move, cost: 2))
            }
        }
        let other = CostLedgerFixture.job(move: "synthetic-unowned-move", cost: 3)
        #expect(Hats.hat(for: other.key.move) == nil)
        let archived = Array(jobs.prefix(2))
        _ = try CostLedger.fold(archived, home: home, prices: CostLedgerFixture.prices, calendar: CostLedgerFixture.calendar)
        let before = CostLedgerFixture.job(start: "2026-09-30T23:59:59Z", cost: 999)
        let atEnd = CostLedgerFixture.job(start: "2026-11-01T00:00:00Z", cost: 999)
        let report = CostReport(ledgers: CostLedger.load(home: home).ledgers,
                                jobs: Array(jobs.dropFirst(2)) + [other, before, atEnd], prices: CostLedgerFixture.prices,
                                now: CostLedgerFixture.now, calendar: CostLedgerFixture.calendar)
        let group: CostGroup = .hat
        let rows = report.rows(by: group, from: from, to: to)
        #expect(Set(rows.map(\.name)) == Set(Hat.allCases.map(\.rawValue) + ["other"]))
        #expect(rows.map(\.cost) == rows.map(\.cost).sorted(by: >))
        for hat in Hat.allCases {
            let row = try #require(rows.first { $0.name == hat.rawValue })
            #expect(row.jobs == hat.moves.count && row.unpriced == 0 && row.cost == Decimal(hat.moves.count * 2))
        }
        let otherRow = try #require(rows.first { $0.name == "other" })
        #expect(otherRow.jobs == 1 && otherRow.unpriced == 0 && otherRow.cost == 3)
    }

    @Test func reportModelRowsSplitRecordedCostsForLedgerAndLiveJobs() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let archived = CostLedgerFixture.job(usage: CostLedgerFixture.twoModels, cost: 6)
        _ = try CostLedger.fold([archived], home: home, prices: CostLedgerFixture.prices, calendar: CostLedgerFixture.calendar)
        let live = CostLedgerFixture.job(start: "2026-10-01T00:00:00Z", usage: CostLedgerFixture.twoModels, cost: 10)
        let report = CostReport(ledgers: CostLedger.load(home: home).ledgers, jobs: [live], prices: CostLedgerFixture.prices,
                                now: CostLedgerFixture.now, calendar: CostLedgerFixture.calendar)
        let from = CostLedgerFixture.date("2026-10-01T00:00:00Z")
        let to = CostLedgerFixture.date("2026-11-01T00:00:00Z")
        let rows = report.rows(by: .model, from: from, to: to)
        #expect(rows.map(\.name) == ["synthetic-b", "synthetic-a"])
        #expect(rows.map(\.cost) == [12, 4])
        #expect(rows.map(\.jobs) == [2, 2])
        #expect(rows.map(\.unpriced) == [0, 0])
        #expect(rows.reduce(Decimal.zero) { $0 + $1.cost } == 16)
    }

    @Test func reportMonthsCombinesLedgersAndUnfoldedRecordsWithoutDuplicates() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let september = CostLedgerFixture.job(start: "2026-09-15T12:00:00Z", cost: 4)
        let october = CostLedgerFixture.job(cost: 5)
        _ = try CostLedger.fold([october, september], home: home, prices: CostLedgerFixture.prices,
                                calendar: CostLedgerFixture.calendar)
        let sameProject = CostLedgerFixture.job(cost: 2)
        let otherProject = CostLedgerFixture.job(repo: "synthetic/other", cost: 3)
        let unpriced = CostLedgerFixture.job(usage: ["unknown": TokenUsage(input: 50)], cost: nil)
        let november = CostLedgerFixture.job(start: "2026-11-03T12:00:00Z", cost: 2)
        let report = CostReport(ledgers: CostLedger.load(home: home).ledgers,
                                jobs: [october, november, unpriced, september, sameProject, otherProject],
                                prices: CostLedgerFixture.prices, now: CostLedgerFixture.now, calendar: CostLedgerFixture.calendar)
        let months = report.months()
        #expect(months.map(\.month) == ["2026-11", "2026-10", "2026-09"])
        #expect(months.map(\.total) == [2, 10, 4])
        #expect(months.map(\.unpriced) == [0, 1, 0])
        let month = try #require(months.first { $0.month == "2026-10" })
        #expect(month.projects.map(\.name) == ["synthetic/repo", "synthetic/other"])
        #expect(month.projects.map(\.cost) == [7, 3])
        #expect(month.projects.map(\.jobs) == [3, 1])
        #expect(month.projects.map(\.unpriced) == [1, 0])
        for month in months {
            #expect(month.projects.reduce(Decimal.zero) { $0 + $1.cost } == month.total)
        }
    }

    @Test func jobSourcesRoundTripAndOldRecordsHaveNoSources() throws {
        let root = try CostLedgerFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let store = try JobStore(home: home)
        let sources: [String: [String: TokenUsage]] = [
            "agent": ["synthetic-a": TokenUsage(input: 1_000_000)],
            "second": ["synthetic-b": TokenUsage(output: 500_000)],
            "helpers": ["unknown": TokenUsage(cacheRead: 50)],
            "codex": ["synthetic-a": TokenUsage(input: 250_000)]
        ]
        let usage = ["synthetic-a": TokenUsage(input: 1_250_000), "synthetic-b": TokenUsage(output: 500_000),
                     "unknown": TokenUsage(cacheRead: 50)]
        var job = CostLedgerFixture.job(usage: usage, cost: nil)
        job.sources = sources
        try store.save(job)
        let restored = try #require(try JobStore(home: BtonHome(environment: ["BTON_HOME": root.path])).all().first)
        #expect(restored.sources == sources)
        #expect(restored.usage == usage && restored.cost == nil)
        let costs = restored.sourceCosts(prices: CostLedgerFixture.prices)
        #expect(Set(costs.keys) == Set(sources.keys))
        #expect(try #require(costs["agent"]) == 2)
        #expect(try #require(costs["second"]) == 6)
        #expect(try #require(costs["codex"]) == Decimal(string: "0.5"))
        let helperCost = try #require(costs["helpers"])
        #expect(helperCost == nil)
        let file = root.appendingPathComponent("jobs/\(job.id.uuidString).json")
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy.removeValue(forKey: "sources")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let old = try #require(store.all().first)
        #expect(old.sources == nil)
        #expect(old.id == job.id && old.usage == usage && old.cost == nil)
    }

    @Test func absentCostSettingsDecodeAsNilAndRetentionDefaultsToNinetyDays() throws {
        let legacy = Data(#"{"repos":[],"pollSeconds":60,"maxAgents":2,"agents":{},"schedules":[]}"#.utf8)
        let config = try JSONDecoder().decode(BtonConfig.self, from: legacy)
        #expect(config.costs == nil)
        #expect(CostSettings.defaultRetentionDays == 90)
        #expect((config.costs?.retentionDays ?? CostSettings.defaultRetentionDays) == 90)
        let unset = try JSONDecoder().decode(CostSettings.self, from: Data("{}".utf8))
        #expect(unset.retentionDays == nil)
        for days in [30, 60, 90, 180] {
            var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
            object["costs"] = ["retentionDays": days]
            let configured = try JSONDecoder().decode(BtonConfig.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(configured.costs?.retentionDays == days)
            let restored = try JSONDecoder().decode(BtonConfig.self, from: JSONEncoder().encode(configured))
            #expect(restored.costs == configured.costs)
        }
    }
}

private enum CostLedgerFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    static let now = date("2026-11-03T12:00:00Z")
    static let prices = PriceList(models: [
        "synthetic-a": ModelPrice(input: 2, cacheRead: 1, cacheWrite: 3, output: 4),
        "synthetic-b": ModelPrice(input: 8, cacheRead: 2, cacheWrite: 10, output: 12)
    ])
    static let twoModels = ["synthetic-a": TokenUsage(input: 1_000_000), "synthetic-b": TokenUsage(output: 500_000)]

    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-cost-ledger-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func job(start: String = "2026-10-15T12:00:00Z", end: String? = nil,
                    repo: String = "synthetic/repo", move: String = "review", agent: String? = "synthetic-agent",
                    status: Job.Status = .succeeded, usage: [String: TokenUsage] = ["synthetic-a": TokenUsage(input: 100)],
                    cost: Decimal? = 1) -> Job {
        let started = date(start)
        return Job(id: UUID(), key: JobKey(repo: repo, item: "pr-1", move: move, head: "synthetic-head"), agent: agent,
                   startedAt: started, endedAt: end.map(date) ?? (status == .running ? nil : started.addingTimeInterval(60)),
                   status: status, usage: usage, cost: cost)
    }

    static func agedJob(ended: Date, repo: String = "synthetic/repo", item: String = "pr-1", move: String = "review",
                        status: Job.Status = .succeeded) -> Job {
        Job(id: UUID(), key: JobKey(repo: repo, item: item, move: move, head: "head-\(ended.timeIntervalSince1970)"),
            agent: "synthetic-agent", startedAt: ended.addingTimeInterval(-3_600), endedAt: ended,
            status: status, usage: ["synthetic-a": TokenUsage(input: 100)], cost: 1)
    }
}
