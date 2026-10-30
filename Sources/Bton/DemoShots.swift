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
        store.showStarOffer()
        try write(panel(.pullRequests), to: directory.appendingPathComponent("footer-star.png"))
        store.showStarOffer(starring: true)
        try write(panel(.pullRequests), to: directory.appendingPathComponent("footer-starring.png"))
        store.showStarOffer(false)
        try write(panel(.issues), to: directory.appendingPathComponent("issues.png"))
        store.readingDraft = snapshot.issueAsks[1]
        store.draftEdits[snapshot.issueAsks[1].notice] = """
            Three retries with a growing delay, as proposed: 1 min, 10 min, 1 hour. That copies Stripe's first \
            three attempts, and nobody has asked for more.

            **Dead-letter queue:** the payments team owns it. They already watch the `webhooks` dashboard, and a \
            delivery that fails three times is a payments problem before it is anything else.

            - [ ] `POST /webhooks/{id}/redeliver` needs the `admin` scope
            - [ ] the queue keeps a delivery for 7 days, then drops it with a log line

            ~~Weekly digest of the queue~~: not now, a dashboard tile is enough.
            """
        try write(panel(.issues), to: directory.appendingPathComponent("draft.png"))
        store.viewingIssue = snapshot.issueAsks[1]
        try write(panel(.issues), to: directory.appendingPathComponent("issue.png"))
        store.viewingIssue = nil
        store.readingDraft = nil
        store.draftEdits = [:]
        store.demoReplies = [1: .questions("Should the CSV sit beside the PDF export or replace it?")]
        let started = NewIssueSession(repo: repo)
        started.turns = [.init(text: "Let customers download their invoices as a CSV file.", round: 1)]
        let dictated = NewIssueSession(repo: repo)
        dictated.draft = "Retry a failed webhook delivery three times, with a growing delay, before it is marked failed."
        store.newIssues = [started, dictated]
        try write(panel(.triage), to: directory.appendingPathComponent("triage.png"))
        store.newIssues = []
        try write(triageIssue(store), to: directory.appendingPathComponent("triage-issue.png"))
        try write(newIssue(store, ready: false), to: directory.appendingPathComponent("new-issue.png"))
        try write(newIssue(store, ready: true), to: directory.appendingPathComponent("new-issue-ready.png"))
        try write(pane(ReposPane()).environment(store), to: directory.appendingPathComponent("settings-repos.png"))
        try write(pane(SchedulesPane()).environment(store), to: directory.appendingPathComponent("settings-schedules.png"))
        try write(pane(AgentsPane()).environment(store), to: directory.appendingPathComponent("settings-agents.png"))
        try write(pane(MorePane()).environment(store), to: directory.appendingPathComponent("settings-more.png"))
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

    /// A new issue part-way through its conversation, or with the issue written and scored.
    private static func newIssue(_ store: AppStore, ready: Bool) -> some View {
        let session = NewIssueSession(repo: repo)
        session.turns = [.init(text: "Let customers download their invoices as a CSV file.", round: 1)]
        store.demoReplies = [1: .questions("""
            #212 already adds PDF invoices (open, stage:spec), and src/invoices/export.ts has the PDF writer. \
            Should the CSV sit beside it or replace it?

            1. One row per invoice, or one per line item? I suggest one per line item, with the invoice number repeated.
            2. Which period can be exported? I suggest any range, up to 12 months at a time.
            3. Who can export: shop owners only, or staff too? I suggest owners only, like the PDF.
            """)]
        if ready {
            session.turns.append(.init(text: "One row per line item. Any range up to 12 months. Owners only.", round: 2))
            store.demoReplies[2] = .ready(title: "Export invoices as CSV, one row per line item", body: """
                Shop owners can download their invoices for a date range as a CSV file.

                **Exists:** `src/invoices/export.ts` writes the PDF; #212 plans the PDF layout. The CSV reuses its query.

                **Out of scope:** XLSX, scheduled exports.

                - [ ] A range of up to 12 months downloads a CSV, one row per line item
                - [ ] Only owners see the button
                - [ ] The invoice number repeats on each of its rows
                """)
            session.answers = [1, 1, 0]
        }
        return VStack(spacing: 0) {
            NewIssueView(session: session) {}
        }
        .padding(.top, 14)
        .frame(width: 404, height: ready ? 1120 : 560)
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
        config.repos = [
            WatchedRepo(slug: repo, path: "/Users/maya/code/checkout", branch: "main",
                        environment: ["DATABASE_URL": "postgres://test@127.0.0.1:5999/checkout"]),
            WatchedRepo(slug: "harbor/api", path: "/Users/maya/code/api", branch: "main"),
            WatchedRepo(slug: "harbor/mobile", path: "/Users/maya/code/mobile", branch: "main"),
            WatchedRepo(slug: "harbor/docs", path: "/Users/maya/code/docs", branch: "main"),
        ]
        config.voice = VoiceSettings(enabled: true)
        config.schedules = [
            ScheduleEntry(name: "Nightly triage", everyMinutes: 1440, enabled: true,
                          repo: repo, agent: "claude", prompt: "Triage new issues.", number: 1),
            ScheduleEntry(name: "Dependency sweep", everyMinutes: 10080, enabled: true,
                          repo: "harbor/api", agent: "codex", prompt: "Update patch-level dependencies.", number: 2),
            ScheduleEntry(name: "Flaky test hunt", everyMinutes: 1440, enabled: true,
                          repo: "harbor/mobile", agent: "claude", prompt: "Find and fix flaky tests.", number: 3),
            ScheduleEntry(name: "Docs drift check", everyMinutes: 10080, enabled: true,
                          repo: "harbor/docs", agent: "claude", prompt: "Compare the docs with the code.", number: 4),
        ]
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
            IssueAsk(repo: repo, number: 402, title: "Webhook retries: which backoff, and who owns the dead-letter queue?",
                     url: URL(string: "https://github.com/\(repo)/issues/402")!, asker: "jonas",
                     askedAt: now.addingTimeInterval(-6 * 60), commentID: "demo-402", handoff: true, thread: webhookThread),
            IssueAsk(repo: "harbor/api", number: 77, title: "Rate limits for the public orders endpoint: per key or per IP?",
                     url: URL(string: "https://github.com/harbor/api/issues/77")!, asker: "lee",
                     askedAt: now.addingTimeInterval(-2 * 3600), commentID: "demo-77"),
            IssueAsk(repo: "harbor/mobile", number: 215, title: "Push permission prompt: ask at launch or after the first order?",
                     url: URL(string: "https://github.com/harbor/mobile/issues/215")!, asker: "jonas",
                     askedAt: now.addingTimeInterval(-5 * 3600), commentID: "demo-215"),
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

    /// Issue 402 as a teammate wrote it, with the comment that asks: the README's issue screen.
    private static var webhookThread: [IssueComment] {
        let comment = { (id: String, author: String, body: String, minutes: Double) in
            IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: body,
                         createdAt: now.addingTimeInterval(-minutes * 60), url: nil)
        }
        return [
            comment("body", "lee", """
                A webhook that fails once is dropped today. Stripe and Shopify both retry; we should too.

                ## Proposal
                - Retry **three times** with a growing delay: 1 min, 10 min, 1 hour.
                - A delivery still failing after that goes to a dead-letter queue, kept 7 days.
                - `POST /webhooks/{id}/redeliver` replays one by hand.

                ## Decisions
                | # | Decision | Who | Date |
                |---|----------|-----|------|
                | D-1 | Retries live in the worker, not the API | lee | 2026-10-27 |

                > The delay schedule copies Stripe's first three attempts.
                """, 3 * 24 * 60),
            comment("demo-402-1", "jonas", "Agreed on three retries. The dead-letter queue needs an owner before I start.", 48 * 60),
            comment("demo-402", "jonas", "@dani which backoff do you want, and who owns the dead-letter queue? `bton handoff`", 6),
        ]
    }

    private static var triage: [TriageIssue] {
        let issue = { (number: Int, title: String, labels: [String], body: String, days: Double) in
            TriageIssue(repo: repo, number: number, title: title, url: URL(string: "https://github.com/\(repo)/issues/\(number)")!,
                        createdAt: now.addingTimeInterval(-days * 86400), body: body, labels: labels)
        }
        return [
            issue(421, "Saved cards fail to charge after a currency switch", [], """
                Customers who switch currency in the cart and pay with a saved card get a generic error, and the order stays unpaid.

                **Reproduced** on staging with EUR to RON:
                1. Add an item, switch the cart to RON.
                2. Pay with a saved card.
                3. The payment intent is created in the old currency, so `charge.failed` comes back.
                """, 1),
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
