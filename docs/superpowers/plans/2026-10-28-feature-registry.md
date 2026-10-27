# Feature Registry and Repo Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bton reads each repo's `.bton/features.json`, computes every feature's status from GitHub and the local clone, and shows the repo's page: a feature tree with statuses, filters, search and a feature's detail, entered from the footer's branch line.

**Architecture:** BtonCore gets the registry model (`FeatureRegistry`), the facts the statuses need (`FeatureFacts` from one GraphQL read per 50 numbers, `FeatureGit` from the clone), the pure status computation (`FeatureStatus`), and the pure page model (`FeaturePage`: tree, counts, filters, search, header sentences). An `EngineFeatures` extension reads the registry and facts each tick, in its own do/catch, and puts a `FeatureReport` per repo into the snapshot. The app shows `RepoPage` over the lists like a job's session, with thin views over `FeaturePage`.

**Tech Stack:** Swift 6 (BtonCore, SwiftUI app), `gh api graphql`, git in the clone, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-27-repo-features-design.md`, section "2. Feature registry and the repo page" (2a, 2b, 2d). Section 2c (the registry job) is the next plan; this one leaves the page's empty state without its button.

**Method (decided 2026-10-28, owner away):** plan 1's: codex writes the acceptance tests from this plan first, the implementer never edits them, codex reviews the diff (two fix rounds at most), full suite green, one line in `.ship/log.jsonl`. Branch `feat/features` from `main`; the merge is the owner's.

## Global Constraints

- The registry is `.bton/features.json` on the repo's default branch (or `WatchedRepo.branch` when set, like `flow.json`), never a PR branch's copy. `version` must be `1`; any other value, and a missing file, is "no registry". A file that is version 1 but does not decode or validate is "invalid" with a reason: the page shows the reason, never the empty state.
- Validation: ids unique across areas and across features; every `feature.area` names an area; every `parent` names a feature and no parent chain loops; `why` is one of `closes`, `branch`, `label`, `files`, `title`.
- Statuses, in order, first match wins: `live` (a linked PR's merge commit is on `origin/<to>`), `inDevelop` (a linked PR merged into the flow's `base`, and the flow has a `release` section), `building` (a linked PR is open), `ready` (a linked open issue has `stage:ready`), `spec` (a linked open issue has `stage:spec`), `idea`. `<to>` is `flow.release.to`, else the default branch. Without a flow, `base` is the default branch.
- Dates: `live` = the commit date of the oldest first-parent commit of `origin/<to>` that contains the merge commit (the merge commit's own date when it is first-parent on `<to>`); `inDevelop` = the earliest `mergedAt` among the merged PRs; `building` = the earliest open PR's `createdAt`; `ready` and `spec` = when the label was added (the issue's `createdAt` when the label event is not in the last 30); `idea` = the earliest linked issue's `createdAt`, else `firstSeen`, else nil. The timeline lists every status the feature passed, oldest first, each with its date and the number that put it there.
- Facts are read only for a registry that decoded as ready, at most every 10 minutes per repo unless the registry data changed or a PR merged or an issue appeared since; a failed read keeps the last facts and logs once. Git facts come from `refs/remotes/origin/<base>` and `refs/remotes/origin/<to>` as they are in the clone: the app's LocalSync fetches both every tick; `bton watch` reads what is there.
- A registry or facts read that fails never marks the repo unread and never stops its PR work (own do/catch, like `readIssues`).
- "N commits, D days" on the page = commits on `origin/<from>` not on `origin/<to>` (from `LocalBranchReport.workingOnly`) and the days since the oldest of them (`git log --format=%ct origin/<to>..origin/<from>`, last line). "Last release" = the latest `live` date across features; shown only when the flow has a `release` section.
- Files stay under 500 lines; `Engine.swift`, `AppStore.swift`, `Dispatcher.swift` and `RootView.swift` grow by at most a few lines each: new engine work goes in `Sources/BtonCore/EngineFeatures.swift`.
- `Flow` gains the optional `release` section now (decoding and validation only; the move is plan 3).
- Plain characters in every string shown to the user. Comments say why.

## Review Focus

1. A registry whose feature links a PR number GitHub does not know (deleted, or a typo): the facts read must not fail the whole registry; the link counts as nothing. Test in Task 2.
2. A PR merged into `develop`, then `develop` merged into `main` with a merge commit: `live` with the `main` merge's date, not the PR's. Test in Task 3.
3. A feature with both an open PR and a closed issue at `stage:ready`: `building`, never `ready` (closed issues count for nothing). Test in Task 3.
4. A fake `gh` that exits 2 with no "HTTP 404" for the registry path (every existing engine fixture): the tick must still read PRs and start moves; the snapshot's report says the registry could not be read. Test in Task 4.
5. An area with no feature and a feature whose area has features of three statuses: the collapsed area's counts and the chips' counts agree with the rows. Test in Task 5.

---

### Task 1: Registry model and the `release` section

**Files:**
- Create: `Sources/BtonCore/Features.swift`
- Modify: `Sources/BtonCore/Flow.swift` (`Flow.release`, validation in `load`)
- Modify: `Sources/BtonCore/GitHub.swift` (`file(repo:path:branch:)`; `flowFile` calls it)
- Modify: `docs/FLOW.md` (one row for `release`)
- Test: `Tests/BtonCoreTests/FeatureRegistryAcceptanceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct FeatureRegistry: Decodable, Sendable, Equatable {
      public static let relativePath = ".bton/features.json"
      public static let supportedVersion = 1
      public let version: Int
      public let areas: [Area]
      public let features: [Feature]
      public struct Area: Decodable, Sendable, Equatable, Identifiable { public let id: String, name: String, paths: [String] }
      public struct Feature: Decodable, Sendable, Equatable, Identifiable {
          public let id: String, name: String, summary: String, area: String, parent: String?, paths: [String]
          public let issues: [Link], prs: [Link]
          public let firstSeen: String?, closed: String?   // "YYYY-MM-DD"
      }
      public struct Link: Decodable, Sendable, Equatable { public let number: Int, why: String }
      public static let whys = ["closes", "branch", "label", "files", "title"]
      public static func load(_ data: Data?) -> RegistryStatus
      public func feature(_ id: String) -> Feature?
      public var linkedNumbers: [Int]            // every issue and PR number, sorted, unique
  }
  public enum RegistryStatus: Sendable, Equatable { case none, invalid(String), ready(FeatureRegistry) }
  ```
  An unknown version decodes as `.none`. `Flow.release: Release?` with `public struct Release: Decodable, Sendable { from, to, who: String; when: [String]; blockedBy: [String]?; checks: [[String]]?; merge: String?; timeoutMinutes: Int? }`; `Flow.load` returns `.invalid` when `merge` is neither `merge-commit` nor `fast-forward`, or `from`/`to` fail `WatchedRepo.isBranchName`, or `from == to`.
  `GitHubClient.file(repo: String, path: String, branch: String? = nil) async throws -> Data?` (nil on 404), used by `flowFile`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func decodesTheSpecExample() throws {
    // the JSON from spec 2a, verbatim
    guard case let .ready(registry) = FeatureRegistry.load(Data(specExample.utf8)) else { Issue.record("expected ready"); return }
    #expect(registry.areas.map(\.id) == ["whatsapp-intake"])
    let feature = try #require(registry.feature("filing-dedupe"))
    #expect(feature.prs.map(\.number) == [428, 419]); #expect(feature.prs[1].why == "files")
    #expect(feature.parent == nil); #expect(feature.closed == nil); #expect(feature.firstSeen == "2026-10-03")
    #expect(registry.linkedNumbers == [402, 419, 428])
}
@Test func missingAndUnknownVersionAreNone() {
    #expect(FeatureRegistry.load(nil) == .none)
    #expect(FeatureRegistry.load(Data(#"{"version":2,"areas":[],"features":[]}"#.utf8)) == .none)
}
@Test(arguments: [
    (#"{"version":1,"areas":[{"id":"a","name":"A","paths":[]}],"features":[{"id":"f","name":"F","summary":"","area":"zzz","parent":null,"paths":[],"issues":[],"prs":[],"firstSeen":null,"closed":null}]}"#, "area"),
    (#"...two features with id "f"..."#, "duplicate"),
    (#"...feature f with parent "g", g with parent "f"..."#, "parent"),
    (#"...a link with "why":"guess"..."#, "why"),
    (#"{"version":1,"areas":"#, "")   // malformed JSON: invalid, never none
]) func invalidRegistriesSayWhy(json: String, word: String) {
    guard case let .invalid(reason) = FeatureRegistry.load(Data(json.utf8)) else { Issue.record("expected invalid"); return }
    #expect(reason.lowercased().contains(word))
}
@Test func flowDecodesRelease() throws {
    // examples/team.flow.json plus the spec's release section (FlowFixture.flow with "release" inserted)
    let release = try #require(flow.release)
    #expect(release.from == "develop"); #expect(release.to == "main"); #expect(release.who == "danieltamas")
    #expect(release.when == ["ahead_commits:50", "ahead_days:7", "features_waiting:5"])
    #expect(release.blockedBy == ["pr_in_review_on_paths:migrations/**"]); #expect(release.merge == "merge-commit"); #expect(release.timeoutMinutes == 40)
}
@Test func flowWithoutReleaseIsNil() throws { #expect(try FlowFixture.flow().release == nil) }
@Test(arguments: ["\"merge\":\"squash\"", "\"to\":\"develop\"", "\"to\":\"-x\""]) func flowRefusesBadRelease(fragment: String) {
    guard case .invalid = Flow.load(/* team flow with a release section carrying the fragment */) else { Issue.record("expected invalid"); return }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --scratch-path .build-rx --filter FeatureRegistryAcceptanceTests`
Expected: compile error, `FeatureRegistry` undefined.

- [ ] **Step 3: Implement `Features.swift`, `Flow.release`, `GitHubClient.file`**

`load` mirrors `Flow.load`: read `version` first (`.none` unless 1), decode, then validate in the order of the Global Constraints, returning `.invalid("<what>: <id>")`. `linkedNumbers` is the sorted set of every link's number. In `Flow.load`, validate `release` after the dispatch rules. `file(repo:path:branch:)` is `flowFile`'s body with the path as a parameter.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --scratch-path .build-rx --filter "FeatureRegistryAcceptanceTests|FlowAcceptanceTests"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BtonCore/Features.swift Sources/BtonCore/Flow.swift Sources/BtonCore/GitHub.swift docs/FLOW.md Tests/BtonCoreTests/FeatureRegistryAcceptanceTests.swift
git commit -m "feat(features): the feature registry model and the flow's release section"
```

---

### Task 2: Facts from GitHub

**Files:**
- Create: `Sources/BtonCore/FeatureFacts.swift`
- Test: `Tests/BtonCoreTests/FeatureFactsAcceptanceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct FeatureFacts: Sendable, Equatable {
      public struct IssueFact: Sendable, Equatable { public let number: Int, open: Bool, createdAt: Date, labels: [String], labeledAt: [String: Date] }
      public struct PullRequestFact: Sendable, Equatable { public let number: Int, state: String /* OPEN, MERGED, CLOSED */, createdAt: Date, mergedAt: Date?, mergeCommit: String?, baseRef: String }
      public var issues: [Int: IssueFact] = [:]
      public var pullRequests: [Int: PullRequestFact] = [:]
      public static let chunk = 50
      public static func query(numbers: [Int]) -> String          // aliases n<number>: issueOrPullRequest(number:)
      public static func decode(_ data: Data) throws -> FeatureFacts
      public mutating func merge(_ other: FeatureFacts)
  }
  extension GitHubClient { public func featureFacts(repo: String, numbers: [Int]) async throws -> FeatureFacts }
  ```
  The query, per alias: `... on Issue { number state createdAt labels(first: 30) { nodes { name } } timelineItems(itemTypes: [LABELED_EVENT], last: 30) { nodes { ... on LabeledEvent { createdAt label { name } } } } } ... on PullRequest { number state createdAt mergedAt baseRefName mergeCommit { oid } }`. A null alias (unknown number) is skipped. `featureFacts` sends one query per `chunk` numbers and merges.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func queryNamesEveryNumberOnce() {
    let query = FeatureFacts.query(numbers: [402, 428])
    #expect(query.contains("n402: issueOrPullRequest(number: 402)")); #expect(query.contains("n428: issueOrPullRequest(number: 428)"))
    #expect(query.contains("LABELED_EVENT")); #expect(query.contains("mergeCommit { oid }"))
}
@Test func decodesIssuesAndPullRequestsAndSkipsUnknown() throws {
    // {"data":{"repository":{"n402":{"__typename":"Issue","number":402,"state":"OPEN","createdAt":"2026-10-01T10:00:00Z","labels":{"nodes":[{"name":"stage:ready"}]},"timelineItems":{"nodes":[{"createdAt":"2026-10-05T09:00:00Z","label":{"name":"stage:spec"}},{"createdAt":"2026-10-09T09:00:00Z","label":{"name":"stage:ready"}}]}},
    //                       "n428":{"__typename":"PullRequest","number":428,"state":"MERGED","createdAt":"2026-10-10T10:00:00Z","mergedAt":"2026-10-12T10:00:00Z","baseRefName":"develop","mergeCommit":{"oid":"abc"}},
    //                       "n999":null}}}
    let facts = try FeatureFacts.decode(data)
    #expect(facts.issues[402]?.labeledAt["stage:ready"] == Date(iso: "2026-10-09T09:00:00Z"))
    #expect(facts.issues[402]?.open == true); #expect(facts.issues[402]?.labels == ["stage:ready"])
    #expect(facts.pullRequests[428]?.mergeCommit == "abc"); #expect(facts.pullRequests[428]?.baseRef == "develop")
    #expect(facts.issues.count == 1); #expect(facts.pullRequests.count == 1)
}
@Test func chunksAt50() { #expect(FeatureFacts.chunk == 50) }
@Test func mergeKeepsBoth() { /* two facts with distinct numbers merge to the union */ }
```

- [ ] **Step 2: Run them to verify they fail** (`--filter FeatureFactsAcceptanceTests`, compile error)

- [ ] **Step 3: Implement `FeatureFacts.swift`**

Decode with `__typename` to pick the branch; `labeledAt` keeps the latest event per label name. `featureFacts` uses `gh(["api","graphql","-f","owner=","-f","name=","-f","query="])` like `openIssues`.

- [ ] **Step 4: Run the tests to verify they pass**

- [ ] **Step 5: Commit** `feat(features): the facts the statuses need, one GraphQL read per 50 numbers`

---

### Task 3: Git facts and the status computation

**Files:**
- Create: `Sources/BtonCore/FeatureGit.swift`, `Sources/BtonCore/FeatureStatus.swift`
- Test: `Tests/BtonCoreTests/FeatureStatusAcceptanceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct FeatureGit: Sendable, Equatable {
      /// Every commit on origin/<to> and origin/<base>, and the first-parent appearance dates on <to>.
      public var onRelease: Set<String> = [], onBase: Set<String> = []
      public var releasedAt: [String: Date] = [:]        // merge commit -> first-parent appearance date on <to>, filled for the commits asked
      public var unreleasedSince: Date?                  // oldest commit on origin/<from> not on origin/<to>; nil when none
      public static func read(clone: URL, base: String, to: String, commits: [String], runner: ProcessRunner = ProcessRunner()) async -> FeatureGit
  }
  public enum FeatureStatus: String, Sendable, CaseIterable, Comparable {   // in rank order
      case live, inDevelop = "in develop", building, ready, spec, idea
  }
  public struct FeatureStanding: Sendable, Equatable {
      public struct Event: Sendable, Equatable { public let status: FeatureStatus, at: Date?, number: Int? }
      public let status: FeatureStatus
      public var since: Date? { timeline.last { $0.status == status }?.at }
      public let timeline: [Event]                       // oldest first, one per status reached
      public let openIssues: Int, openPullRequests: Int
      public let changes: [Int]                          // merged PR numbers, newest merge first
  }
  public enum FeatureStatuses {
      public static func standing(of feature: FeatureRegistry.Feature, facts: FeatureFacts, git: FeatureGit,
                                  base: String, hasRelease: Bool) -> FeatureStanding
  }
  ```
  `read`: `git rev-list refs/remotes/origin/<to>` and `...<base>` into the sets (empty when the ref is missing); for each of `commits` on `<to>`: `git log --first-parent --ancestry-path --format=%H:%ct <sha>..refs/remotes/origin/<to>`, last line's date, or `git show -s --format=%ct <sha>` when the range is empty; `unreleasedSince` from `git log --format=%ct refs/remotes/origin/<to>..refs/remotes/origin/<base>`, last line (so `<from>` is `base`).

- [ ] **Step 1: Write the failing tests**

A fixture makes a temp git repo as the clone with `refs/remotes/origin/develop` and `refs/remotes/origin/main` (plain `git update-ref`): commits A (shared), B merged into develop as a merge commit M1 at day 10, develop merged into main as merge commit R1 at day 19; a second PR merge M2 on develop at day 20 not on main. Facts are built in code.

```swift
@Test func liveTakesTheMainMergeDate() async throws {
    // feature links PR 428 (MERGED, mergeCommit M1, mergedAt day 10) and issue 402 (closed)
    let git = await FeatureGit.read(clone: f.clone, base: "develop", to: "main", commits: ["M1", "M2"])
    let standing = FeatureStatuses.standing(of: feature, facts: facts, git: git, base: "develop", hasRelease: true)
    #expect(standing.status == .live)
    #expect(standing.since == f.date(ofCommit: "R1"))
    #expect(standing.timeline.map(\.status) == [.idea, .building, .inDevelop, .live])
    #expect(standing.changes == [428])
}
@Test func mergedIntoDevelopIsInDevelopOnlyWithARelease() async throws {
    // PR 430 merged as M2
    #expect(standing(hasRelease: true).status == .inDevelop); #expect(standing(hasRelease: true).since == mergedAt430)
    #expect(standing(hasRelease: false).status == .idea)       // without a release section <to> is the default branch (main): M2 is not on it, and "in develop" never applies
}
@Test func openPullRequestBeatsClosedReadyIssue() { /* open PR + closed issue with stage:ready -> .building, since the PR's createdAt */ }
@Test func readyAndSpecFromOpenIssueLabels() { /* open issue stage:ready -> .ready since labeledAt; stage:spec -> .spec; label event missing -> createdAt */ }
@Test func ideaUsesEarliestIssueThenFirstSeen() { /* no links: .idea with since == firstSeen; one closed issue only: .idea since its createdAt */ }
@Test func unknownLinksCountForNothing() { /* links to numbers absent from facts -> .idea */ }
@Test func unreleasedSinceIsTheOldestCommitNotOnMain() async { /* == date of M2's first commit */ }
@Test func missingRefsReadAsEmpty() async { /* a clone without origin/main: onRelease empty, no crash */ }
```

- [ ] **Step 2: Run them to verify they fail**

- [ ] **Step 3: Implement `FeatureGit.swift` and `FeatureStatus.swift`**

`standing` walks the spec table top down with the facts, builds the timeline from the events that happened (idea first when any date exists), counts open issues and PRs among the links, and lists merged PR numbers by `mergedAt` descending.

- [ ] **Step 4: Run the tests to verify they pass**

- [ ] **Step 5: Commit** `feat(features): statuses and their dates from GitHub facts and the clone`

---

### Task 4: The engine reads the registry and reports

**Files:**
- Create: `Sources/BtonCore/EngineFeatures.swift`
- Modify: `Sources/BtonCore/Engine.swift` (`Snapshot.features`, one call in `tick` beside `readIssues`, one stored property)
- Test: `Tests/BtonCoreTests/FeatureReportAcceptanceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct FeatureReport: Sendable, Equatable {
      public let repo: String
      public let registry: RegistryStatus
      public var standings: [String: FeatureStanding] = [:]   // by feature id
      public var unreleasedSince: Date?
      public var lastRelease: Date?                               // latest live date; nil without a release section
      public var hasRelease: Bool
      public var readAt: Date?
      /// Why the registry or its facts could not be read this time; the rest is from the last good read.
      public var problem: String?
  }
  // Engine.Snapshot
  public var features: [String: FeatureReport] = [:]            // by slug
  // EngineFeatures.swift
  extension Engine {
      func readFeatures(repo: WatchedRepo, flow: Flow?, defaultBranch: String, merged: [MergedPullRequest]) async
      static let factsEvery: TimeInterval = 600
  }
  ```
  State kept on the engine: per lowercased slug, the last registry data hash, the last facts and when they were read, the last report. Facts are re-read when the hash changed, or `factsEvery` passed, or a merged PR's `mergedAt` or an open issue's `createdAt` is newer than the last read. Git facts are read on every facts read, for the merge commits of the merged links.

- [ ] **Step 1: Write the failing tests**

Using `StartMovesFixture` (its fake `gh` exits 2 for unknown paths):

```swift
@Test(ProcessBound()) func unreadableRegistryNeverBlocksTheRepo() async throws {
    let f = try await StartMovesFixture.make(startMoves: true)
    defer { f.remove() }
    let snapshot = await f.engine().tick()
    #expect(snapshot.problem == nil)
    #expect(snapshot.openPullRequests.count == 1)
    #expect(snapshot.features[f.repo]?.registry == .none || snapshot.features[f.repo]?.problem != nil)   // read failed, said so, nothing else changed
}
@Test(ProcessBound()) func registryOnTheDefaultBranchIsReported() async throws {
    // the fixture's gh gets a case for repos/synthetic/project/contents/.bton/features.json (the spec example)
    // and for the facts query (graphql with "issueOrPullRequest" in $* -> a payload where 402 is OPEN stage:ready, 428 and 419 are MERGED into main with mergeCommit = the clone's HEAD)
    let report = try #require(snapshot.features[f.repo])
    guard case .ready = report.registry else { Issue.record("expected ready"); return }
    #expect(report.standings["filing-dedupe"]?.status == .live)
    #expect(report.hasRelease == false); #expect(report.lastRelease == nil)
}
@Test(ProcessBound()) func factsAreNotReadAgainWithinTenMinutes() async throws {
    // two ticks: the gh-calls log has one facts query
}
@Test(ProcessBound()) func invalidRegistryIsReportedAsInvalid() async throws { /* version 1, bad area -> .invalid */ }
```

- [ ] **Step 2: Run them to verify they fail**

- [ ] **Step 3: Implement `EngineFeatures.swift`**

`readFeatures` runs after `readIssues` in `tick`, inside its own do/catch, and writes `snapshot.features[repo.slug]`. A failed registry read keeps the last report with `problem` set and logs `"<slug>: features not read: <reason>"` once per reason.

- [ ] **Step 4: Run the tests to verify they pass**, then the full suite.

- [ ] **Step 5: Commit** `feat(features): the engine reads the registry and reports every feature's standing`

---

### Task 5: The page model

**Files:**
- Create: `Sources/BtonCore/FeaturePage.swift`
- Test: `Tests/BtonCoreTests/FeaturePageAcceptanceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum FeatureFilter: String, CaseIterable, Sendable { case shipsNext = "ships next", building, live, ideas }
  public struct FeaturePage: Sendable, Equatable {
      public struct Row: Sendable, Equatable, Identifiable { public let id: String, feature: FeatureRegistry.Feature, standing: FeatureStanding, depth: Int }
      public struct AreaRows: Sendable, Equatable, Identifiable { public let id: String, area: FeatureRegistry.Area, rows: [Row], counts: [FeatureStatus: Int] }
      public let areas: [AreaRows]                       // registry order; features: parents before children, siblings by name
      public static func make(registry: FeatureRegistry, report: FeatureReport, filter: FeatureFilter?, query: SearchQuery) -> FeaturePage
      public static func count(_ filter: FeatureFilter, report: FeatureReport) -> Int
      public static func matches(_ filter: FeatureFilter, _ status: FeatureStatus) -> Bool   // shipsNext: inDevelop; building: building; live: live; ideas: ready, spec, idea
      /// "14 features in develop that main lacks." (hasRelease only; nil otherwise), "Last release Oct 19."
      public static func summary(report: FeatureReport, to: String, now: Date) -> String?
      /// "100 commits, 8 days" from the branch report's counts and unreleasedSince; nil when nothing is ahead.
      public static func ahead(commits: Int?, since: Date?, now: Date) -> String?
  }
  ```
  Search matches a feature's name, summary, id and linked numbers (`SearchQuery.matches(numbers:texts:)`); a matching child keeps its parent row; a filter keeps a feature when its status matches, and keeps a parent whose child matches. Closed features (`closed != nil`) are left out. An area with no rows after filtering is left out; with no filter and no query an empty area is still listed with zero counts.

- [ ] **Step 1: Write the failing tests** (pure, a registry with two areas, three features including a sub-feature, standings built in code)

```swift
@Test func treeOrdersParentsBeforeChildren() { /* rows ids == ["filing-dedupe", "same-photo", "voice-notes"], depths [0, 1, 0] */ }
@Test func collapsedCountsMatchRows() { /* counts[.inDevelop] == 2, counts[.building] == 1 */ }
@Test func chipCountsMatchFilters() { /* count(.shipsNext) == 2 ... and sum over filters == features not closed */ }
@Test func filterKeepsAMatchingChildsParent() { /* filter .building where only the child builds: parent row kept, depth preserved */ }
@Test func searchByNumberAndWord() { /* "#433" finds voice-notes; "dedupe" finds filing-dedupe; an unmatched area is gone */ }
@Test func summarySentences() {
    #expect(FeaturePage.summary(report: withRelease, to: "main", now: now) == "14 features in develop that main lacks. Last release Oct 19.")
    #expect(FeaturePage.summary(report: withoutRelease, to: "main", now: now) == nil)
    #expect(FeaturePage.ahead(commits: 100, since: eightDaysAgo, now: now) == "100 commits, 8 days")
    #expect(FeaturePage.ahead(commits: 0, since: nil, now: now) == nil)
}
@Test func closedFeaturesAreHidden() {}
```

- [ ] **Step 2: Run to verify they fail**; **Step 3: Implement**; **Step 4: Run to verify they pass**

- [ ] **Step 5: Commit** `feat(features): the page model: tree, counts, filters, search, header sentences`

---

### Task 6: The repo page in the app

**Files:**
- Create: `Sources/Bton/RepoPage.swift` (header, chips, search, empty and invalid states), `Sources/Bton/FeatureTree.swift` (areas and rows), `Sources/Bton/FeatureDetail.swift`
- Modify: `Sources/Bton/AppStore.swift` (`features`, `viewingRepo`, `openRepoPage(_:)`; `apply` copies `snapshot.features` for read repos), `Sources/Bton/RootView.swift` (one `else if` in `content`; `show` clears `viewingRepo`), `Sources/Bton/BranchStatusViews.swift` (entry), `Sources/Bton/RepoFilter.swift` (a trailing chevron per repo row), `Sources/Bton/DemoShots.swift` (one shot with a registry, optional)
- Test: none in the app target (no test target); the BtonCore tests above cover the logic. Build must pass.

**Interfaces:**
- Consumes: `FeaturePage`, `FeatureReport`, `FeatureStatus`, `LocalBranchReport` (branch marks and `workingOnly`).
- Produces: `AppStore.viewingRepo: String?`, `AppStore.openRepoPage(_ slug: String)`, `AppStore.features: [String: FeatureReport]`.

- [ ] **Step 1: Entry points.** `BranchSummary`: with one report, the button calls `store.openRepoPage(slug)` instead of opening the popover; with several, the popover lists each repo as a row (`BranchMark`s and the repo's short name) that opens its page. The branch details text (`BranchDetails.describe`, `compare`, the problem, "Checked at") moves to the page's header popover under the branch marks. `RepoFilter` rows get an `IconButton(symbol: "chevron.right")` that opens the page and closes the popover.
- [ ] **Step 2: `RepoPage`.** `VStack`: header row (`IconButton("chevron.left")` with `.keyboardShortcut(.cancelAction)`, repo name in `.rowTitle`), branch line (`BranchMark` per branch, `FeaturePage.ahead(...)`), `FeaturePage.summary(...)` when non-nil in `.meta`, chip row (`Chip` per `FeatureFilter` with its count, the selected one `.filled`, `Theme.mint`), `SearchField`, then: `.none` -> `EmptyState(symbol: "square.grid.3x3", title: "No feature registry yet", detail: "The registry job builds .bton/features.json from the code graph, the issues and the merged PRs.")`; `.invalid(reason)` -> `ProblemText`; `.ready` -> `FeatureTree`. `report.problem` shows as `ProblemText` above the tree.
- [ ] **Step 3: `FeatureTree`.** A `ScrollView` of areas: an area header row (chevron, name, when collapsed one `Chip` per status with a count > 0, in status order) toggling `@State collapsed: Set<String>`; rows indented 14 pt per depth with a `└` glyph for depth 1 drawn as a short `Path`, name, status chip (`FeatureStatusChip`: live `Theme.success`, in develop `Theme.color(forStage: "review")`, building `"in-progress"`, ready `"ready"`, spec `"spec"`, idea `Theme.neutral`), `RelativeTime(since)` as "3d in status", then open counts as `"\(n) issues"`/`"\(n) PRs"` in `.meta` when > 0. A row is a button (`PressStyle`, `.pointingHandCursor()`) that opens `FeatureDetail`.
- [ ] **Step 4: `FeatureDetail`.** Back chevron and the feature's name; summary; `Eyebrow("Paths")` and the paths monospaced; `Eyebrow("Timeline")` with one line per event: status chip, date `.formatted(date: .abbreviated, time: .omitted)`, `#number` as a button opening `https://github.com/<slug>/issues/<n>` (GitHub redirects a PR number); `Eyebrow("Changes")` with the merged PRs newest first, number and (from `store.merged` when known) the title.
- [ ] **Step 5: Build** `swift build --scratch-path .build-rx` and run the app once with `BTON_HOME` pointed at a temp home holding a repo with a registry, or add a `DemoShots` snapshot with a registry and take the screenshot the README uses. Expected: the page opens from the footer, back returns to the lists.
- [ ] **Step 6: Commit** `feat(features): the repo's page: feature tree, filters, search, detail`

---

### Task 7: Docs and evidence

- [ ] `LOG.md` Unreleased: "The repo's page: every feature with its status, from the footer's branch line." `README.md` "What you get": one row. `docs/FLOW.md`: the `release` row (done in Task 1). Commit `docs: the repo page and the feature registry`.
- [ ] Full suite: `swift test --scratch-path .build-rx` green. Codex review from the diff; fix rounds (two at most). Append the `.ship/log.jsonl` line. Commit `chore(ship): evidence for the feature registry and repo page`.
