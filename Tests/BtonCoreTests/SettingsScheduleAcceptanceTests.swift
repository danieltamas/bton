@testable import BtonCore
import Foundation
import Testing

private enum SettingsScheduleFixture {
    static let repo = "acme/widget"
    static let agents = ["codex": AgentTemplate(argv: ["codex", "{prompt}"])]
    static let now = Date(timeIntervalSince1970: 120_030)

    static func entry(number: Int = 7) -> ScheduleEntry {
        ScheduleEntry(name: "Daily check", everyMinutes: 10, enabled: true,
                      repo: repo, agent: "codex", prompt: "Inspect the synthetic widget.", number: number)
    }

    static func candidates(_ entries: [ScheduleEntry], jobs: [Job] = [],
                           branch: String = "main", now: Date = SettingsScheduleFixture.now) -> [DispatchCandidate] {
        DispatchPlanner.scheduled(entries, jobs: jobs, repo: repo, defaultBranch: branch, me: "octo", now: now)
    }

    static func job(repo: String = SettingsScheduleFixture.repo, item: String = "schedule-7", at: Date,
                    status: Job.Status = .succeeded) -> Job {
        Job(id: UUID(), key: JobKey(repo: repo, item: item, move: "schedule", head: "old-minute"),
            agent: "codex", startedAt: at, status: status)
    }

    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git", arguments, in: directory,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            timeout: .seconds(120))
        guard result.status == 0 else {
            Issue.record("git \(arguments) exited \(result.status): \(result.stderr)")
            throw DispatchError.worktree(result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func repository(in root: URL, origin: String?) async throws -> URL {
        let clone = root.appendingPathComponent("clone")
        try await git(["init", "--initial-branch=main", clone.path], in: root)
        if let origin { try await git(["remote", "add", "origin", origin], in: clone) }
        return clone
    }

    static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

@Suite(ProcessBound())
struct SettingsScheduleAcceptanceTests {
    @Test func scheduleLegacyInitializerAndItemCompleteness() throws {
        let legacy = ScheduleEntry(name: "Daily check", everyMinutes: 10, enabled: true)
        #expect(legacy.repo == nil)
        #expect(legacy.agent == nil)
        #expect(legacy.prompt == nil)
        #expect(legacy.number == nil)
        #expect(legacy.timeoutMinutes == nil)
        #expect(legacy.item == nil)
        let complete = SettingsScheduleFixture.entry()
        #expect(complete.item == "schedule-7")
        #expect(LeaseItem(try #require(complete.item)) != nil)
        var missingRepo = complete; missingRepo.repo = nil
        var missingAgent = complete; missingAgent.agent = nil
        var missingPrompt = complete; missingPrompt.prompt = nil
        var emptyPrompt = complete; emptyPrompt.prompt = ""
        var missingNumber = complete; missingNumber.number = nil
        for entry in [missingRepo, missingAgent, missingPrompt, emptyPrompt, missingNumber] {
            #expect(entry.item == nil)
        }
    }

    @Test func scheduleValidationRejectsEachInvalidField() {
        let valid = SettingsScheduleFixture.entry()
        let agents = SettingsScheduleFixture.agents
        #expect(valid.problem(among: [], agents: agents) == nil)
        var invalid: [ScheduleEntry] = []
        var entry = valid; entry.name = "   "; invalid.append(entry)
        for minutes in [4, 10_081] {
            entry = valid; entry.everyMinutes = minutes; invalid.append(entry)
        }
        entry = valid; entry.repo = nil; invalid.append(entry)
        entry = valid; entry.agent = nil; invalid.append(entry)
        entry = valid; entry.agent = "unknown"; invalid.append(entry)
        for prompt: String? in [nil, "", " \n\t "] {
            entry = valid; entry.prompt = prompt; invalid.append(entry)
        }
        for minutes in [0, 481] {
            entry = valid; entry.timeoutMinutes = minutes; invalid.append(entry)
        }
        for candidate in invalid {
            #expect(candidate.problem(among: [], agents: agents)?.isEmpty == false)
        }
        for minutes in [5, 10_080] {
            entry = valid; entry.everyMinutes = minutes
            #expect(entry.problem(among: [], agents: agents) == nil)
        }
        for minutes in [1, 480] {
            entry = valid; entry.timeoutMinutes = minutes
            #expect(entry.problem(among: [], agents: agents) == nil)
        }
    }

    @Test func scheduleNamesIgnoreCaseButExcludeSameNumber() {
        let entry = SettingsScheduleFixture.entry()
        var duplicate = SettingsScheduleFixture.entry(number: 8)
        duplicate.name = entry.name.uppercased()
        #expect(entry.problem(among: [duplicate], agents: SettingsScheduleFixture.agents)?.isEmpty == false)
        duplicate.number = entry.number
        #expect(entry.problem(among: [entry, duplicate], agents: SettingsScheduleFixture.agents) == nil)
    }

    @Test func scheduleNewNumbersAreInRangeAndUnused() {
        var entries = [SettingsScheduleFixture.entry(number: 1), SettingsScheduleFixture.entry(number: 999_999_999)]
        for _ in 0..<100 {
            let number = ScheduleEntry.newNumber(avoiding: entries)
            #expect((1...999_999_999).contains(number))
            #expect(!entries.contains { $0.number == number })
            entries.append(SettingsScheduleFixture.entry(number: number))
        }
    }

    @Test func scheduledNeverRunCandidateCarriesDispatchContract() throws {
        var entry = SettingsScheduleFixture.entry()
        for (minutes, seconds) in [(nil as Int?, 3600), (23, 1380)] {
            entry.timeoutMinutes = minutes
            let candidates = SettingsScheduleFixture.candidates([entry])
            #expect(candidates.count == 1)
            let candidate = try #require(candidates.first)
            if case let .branch(branch) = candidate.target { #expect(branch == "main") }
            else { Issue.record("A schedule must target the default branch") }
            #expect(candidate.pr == nil)
            #expect(candidate.key == JobKey(repo: "acme/widget", item: "schedule-7", move: "schedule", head: "m2000"))
            #expect(candidate.agent == "codex")
            #expect(candidate.prompt == "Inspect the synthetic widget.")
            #expect(candidate.command == nil)
            #expect(!candidate.postComment)
            #expect(candidate.timeout == .seconds(seconds))
            #expect(candidate.move.name == "schedule")
            #expect(candidate.move.owner == "octo")
        }
    }

    @Test func scheduledFiltersDisabledForeignIncompleteAndMissingBranch() {
        let complete = SettingsScheduleFixture.entry()
        var disabled = complete; disabled.enabled = false
        var foreign = complete; foreign.repo = "acme/other"
        var noRepo = complete; noRepo.repo = nil
        var noAgent = complete; noAgent.agent = nil
        var noPrompt = complete; noPrompt.prompt = nil
        var emptyPrompt = complete; emptyPrompt.prompt = ""
        var noNumber = complete; noNumber.number = nil
        #expect(SettingsScheduleFixture.candidates([disabled, foreign, noRepo, noAgent, noPrompt, emptyPrompt, noNumber]).isEmpty)
        #expect(SettingsScheduleFixture.candidates([complete], branch: "").isEmpty)
        var caseVariant = complete; caseVariant.repo = "ACME/WIDGET"
        #expect(SettingsScheduleFixture.candidates([caseVariant]).count == 1)
    }

    @Test func scheduledUsesNewestRunAndExactIntervalBoundary() {
        let now = SettingsScheduleFixture.now
        let newest = now.addingTimeInterval(-600)
        let jobs = [
            SettingsScheduleFixture.job(at: newest.addingTimeInterval(-900)),
            SettingsScheduleFixture.job(at: newest, status: .failed),
            SettingsScheduleFixture.job(at: newest.addingTimeInterval(-300), status: .cancelled)
        ]
        let entry = SettingsScheduleFixture.entry()
        #expect(SettingsScheduleFixture.candidates([entry], jobs: jobs, now: now.addingTimeInterval(-1)).isEmpty)
        #expect(SettingsScheduleFixture.candidates([entry], jobs: jobs, now: now).count == 1)
        #expect(SettingsScheduleFixture.candidates([entry], jobs: jobs, now: now.addingTimeInterval(1)).count == 1)
    }

    @Test func scheduledHistoryScopesRepoIgnoringCaseAndItem() {
        let now = SettingsScheduleFixture.now
        let entry = SettingsScheduleFixture.entry()
        let unrelated = [SettingsScheduleFixture.job(repo: "acme/other", at: now),
                         SettingsScheduleFixture.job(item: "schedule-8", at: now)]
        #expect(SettingsScheduleFixture.candidates([entry], jobs: unrelated).count == 1)
        let sameRepo = SettingsScheduleFixture.job(repo: "ACME/WIDGET", at: now)
        #expect(SettingsScheduleFixture.candidates([entry], jobs: unrelated + [sameRepo]).isEmpty)
    }

    @Test func scheduledSelectionHonorsAgentsRunningItemsAndCapacity() throws {
        let candidates = SettingsScheduleFixture.candidates([SettingsScheduleFixture.entry(), SettingsScheduleFixture.entry(number: 8)])
        #expect(candidates.count == 2)
        let agents = SettingsScheduleFixture.agents
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 2, agents: [:]).isEmpty)
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 0, agents: agents).isEmpty)
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 1, agents: agents).count == 1)
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 2, agents: agents).map(\.key.item) == ["schedule-7"])
        let running = SettingsScheduleFixture.job(at: SettingsScheduleFixture.now.addingTimeInterval(-900), status: .running)
        let selected = DispatchPlanner.select(candidates, jobs: [running], maxAgents: 2, agents: agents)
        #expect(selected.isEmpty)
        #expect(DispatchPlanner.select(candidates, jobs: [running], maxAgents: 1, agents: agents).isEmpty)
        #expect(DispatchPlanner.select(candidates, jobs: [running], maxAgents: 16, agents: agents).isEmpty)
    }

    @Test func pricesPersistExactDecimalsInBtonHome() throws {
        let root = try SettingsScheduleFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("state").path])
        #expect(PriceList.load(home: home).models.isEmpty)
        let low = try #require(Decimal(string: "0.3"))
        let medium = try #require(Decimal(string: "3.75"))
        let high = try #require(Decimal(string: "15"))
        let models = ["synthetic-small": ModelPrice(input: low, cacheRead: medium, cacheWrite: high, output: high),
                      "synthetic-large": ModelPrice(input: high, cacheRead: low, cacheWrite: medium, output: medium)]
        try PriceList(models: models).save(home: home)
        let expectedURL = home.url.appendingPathComponent("prices.json")
        #expect(PriceList.url(home: home) == expectedURL)
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        #expect(PriceList.load(home: home).models == models)
        let decoded = try JSONDecoder().decode(PriceList.self, from: Data(contentsOf: expectedURL))
        #expect(decoded.models == models)
    }

    @Test func agentTemplatesRequireProgramAndPromptButNotSession() {
        for argv in [[], ["", "{prompt}"], ["   ", "{prompt}"], ["codex"], ["codex", "{session}"]] {
            #expect(AgentTemplate(argv: argv).problem?.isEmpty == false)
        }
        for argv in [["codex", "{prompt}"], ["codex", "--prompt={prompt}"]] {
            #expect(AgentTemplate(argv: argv).problem == nil)
        }
        for template in BtonConfig.initial.agents.values { #expect(template.problem == nil) }
    }

    @Test func agentNamesAndInitialSettingsMeetRanges() {
        for name in ["claude", "codex", "my-agent2"] { #expect(BtonConfig.isAgentName(name)) }
        for name in ["", "Claude", "2fast", "a b", "a/b", String(repeating: "a", count: 33)] {
            #expect(!BtonConfig.isAgentName(name))
        }
        #expect(BtonConfig.pollSecondsRange == 15...3600)
        #expect(BtonConfig.maxAgentsRange == 0...16)
        #expect(BtonConfig.pollSecondsRange.contains(BtonConfig.initial.pollSeconds))
        #expect(BtonConfig.maxAgentsRange.contains(BtonConfig.initial.maxAgents))
    }

    @Test(arguments: ["https://github.com/acme/widget.git", "git@github.com:acme/widget.git"])
    func inspectGitHubOriginFromNestedFolder(_ origin: String) async throws {
        let root = try SettingsScheduleFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clone = try await SettingsScheduleFixture.repository(in: root, origin: origin)
        let nested = clone.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in [clone, nested] {
            let found = try await RepoOrigin.inspect(clone: path)
            #expect(found.slug == "acme/widget")
            #expect(SettingsScheduleFixture.canonical(found.top) == SettingsScheduleFixture.canonical(clone))
        }
    }

    @Test(arguments: [nil as String?, "https://gitlab.com/acme/widget.git"])
    func inspectAndVerifyRejectUnreadableOrigins(_ origin: String?) async throws {
        let root = try SettingsScheduleFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clone = try await SettingsScheduleFixture.repository(in: root, origin: origin)
        let paths = origin == nil ? [clone, root] : [clone]
        for path in paths {
            do {
                _ = try await RepoOrigin.inspect(clone: path)
                Issue.record("inspect must reject an absent or non-GitHub origin")
            } catch RepoOrigin.Unreadable.noOrigin { #expect(origin == nil) }
              catch RepoOrigin.Unreadable.notGitHub { #expect(origin != nil) }
            do {
                try await RepoOrigin.verify(clone: path, matches: "acme/widget")
                Issue.record("verify must reject an absent or non-GitHub origin")
            } catch RepoOrigin.Mismatch.noOrigin { #expect(origin == nil) }
              catch RepoOrigin.Mismatch.notGitHub { #expect(origin != nil) }
        }
    }

    @Test func verifyRejectsAnotherRepositoryWithTypedMismatch() async throws {
        let root = try SettingsScheduleFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clone = try await SettingsScheduleFixture.repository(in: root, origin: "https://github.com/acme/other.git")
        do {
            try await RepoOrigin.verify(clone: clone, matches: "acme/widget")
            Issue.record("A clone of another repository must be rejected")
        } catch let RepoOrigin.Mismatch.otherRepo(_, expected, actual) {
            #expect(expected == "acme/widget")
            #expect(actual == "acme/other")
        }
    }

    @Test func scheduleWorktreeRefreshesDetachedTipAndPreservesDirtyFiles() async throws {
        let root = try SettingsScheduleFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = root.appendingPathComponent("origin.git")
        let writer = root.appendingPathComponent("writer")
        let clone = root.appendingPathComponent("clone")
        try await SettingsScheduleFixture.git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
        try await SettingsScheduleFixture.git(["clone", origin.path, writer.path], in: root)
        try await SettingsScheduleFixture.git(["config", "user.name", "Synthetic Tester"], in: writer)
        try await SettingsScheduleFixture.git(["config", "user.email", "octo@example.invalid"], in: writer)
        try Data("original\n".utf8).write(to: writer.appendingPathComponent("tracked.txt"))
        try await SettingsScheduleFixture.git(["add", "tracked.txt"], in: writer)
        try await SettingsScheduleFixture.git(["-c", "commit.gpgsign=false", "commit", "-m", "Synthetic initial"], in: writer)
        try await SettingsScheduleFixture.git(["push", "origin", "main"], in: writer)
        try await SettingsScheduleFixture.git(["clone", origin.path, clone.path], in: root)
        let firstTip = try await SettingsScheduleFixture.git(["rev-parse", "HEAD"], in: writer)
        let tree = try await Worktrees.prepare(clone: clone, branch: "main", item: "schedule-7",
                                               ghPath: "/usr/bin/true", runner: ProcessRunner())
        #expect(SettingsScheduleFixture.canonical(tree) == SettingsScheduleFixture.canonical(clone.appendingPathComponent(".worktrees/bton-schedule-7")))
        #expect(try await SettingsScheduleFixture.git(["rev-parse", "HEAD"], in: tree) == firstTip)
        let initialBranch = try await ProcessRunner().run("/usr/bin/git", ["symbolic-ref", "-q", "HEAD"], in: tree, timeout: .seconds(120))
        #expect(initialBranch.status == 1)
        try await SettingsScheduleFixture.git(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic update"], in: writer)
        try await SettingsScheduleFixture.git(["push", "origin", "main"], in: writer)
        let nextTip = try await SettingsScheduleFixture.git(["rev-parse", "HEAD"], in: writer)
        #expect(nextTip != firstTip)
        let refreshed = try await Worktrees.prepare(clone: clone, branch: "main", item: "schedule-7",
                                                    ghPath: "/usr/bin/true", runner: ProcessRunner())
        #expect(SettingsScheduleFixture.canonical(refreshed) == SettingsScheduleFixture.canonical(tree))
        #expect(try await SettingsScheduleFixture.git(["rev-parse", "HEAD"], in: tree) == nextTip)
        let branch = try await ProcessRunner().run("/usr/bin/git", ["symbolic-ref", "-q", "HEAD"], in: tree, timeout: .seconds(120))
        #expect(branch.status == 1)
        for filename in ["untracked.txt", "tracked.txt"] {
            let file = tree.appendingPathComponent(filename)
            let contents = Data("synthetic work to preserve\n".utf8)
            try contents.write(to: file)
            try await SettingsScheduleFixture.git(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic dirty refresh"], in: writer)
            try await SettingsScheduleFixture.git(["push", "origin", "main"], in: writer)
            let dirtyRefreshTip = try await SettingsScheduleFixture.git(["rev-parse", "HEAD"], in: writer)
            let prepared = try await Worktrees.prepare(clone: clone, branch: "main", item: "schedule-7",
                                                       ghPath: "/usr/bin/true", runner: ProcessRunner())
            #expect(SettingsScheduleFixture.canonical(prepared) == SettingsScheduleFixture.canonical(tree))
            #expect(try await SettingsScheduleFixture.git(["rev-parse", "HEAD"], in: tree) == dirtyRefreshTip)
            #expect(try await SettingsScheduleFixture.git(["status", "--porcelain", "--untracked-files=all"], in: tree).isEmpty)
            let stash = try await SettingsScheduleFixture.git(["stash", "list", "--format=%s"], in: clone)
            #expect(stash.components(separatedBy: "\n").first?.contains("bton: leftovers in bton-schedule-7 before ") == true)
            let savedFile = filename == "untracked.txt" ? "refs/stash^3:\(filename)" : "refs/stash:\(filename)"
            #expect(try await SettingsScheduleFixture.git(["show", savedFile], in: clone) == "synthetic work to preserve")
            if filename == "untracked.txt" {
                #expect(!FileManager.default.fileExists(atPath: file.path))
            } else {
                #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")
            }
        }
    }
}
