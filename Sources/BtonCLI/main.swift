import BtonCore
import Foundation

let usage = """
usage: bton moves <owner/name> [--flow <file>]              each open PR's move and owner
       bton lease claim <owner/name> <kind>-<n> [--job <uuid>]   prints the job id
       bton lease renew|release <owner/name> <kind>-<n> --job <uuid>
       bton lease check <owner/name> <kind>-<n>
       bton watch [--for <seconds>]   tick every pollSeconds: dispatch this Mac's moves
       bton jobs                      this BTON_HOME's jobs as JSON lines
       bton prs                       one read without dispatching: open PRs and merged totals
       bton handoff <owner/name> [<issue>] --to <login> <text>   comment @login on an issue, once;
                                      no issue: the repo's open issue labelled bton:inbox
       bton prices refresh            fetch token prices now
       bton ask-server --job <uuid> --cwd <dir> --helper <agent>...   a job's MCP ask tool (Bton starts it)
exit: 0 done, 1 held by someone else or lost, 2 usage, 3 error (not held)
"""

func fail(_ message: String, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data(("warning: " + message + "\n").utf8))
}

// Line-buffered, so `watch` output reaches a log file even when the process is killed.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }

// Any error left, gh not found among them, ends with its message, not a trace.
do {
    switch command {
    case "ask-server":
        func values(_ flag: String) -> [String] {
            arguments.indices.filter { arguments[$0] == flag && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
        }
        guard let job = values("--job").first.flatMap(UUID.init(uuidString:)), let cwd = values("--cwd").first else { fail(usage) }
        let home = BtonHome()
        // An unreadable config still answers the agent: every ask then fails with a reason.
        let (jobs, agents) = (try JobStore(home: home), (try? BtonConfig.loadOrCreate(home: home))?.agents ?? [:])
        // A helper's own session never offers helpers: one level of asking, no loops.
        let helpers = ProcessInfo.processInfo.environment["BTON_HELPER"] == nil ? values("--helper") : []
        let server = AskServer(helpers: helpers) { agent, question in
            await Helpers.ask(agent: agent, question: question, allowed: helpers, agents: agents,
                              cwd: URL(fileURLWithPath: cwd), job: job, jobs: jobs, timeout: Helpers.askTimeout)
        }
        while let line = readLine() {
            if let reply = await server.respond(to: line) { print(reply) }
        }
    case "moves":
        guard arguments.count >= 2, BtonConfig.isRepoSlug(arguments[1]) else { fail(usage) }
        let repo = arguments[1]
        let github = try GitHubClient()
        // The branch the app reads for a watched repo; the default branch otherwise.
        let branch = try BtonConfig.loadOrCreate(home: BtonHome()).repos
            .first { $0.slug.caseInsensitiveCompare(repo) == .orderedSame }?.branch
        // --flow reads a local file instead of the watched branch's, to try a flow before it lands.
        let flowData: Data? = if let index = arguments.firstIndex(of: "--flow"), index + 1 < arguments.count {
            try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
        } else {
            try await github.flowFile(repo: repo, branch: branch)
        }
        guard let flow = Flow.load(flowData).flow else { fail("\(repo): no supported flow", status: 1) }
        let read = try await github.openPullRequests(repo: repo)
        for pr in read.pullRequests.sorted(by: { $0.number < $1.number }) {
            guard let move = FlowEngine.move(for: pr, flow: flow) else {
                print("#\(pr.number)\t-")
                continue
            }
            let owner = move.owner.map { move.ownerFromRotation ? "\($0) (rotation)" : move.ownerWroteIt ? "\($0) (author: needs another reviewer)" : $0 } ?? "unassigned"
            let dispatch = FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: read.viewer) ? "\tdispatch" : ""
            print("#\(pr.number)\t\(move.tier)\(move.tierReason.map { " (\($0))" } ?? "")\t\(move.name)\t\(owner)\(dispatch)")
        }
    case "lease":
        guard arguments.count >= 4, BtonConfig.isRepoSlug(arguments[2]), let item = LeaseItem(arguments[3]) else { fail(usage) }
        let (action, repo) = (arguments[1], arguments[2])
        // Validated in full before any I/O, so a usage error never reads as "not held".
        var job: UUID?
        if arguments.count == 6, arguments[4] == "--job", let parsed = UUID(uuidString: arguments[5]) {
            job = parsed
        } else if arguments.count != 4 {
            fail(usage)
        }
        switch action {
        case "claim": break
        case "renew", "release": guard job != nil else { fail(usage) }
        case "check": guard job == nil else { fail(usage) }
        default: fail(usage)
        }
        do {
            let github = try GitHubClient()
            let store = try LeaseStore(home: BtonHome(), holder: try await github.viewer(), github: github)
            // The repo's work label follows a schedule agent's claim too, and the release takes off the
            // label the claim added; a failure only warns.
            let config = try? JSONDecoder().decode(BtonConfig.self, from: Data(contentsOf: BtonHome().configURL))
            let configured = config.flatMap { WorkLabels.label(for: repo, in: $0) }
            let label = { (on: Bool, label: String?) async in
                await WorkLabels.set(on, label: label, item: item, repo: repo, github: github, note: { @Sendable in warn($0) })
            }
            switch action {
            case "claim":
                switch try await store.claim(item, in: repo, job: job ?? UUID()) {
                case let .claimed(lease):
                    print(lease.record.job.uuidString)
                    if let configured {
                        let saved = WorkLabels.claimFile(job: lease.record.job, repo: repo, item: item, home: BtonHome())
                        try? FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? Data(configured.utf8).write(to: saved)
                    }
                    await label(true, configured)
                case let .notClaimed(holder): fail("held by \(holder.map(describe) ?? "someone else")", status: 1)
                }
            case "renew", "release":
                let lease = try await store.current(item, in: repo, job: job!)
                if action == "renew" {
                    _ = try await store.renew(lease)
                } else {
                    // Off before the release, so it never comes off a claim made right after it.
                    let saved = WorkLabels.claimFile(job: lease.record.job, repo: repo, item: item, home: BtonHome())
                    let added = (try? String(contentsOf: saved, encoding: .utf8)).flatMap { WatchedRepo.isLabelName($0) ? $0 : nil }
                    await label(false, added ?? configured)
                    try await store.release(lease)
                    try? FileManager.default.removeItem(at: saved)
                }
            case "check":
                switch try await store.state(of: item, in: repo) {
                case .absent: print("absent")
                case let .held(record): print("held\t\(describe(record))")
                case let .free(record): print("free\t\(describe(record))")
                }
            default:
                fail(usage)
            }
        } catch LeaseError.lost, LeaseError.notHolder {
            fail("not held by this job", status: 1)
        } catch {
            fail(error.localizedDescription, status: 3)
        }
    case "watch":
        var seconds: Double?
        if arguments.count == 3, arguments[1] == "--for", let value = Double(arguments[2]) {
            seconds = value
        } else if arguments.count != 1 {
            fail(usage)
        }
        let home = BtonHome()
        let engine: Engine
        do {
            engine = try Engine(home: home) { print("\(Date.now.formatted(.iso8601)) \($0)") }
        } catch {
            fail(error.localizedDescription, status: 3)
        }
        let stop = seconds.map { Date.now + $0 }
        // A job that ends wakes the loop, so its agent takes the next job without waiting a poll.
        let ended = JobEnded()
        await engine.onJobEnded { Task { await ended.fire() } }
        while stop.map({ Date.now < $0 }) ?? true {
            let started = Date.now
            let snapshot = await engine.tick()
            if let problem = snapshot.problem { print("\(Date.now.formatted(.iso8601)) problem: \(problem)") }
            // Fixed rate: a tick starts every pollSeconds, however long the last one took.
            let poll = (try? BtonConfig.loadOrCreate(home: home).pollSeconds) ?? 60
            let next = max(0, Double(poll) - Date.now.timeIntervalSince(started))
            let wait = stop.map { min(next, max(0, $0.timeIntervalSinceNow)) } ?? next
            let deadline = Date.now + wait
            while Date.now < deadline, !(await ended.take()) {
                try await Task.sleep(for: .seconds(min(1, max(0, deadline.timeIntervalSinceNow))))
            }
        }
    case "prs":
        guard arguments.count == 1 else { fail(usage) }
        let snapshot = await (try Engine(home: BtonHome())).tick(dispatching: false)
        if let problem = snapshot.problem { fail(problem, status: 3) }
        let money = { (cost: Decimal?) in cost.map { "$\($0)" } ?? "-" }
        for pr in snapshot.openPullRequests {
            print("open\t\(pr.repo)#\(pr.number)\t\(pr.move.map { "\($0.name) \($0.owner ?? "unassigned")" } ?? "-")\t\(money(pr.cost))")
        }
        for pr in snapshot.merged { print("merged\t\(pr.repo)#\(pr.number)\t\(money(pr.totalCost))") }
    case "jobs":
        guard arguments.count == 1 else { fail(usage) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        for job in try JobStore(home: BtonHome()).all() {
            print(String(decoding: try encoder.encode(job), as: UTF8.self))
        }
    case "handoff":
        // The issue is optional: `--to` sits where it would be when there is none.
        let issue: Int? = arguments.count == 6 ? Int(arguments[2]) : nil
        guard [5, 6].contains(arguments.count), BtonConfig.isRepoSlug(arguments[1]),
              arguments.count == 5 || (issue ?? 0) > 0, arguments[arguments.count - 3] == "--to" else { fail(usage) }
        do {
            let posted = try await GitHubClient().handOff(to: arguments[arguments.count - 2], text: arguments[arguments.count - 1],
                                                          repo: arguments[1], issue: issue)
            print(posted ? "posted" : "already posted")
        } catch let problem as Handoff.Problem {
            fail(problem.localizedDescription)
        }
    case "prices":
        guard arguments == ["prices", "refresh"] else { fail(usage) }
        do {
            let list = try await PriceFeed.refresh(home: BtonHome())
            print("\(list.models.count) model prices from \(list.source ?? "?")")
        } catch {
            fail(error.localizedDescription, status: 3)
        }
    default:
        fail(usage)
    }
} catch {
    fail(error.localizedDescription, status: 3)
}

func describe(_ record: LeaseRecord) -> String {
    "\(record.holder)@\(record.host) job \(record.job.uuidString) \(record.released ? "released" : "until \(record.expires.formatted(.iso8601))")"
}

/// Set when a job ends, cleared by the watch loop that wakes on it.
actor JobEnded {
    private var fired = false
    func fire() { fired = true }
    func take() -> Bool {
        defer { fired = false }
        return fired
    }
}
