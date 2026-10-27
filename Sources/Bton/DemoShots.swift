import AppKit
import BtonCore
import SwiftUI

/// The README's screenshots: the real views over a made-up team, drawn by `ImageRenderer`
/// (`Bton --render-screenshots <dir>`). Nothing is read from or written to this Mac's Bton.
@MainActor
enum DemoShots {
    static let flag = "--render-screenshots"
    /// `--look solidGlass` draws them in another look; the saved choice is neither used nor changed.
    static let lookFlag = "--look"

    static func render(to directory: URL, look: Look = .bton) throws {
        Appearance.shared.look = look
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore()
        store.showDemo(snapshot, config: config)
        let panel = { (tab: Tab) in RootView(tab: tab).environment(store) }
        try write(hero(prs: panel(.pullRequests), jobs: panel(.jobs)), to: directory.appendingPathComponent("hero.png"))
        try write(panel(.pullRequests), to: directory.appendingPathComponent("pull-requests.png"))
        try write(panel(.jobs), to: directory.appendingPathComponent("jobs.png"))
        try write(panel(.triage), to: directory.appendingPathComponent("triage.png"))
        try write(triageIssue(store), to: directory.appendingPathComponent("triage-issue.png"))
        try write(pane(ReposPane()).environment(store), to: directory.appendingPathComponent("settings-repos.png"))
        try write(pane(AgentsPane()).environment(store), to: directory.appendingPathComponent("settings-agents.png"))
    }

    /// Drawn by an offscreen window, not `ImageRenderer`: that one leaves text fields and other
    /// AppKit-backed controls as placeholders. Nothing reaches the screen, so no capture permission.
    private static func write(_ view: some View, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.stillImage, true))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        let size = host.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }

    private static func hero(prs: some View, jobs: some View) -> some View {
        HStack(alignment: .top, spacing: 36) {
            prs.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
            jobs.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
                .padding(.top, 56)
        }
        .padding(.horizontal, 64)
        .padding(.top, 56)
        .padding(.bottom, 92)
        .background(Backdrop())
    }

    /// An issue open in the Triage tab with its three questions answered.
    private static func triageIssue(_ store: AppStore) -> some View {
        VStack(spacing: 0) {
            TriageView(issue: triage[0], answered: [0, 1, 0]) {}
        }
        .padding(.top, 14)
        .frame(width: 404, height: 860)
        .background(Backdrop())
        .environment(store)
        .preferredColorScheme(Theme.scheme)
    }

    private static func pane(_ content: some View) -> some View {
        content.padding(28).frame(width: 640, alignment: .topLeading).background(Backdrop())
            .preferredColorScheme(Theme.scheme)
    }

    // MARK: the made-up team

    private static let repo = "harbor/checkout"
    private static let now = Date.now

    private static var config: BtonConfig {
        var config = BtonConfig.initial
        config.pollSeconds = 300
        config.maxAgents = 3
        config.agents = [
            "claude": AgentTemplate(argv: ["claude", "-p", "{prompt}", "--session-id", "{session}",
                                           "--permission-mode", "acceptEdits"]),
            "codex": AgentTemplate(argv: ["codex", "exec", "--sandbox", "workspace-write", "{prompt}"]),
        ]
        config.repos = [WatchedRepo(slug: repo, path: "/Users/maya/code/checkout", branch: "main",
                                    environment: ["DATABASE_URL": "postgres://test@127.0.0.1:5999/checkout"])]
        config.schedules = [ScheduleEntry(name: "Nightly triage", everyMinutes: 1440, enabled: true,
                                          repo: repo, agent: "claude", prompt: "Triage new issues.", number: 1)]
        return config
    }

    private static var snapshot: Engine.Snapshot {
        var snapshot = Engine.Snapshot()
        snapshot.me = "maya"
        snapshot.at = now.addingTimeInterval(-40)
        snapshot.flows = [repo: Flow.load(Data(flow.utf8))]
        snapshot.openPullRequests = [
            pr(412, "Checkout: saved cards and one-tap reorder", by: "jonas", minutes: 12,
               move: Move(name: "review", owner: "maya", ownerFromRotation: true, tier: "feature", hasDispatch: true),
               cost: 0.84, working: true),
            pr(415, "Fix rounding in tax totals for EU carts", by: "maya", minutes: 26,
               move: Move(name: "merge", owner: "maya", ownerFromRotation: false, tier: "quick fix", hasDispatch: true),
               cost: 0.31),
            pr(401, "Order history: filters and CSV export", by: "jonas", minutes: 95,
               move: Move(name: "decide", owner: "maya", ownerFromRotation: false, tier: "feature", hasDispatch: false),
               cost: 3.40),
            pr(409, "Rotate payment webhook secrets without downtime", by: "lee", minutes: 48,
               move: Move(name: "fix", owner: "lee", ownerFromRotation: false, tier: "high-risk", hasDispatch: true),
               cost: 2.12),
            pr(418, "Raise image CDN timeouts", by: "lee", minutes: 7,
               move: Move(name: "review", owner: "jonas", ownerFromRotation: true, tier: "quick fix", hasDispatch: true)),
        ]
        snapshot.issueAsks = [
            IssueAsk(repo: repo, number: 388, title: "Apple Pay button missing on Safari 17",
                     url: URL(string: "https://github.com/\(repo)/issues/388")!, asker: "lee",
                     askedAt: now.addingTimeInterval(-34 * 60), commentID: "demo-388"),
        ]
        snapshot.triage = triage
        snapshot.jobs = [
            job("pr-395", "fix", agent: "claude", minutes: 26 * 60, took: 38, status: .succeeded, cost: 21.80),
            job("pr-398", "merge", agent: nil, minutes: 190, took: 3, status: .failed, detail: "`bash scripts/check.sh` exited 1"),
            job("pr-407", "merge", agent: nil, minutes: 140, took: 2, status: .succeeded),
            job("schedule-1", "schedule", agent: "claude", minutes: 120, took: 14, status: .succeeded, cost: 0.62),
            job("pr-409", "fix", agent: "claude", minutes: 55, took: 21, status: .succeeded, cost: 1.62),
            job("pr-415", "review", agent: "codex", minutes: 30, took: 6, status: .succeeded, cost: 0.31),
            job("pr-412", "review", agent: "claude", minutes: 9, took: nil, status: .running, cost: 0.84),
        ]
        return snapshot
    }

    private static var triage: [TriageIssue] {
        let issue = { (number: Int, title: String, labels: [String], body: String, days: Double) in
            TriageIssue(repo: repo, number: number, title: title, url: URL(string: "https://github.com/\(repo)/issues/\(number)")!,
                        createdAt: now.addingTimeInterval(-days * 86400), body: body, labels: labels)
        }
        return [
            issue(421, "Saved cards fail to charge after a currency switch", [],
                  "Customers who switch currency in the cart and pay with a saved card get a generic error, and the order stays unpaid. "
                      + "Reproduced on staging with EUR to RON. The payment intent is created in the old currency.", 1),
            issue(417, "Order confirmation email shows the wrong delivery date", ["priority:medium", "stage:triage"],
                  "The date uses the warehouse time zone, not the customer's.", 4),
            issue(399, "Dark mode: low contrast on the cart's discount banner", ["stage:triage"],
                  "The banner text is grey on a dark green background.", 9),
            issue(390, "Support multiple shipping addresses per account", ["priority:low", "stage:spec"],
                  "Customers who ship to family ask for an address book.", 16),
        ]
    }

    private static func pr(_ number: Int, _ title: String, by author: String, minutes: Double, move: Move,
                           cost: Decimal? = nil, working: Bool = false) -> PullRequest {
        var pr = PullRequest(repo: repo, number: number, title: title, author: author, authorAssociation: "MEMBER",
                             url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
                             headSha: String(repeating: "\(number % 10)", count: 40), headRef: "feature/\(number)",
                             baseRef: "main", body: "", isDraft: false, labels: [], assignees: [], comments: [],
                             updatedAt: now.addingTimeInterval(-minutes * 60), move: move)
        pr.cost = cost
        pr.isWorking = working
        return pr
    }

    private static func job(_ item: String, _ move: String, agent: String?, minutes: Double, took: Double?,
                            status: Job.Status, detail: String? = nil, cost: Decimal? = nil) -> Job {
        let started = now.addingTimeInterval(-minutes * 60)
        return Job(id: UUID(), key: JobKey(repo: repo, item: item, move: move, head: "4f2a9c1e"), agent: agent,
                   startedAt: started, endedAt: took.map { started.addingTimeInterval($0 * 60) }, status: status,
                   detail: detail, cost: cost)
    }

    private static let flow = """
    {
      "version": 1, "base": "main",
      "tier": { "marker": "Tier:", "values": ["quick fix", "feature", "high-risk"], "default": "quick fix" },
      "reviews": { "quick fix": [{ "heading": "## Review:" }], "feature": [{ "heading": "## Review:" }],
                   "high-risk": [{ "heading": "## Review:" }] },
      "fixed": "## Fixed:",
      "moves": [
        { "move": "review", "when": ["no_review_or_response_newer"], "who": "author" },
        { "move": "merge", "when": ["approved_current_head"], "who": "author" },
        { "move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author" }
      ],
      "dispatch": { "fix": { "agent": "claude", "prompt": "Fix PR #{number}." } }
    }
    """
}
