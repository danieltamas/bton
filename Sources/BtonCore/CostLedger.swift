import Foundation

/// How long this Mac keeps a finished job's record before it is folded into the month's ledger.
public struct CostSettings: Codable, Hashable, Sendable {
    /// nil: `defaultRetentionDays`.
    public var retentionDays: Int?
    public static let defaultRetentionDays = 90

    public init(retentionDays: Int? = nil) {
        self.retentionDays = retentionDays
    }
}

/// One month of this Mac's spend, `$BTON_HOME/costs/<YYYY-MM>.json`: the retired job records,
/// summed per day, repo, move and agent, with the models inside each. A record is folded once
/// (`folded`), so retiring the same jobs again changes nothing, and the ledger stays after the
/// records are gone.
public struct CostLedger: Codable, Sendable {
    /// Tokens and cost of one model inside a row; `jobs` counts the jobs that used it.
    public struct ModelShare: Codable, Hashable, Sendable {
        public var jobs: Int
        public var usage: TokenUsage
        public var cost: Decimal

        public init(jobs: Int = 0, usage: TokenUsage = TokenUsage(), cost: Decimal = 0) {
            self.jobs = jobs
            self.usage = usage
            self.cost = cost
        }
    }

    /// The jobs of one day, repo, move and agent. `unpriced` counts the jobs whose tokens had no
    /// price: their tokens are in `models`, their cost is nowhere, so a total never hides a guess.
    public struct Row: Codable, Hashable, Sendable {
        public let day: String
        public let repo: String
        public let move: String
        public let agent: String
        public var jobs: Int
        public var unpriced: Int
        public var cost: Decimal
        public var models: [String: ModelShare]

        public init(day: String, repo: String, move: String, agent: String, jobs: Int = 0, unpriced: Int = 0,
                    cost: Decimal = 0, models: [String: ModelShare] = [:]) {
            self.day = day
            self.repo = repo
            self.move = move
            self.agent = agent
            self.jobs = jobs
            self.unpriced = unpriced
            self.cost = cost
            self.models = models
        }
    }

    public let month: String
    public var rows: [Row]
    public var folded: Set<UUID>

    public init(month: String, rows: [Row] = [], folded: Set<UUID> = []) {
        self.month = month
        self.rows = rows
        self.folded = folded
    }

    /// The agent name a row carries for a command job.
    public static let commandAgent = "command"

    public static func directory(home: BtonHome) -> URL { home.url.appendingPathComponent("costs") }

    static func fileURL(month: String, home: BtonHome) -> URL { directory(home: home).appendingPathComponent("\(month).json") }

    /// `YYYY-MM` and `YYYY-MM-DD` of a moment in `calendar`.
    static func month(of date: Date, calendar: Calendar) -> String { String(day(of: date, calendar: calendar).prefix(7)) }

    static func day(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Adds every given job that is over and not yet folded to its month's file; returns how many.
    /// A month file that exists and does not decode is left as it is and its jobs stay unfolded:
    /// a partial ledger never replaces a full one.
    @discardableResult
    public static func fold(_ jobs: [Job], home: BtonHome, prices: PriceList, calendar: Calendar = .current) throws -> Int {
        let directory = directory(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let byMonth = Dictionary(grouping: jobs.filter { $0.status != .running }) { month(of: $0.startedAt, calendar: calendar) }
        var count = 0
        for (month, jobs) in byMonth.sorted(by: { $0.key < $1.key }) {
            let url = fileURL(month: month, home: home)
            var ledger = FileManager.default.fileExists(atPath: url.path)
                ? try decoder.decode(CostLedger.self, from: Data(contentsOf: url))
                : CostLedger(month: month)
            // The same record handed in twice is one job.
            var fresh: [Job] = []
            for job in jobs where !ledger.folded.contains(job.id) && !fresh.contains(where: { $0.id == job.id }) { fresh.append(job) }
            guard !fresh.isEmpty else { continue }
            for job in fresh {
                ledger.add(job, prices: prices, calendar: calendar)
                ledger.folded.insert(job.id)
            }
            try encoder.encode(ledger).write(to: url, options: .atomic)
            count += fresh.count
        }
        return count
    }

    /// Every month on disk, oldest first; a file that does not decode is named, not skipped in silence.
    public static func load(home: BtonHome) -> (ledgers: [CostLedger], unreadable: [String]) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory(home: home), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var ledgers: [CostLedger] = [], unreadable: [String] = []
        for file in files {
            if let ledger = try? decoder.decode(CostLedger.self, from: Data(contentsOf: file)) {
                ledgers.append(ledger)
            } else {
                unreadable.append(file.lastPathComponent)
            }
        }
        return (ledgers, unreadable)
    }

    /// One job into its row, under the one valuation rule: a priced job's `cost` is split across
    /// its models in proportion to each model's token cost at `prices`, so the model view and the
    /// project view add up to the same total; an unpriced job adds tokens and a count, never money.
    mutating func add(_ job: Job, prices: PriceList, calendar: Calendar) {
        let day = Self.day(of: job.startedAt, calendar: calendar)
        let agent = job.agent ?? Self.commandAgent
        let index = rows.firstIndex { $0.day == day && $0.repo == job.key.repo && $0.move == job.key.move && $0.agent == agent }
            ?? {
                rows.append(Row(day: day, repo: job.key.repo, move: job.key.move, agent: agent))
                return rows.count - 1
            }()
        rows[index].jobs += 1
        guard !job.usage.isEmpty else { return }
        let shares = JobValuation.modelCosts(of: job, prices: prices)
        if let total = job.cost, shares != nil { rows[index].cost += total } else { rows[index].unpriced += 1 }
        for (model, tokens) in job.usage {
            var share = rows[index].models[model] ?? ModelShare()
            share.jobs += 1
            share.usage = share.usage + tokens
            share.cost += shares?[model] ?? 0
            rows[index].models[model] = share
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// The one way a job's money is split across its models and its sources.
public enum JobValuation {
    /// `job.cost` per model, in proportion to each model's token cost at `prices`; the last model
    /// (by name) takes the remainder so the parts add up to the whole exactly. nil for an unpriced
    /// job (no `cost`), and an empty dictionary for a job with no tokens.
    public static func modelCosts(of job: Job, prices: PriceList) -> [String: Decimal]? {
        guard let total = job.cost else { return nil }
        let models = job.usage.keys.sorted()
        guard !models.isEmpty else { return [:] }
        let weights = models.map { prices.price(for: $0)?.cost(of: job.usage[$0]!) ?? 0 }
        let sum = weights.reduce(0, +)
        var shares: [String: Decimal] = [:]
        var given: Decimal = 0
        for (model, weight) in zip(models, weights).dropLast() {
            // A job priced before its prices went missing is split evenly rather than lost.
            let share = sum > 0 ? total * weight / sum : total / Decimal(models.count)
            shares[model] = share
            given += share
        }
        shares[models.last!] = total - given
        return shares
    }
}

extension Job {
    /// Each source bucket of `sources` priced; nil for a bucket with an unpriced model.
    public func sourceCosts(prices: PriceList) -> [String: Decimal?] {
        (sources ?? [:]).mapValues { PriceList.cost(of: $0, prices: prices) }
    }
}

/// What the Costs pane groups by.
public enum CostGroup: String, CaseIterable, Sendable {
    case project, hat, move, agent, model

    /// The name a move's hat shows, or "other" for a move no hat owns.
    public static func hatName(for move: String) -> String { Hats.hat(for: move)?.rawValue ?? "other" }
}

/// This Mac's spend over the ledgers and the records still kept, read the same way: a kept
/// record is valued into rows as the ledger would value it, and a record already folded counts
/// from the ledger only.
public struct CostReport: Sendable {
    public struct Day: Hashable, Sendable {
        public let date: Date
        public let cost: Decimal
        public let jobs: Int
        public let unpriced: Int
    }

    public struct GroupRow: Hashable, Sendable {
        public let name: String
        public let jobs: Int
        public let unpriced: Int
        public let cost: Decimal
    }

    public struct Month: Hashable, Sendable {
        public let month: String
        public let total: Decimal
        public let unpriced: Int
        public let projects: [GroupRow]
    }

    public let prices: PriceList
    public let now: Date
    public let calendar: Calendar
    /// Every record still kept; the ones a ledger already holds are listed, not summed again.
    public let jobs: [Job]
    let rows: [CostLedger.Row]

    public init(ledgers: [CostLedger], jobs: [Job], prices: PriceList, now: Date = .now, calendar: Calendar = .current) {
        self.prices = prices
        self.now = now
        self.calendar = calendar
        self.jobs = jobs
        let folded = ledgers.reduce(into: Set<UUID>()) { $0.formUnion($1.folded) }
        let live = jobs.filter { !folded.contains($0.id) }
        var scratch = CostLedger(month: "")
        for job in live { scratch.add(job, prices: prices, calendar: calendar) }
        rows = ledgers.flatMap(\.rows) + scratch.rows
    }

    /// One entry per calendar day, the last `n` ending today, zeros where nothing ran.
    public func days(last n: Int) -> [Day] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(n, 0)).reversed().compactMap { back -> Day? in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let key = CostLedger.day(of: date, calendar: calendar)
            let mine = rows.filter { $0.day == key }
            return Day(date: date, cost: mine.reduce(0) { $0 + $1.cost }, jobs: mine.reduce(0) { $0 + $1.jobs },
                       unpriced: mine.reduce(0) { $0 + $1.unpriced })
        }
    }

    /// The jobs started in `from..<to`, grouped, dearest first.
    public func rows(by group: CostGroup, from: Date, to: Date) -> [GroupRow] {
        let window = rows.filter { row in
            guard let date = date(ofDay: row.day) else { return false }
            return date >= calendar.startOfDay(for: from) && date < to
        }
        return Self.grouped(window, by: group)
    }

    /// Every month, newest first, with its projects.
    public func months() -> [Month] {
        Dictionary(grouping: rows) { String($0.day.prefix(7)) }
            .map { month, rows in
                Month(month: month, total: rows.reduce(0) { $0 + $1.cost }, unpriced: rows.reduce(0) { $0 + $1.unpriced },
                      projects: Self.grouped(rows, by: .project))
            }
            .sorted { $0.month > $1.month }
    }

    /// The kept records that started on `day`, newest first.
    public func jobs(on day: Date) -> [Job] {
        let key = CostLedger.day(of: day, calendar: calendar)
        return jobs.filter { CostLedger.day(of: $0.startedAt, calendar: calendar) == key }.sorted { $0.startedAt > $1.startedAt }
    }

    private func date(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func grouped(_ rows: [CostLedger.Row], by group: CostGroup) -> [GroupRow] {
        var totals: [String: (jobs: Int, unpriced: Int, cost: Decimal)] = [:]
        for row in rows {
            if group == .model {
                for (model, share) in row.models {
                    var entry = totals[model] ?? (0, 0, 0)
                    entry.jobs += share.jobs
                    entry.cost += share.cost
                    totals[model] = entry
                }
                // An unpriced job's count goes to the models it used, so the column stays honest.
                if row.unpriced > 0 {
                    for model in row.models.keys { totals[model]!.unpriced += row.unpriced }
                }
                continue
            }
            let name: String = switch group {
            case .project: row.repo
            case .hat: CostGroup.hatName(for: row.move)
            case .move: row.move
            case .agent: row.agent
            case .model: ""
            }
            var entry = totals[name] ?? (0, 0, 0)
            entry.jobs += row.jobs
            entry.unpriced += row.unpriced
            entry.cost += row.cost
            totals[name] = entry
        }
        return totals.map { GroupRow(name: $0.key, jobs: $0.value.jobs, unpriced: $0.value.unpriced, cost: $0.value.cost) }
            .sorted { ($0.cost, $0.jobs, $1.name) > ($1.cost, $1.jobs, $0.name) }
    }
}
