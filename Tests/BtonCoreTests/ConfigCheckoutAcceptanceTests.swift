import BtonCore
import Foundation
import Testing

private let claudeArgv = [
    "claude", "-p", "{prompt}", "--session-id", "{session}",
    "--permission-mode", "acceptEdits", "--allowedTools",
    "Bash(git:*)", "Bash(gh:*)", "Bash(bun:*)", "Bash(bash scripts/*)",
]

private let legacyJSON = #"{"pollSeconds":45,"repos":["example-org/app"],"schedules":[{"enabled":true,"everyMinutes":1,"name":"Poll GitHub"}]}"#

private struct ConfigCheckoutFixture {
    let root: URL
    let home: BtonHome
    let legacyURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-acceptance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("state").path],
                        homeDirectory: root)
        legacyURL = root.appendingPathComponent(".config/bton/config.json")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func writeLegacy() throws {
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(legacyJSON.utf8).write(to: legacyURL)
    }

    func readConfig() throws -> BtonConfig {
        try JSONDecoder().decode(BtonConfig.self, from: Data(contentsOf: home.configURL))
    }

    func makeClone(origin: String?) throws -> URL {
        let clone = root.appendingPathComponent("clone with spaces-\(UUID())")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try git(["-C", clone.path, "init", "--quiet"])
        if let origin { try git(["-C", clone.path, "remote", "add", "origin", origin]) }
        return clone
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git fixture setup must succeed")
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

private func expectSameConfig(_ actual: BtonConfig, _ expected: BtonConfig) {
    #expect(actual.repos == expected.repos)
    #expect(actual.maxAgents == expected.maxAgents)
    #expect(actual.pollSeconds == expected.pollSeconds)
    #expect(actual.agents == expected.agents)
    #expect(actual.schedules == expected.schedules)
}

private func expectPrivateDirectory(_ url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o700)
}

@Test func initialConfigUsesTheApprovedMachineDefaults() {
    #expect(BtonConfig.initial.repos.isEmpty)
    #expect(BtonConfig.initial.maxAgents == 2)
    #expect(BtonConfig.initial.pollSeconds == 60)
    #expect(BtonConfig.initial.agents["claude"]?.argv == claudeArgv)
    #expect(BtonConfig.initial.agents["codex"] == nil)
}

@Test func skeletonConfigIsMigratedAndRemoved() throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    try fixture.writeLegacy()

    let migrated = try BtonConfig.loadOrCreate(home: fixture.home, legacyURL: fixture.legacyURL)
    let expectedRepos = [WatchedRepo(slug: "example-org/app", path: nil)]
    #expect(migrated.repos == expectedRepos)
    #expect(migrated.pollSeconds == 45)
    #expect(migrated.schedules == [ScheduleEntry(name: "Poll GitHub", everyMinutes: 1, enabled: true)])
    #expect(migrated.maxAgents == 2)
    #expect(migrated.agents["claude"]?.argv == claudeArgv)
    #expect(migrated.agents["codex"] == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.legacyURL.path))
    expectSameConfig(try fixture.readConfig(), migrated)
    try expectPrivateDirectory(fixture.home.url)
}

@Test func existingNewConfigWinsAndLeavesLegacyUntouched() throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    try fixture.writeLegacy()
    let legacyBytes = try Data(contentsOf: fixture.legacyURL)
    var existing = BtonConfig.initial
    existing.repos = [WatchedRepo(slug: "owner/current", path: fixture.root.path)]
    existing.maxAgents = 7
    existing.pollSeconds = 123
    existing.agents = ["custom": AgentTemplate(argv: ["/usr/bin/true", "{prompt}"])]
    existing.schedules = [ScheduleEntry(name: "Custom", everyMinutes: 9, enabled: false)]
    try existing.save(to: fixture.home.configURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.home.url.path)
    let configBytes = try Data(contentsOf: fixture.home.configURL)

    let loaded = try BtonConfig.loadOrCreate(home: fixture.home, legacyURL: fixture.legacyURL)
    expectSameConfig(loaded, existing)
    #expect(try Data(contentsOf: fixture.legacyURL) == legacyBytes)
    #expect(try Data(contentsOf: fixture.home.configURL) == configBytes)
    try expectPrivateDirectory(fixture.home.url)
}

@Test func firstRunPersistsInitialConfig() throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    let loaded = try BtonConfig.loadOrCreate(home: fixture.home, legacyURL: fixture.legacyURL)
    expectSameConfig(loaded, BtonConfig.initial)
    expectSameConfig(try fixture.readConfig(), BtonConfig.initial)
    #expect(!FileManager.default.fileExists(atPath: fixture.legacyURL.path))
    try expectPrivateDirectory(fixture.home.url)
}

@Test func homeResolutionAndPrepareUsePrivateDirectories() throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    let fallback = BtonHome(environment: [:], homeDirectory: fixture.root)
    #expect(fallback.url.path == fixture.root.appendingPathComponent(".bton").path)
    #expect(fixture.home.url.path == fixture.root.appendingPathComponent("state").path)
    #expect(fixture.home.configURL.path == fixture.home.url.appendingPathComponent("config.json").path)
    for home in [fallback, fixture.home] {
        try home.prepare()
        try expectPrivateDirectory(home.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: home.url.path)
        try home.prepare()
        try expectPrivateDirectory(home.url)
    }
}

@Test func separateHomesShareNoConfig() throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    let second = BtonHome(environment: ["BTON_HOME": fixture.root.appendingPathComponent("second").path],
                          homeDirectory: fixture.root)
    var firstConfig = try BtonConfig.loadOrCreate(home: fixture.home, legacyURL: fixture.legacyURL)
    let secondConfig = try BtonConfig.loadOrCreate(home: second, legacyURL: fixture.legacyURL)
    let secondBytes = try Data(contentsOf: second.configURL)
    firstConfig.repos = [WatchedRepo(slug: "owner/first", path: fixture.root.path)]
    firstConfig.pollSeconds = 17
    try firstConfig.save(to: fixture.home.configURL)

    expectSameConfig(try BtonConfig.loadOrCreate(home: fixture.home, legacyURL: fixture.legacyURL), firstConfig)
    expectSameConfig(try BtonConfig.loadOrCreate(home: second, legacyURL: fixture.legacyURL), secondConfig)
    #expect(try Data(contentsOf: second.configURL) == secondBytes)
}

@Test(arguments: [
    "git@github.com:o/r.git", "git@github.com:o/r",
    "https://github.com/o/r.git", "https://github.com/o/r",
    "ssh://git@github.com/o/r.git",
])
func githubOriginFormsNormalizeToSlug(_ remote: String) {
    #expect(RepoOrigin.slug(fromRemoteURL: remote) == "o/r")
}

@Test(arguments: ["https://gitlab.com/o/r.git", "git@gitlab.com:o/r.git", "garbage", ""])
func nonGitHubOriginsHaveNoSlug(_ remote: String) {
    #expect(RepoOrigin.slug(fromRemoteURL: remote) == nil)
}

@Test(arguments: ["example-org/app", "EXAMPLE-ORG/APP"])
func matchingCloneOriginIsAcceptedIgnoringCase(_ expected: String) async throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    let clone = try fixture.makeClone(origin: "git@github.com:example-org/app.git")
    try await RepoOrigin.verify(clone: clone, matches: expected)
}

@Test func nestedCloneFolderReturnsCloneRoot() async throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    let clone = try fixture.makeClone(origin: "git@github.com:o/r.git")
    let subfolder = clone.appendingPathComponent("nested/deeper")
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

    let verifiedRoot = try await RepoOrigin.verify(clone: subfolder, matches: "o/r")
    #expect(verifiedRoot.resolvingSymlinksInPath().path == clone.resolvingSymlinksInPath().path)
}

@Test func differentCloneOriginIsRefusedNamingBothRepos() async throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    let clone = try fixture.makeClone(origin: "https://github.com/another/actual.git")
    do {
        try await RepoOrigin.verify(clone: clone, matches: "example-org/app")
        Issue.record("A clone of another repository must be refused")
    } catch {
        #expect(error.localizedDescription.contains("example-org/app"))
        #expect(error.localizedDescription.contains("another/actual"))
    }
}

@Test func nonGitFolderIsRefused() async throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    do {
        try await RepoOrigin.verify(clone: fixture.root, matches: "o/r")
        Issue.record("A non-git folder must be refused")
    } catch {}
}

@Test func cloneWithoutOriginIsRefused() async throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    let clone = try fixture.makeClone(origin: nil)
    do {
        try await RepoOrigin.verify(clone: clone, matches: "o/r")
        Issue.record("A repository without origin must be refused")
    } catch {}
}

@Test(.timeLimit(.minutes(1))) func processRunnerDrainsOutputLargerThanPipeCapacity() async throws {
    let output = try await ProcessRunner().run(
        "/bin/sh", ["-c", "head -c 300000 /dev/zero"], timeout: .seconds(10))
    #expect(output.status == 0)
    #expect(output.stdout == Data(repeating: 0, count: 300_000))
    #expect(output.stderr.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func processRunnerTimesOutBeforeTheChildFinishes() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    do {
        _ = try await ProcessRunner().run("/bin/sleep", ["5"], timeout: .milliseconds(500))
        Issue.record("A process exceeding its deadline must throw timedOut")
    } catch ProcessRunner.Failure.timedOut {
        #expect(start.duration(to: clock.now) < .seconds(3))
    }
}

@Test func processRunnerReturnsNonzeroStatusAndStderr() async throws {
    let output = try await ProcessRunner().run(
        "/bin/sh", ["-c", "echo err >&2; exit 3"], timeout: .seconds(5))
    #expect(output.status == 3)
    #expect(output.stdout.isEmpty)
    #expect(output.stderr == "err\n")
}

@Test(.timeLimit(.minutes(1))) func processRunnerTimesOutWhenChildIgnoresSIGTERM() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    defer { #expect(start.duration(to: clock.now) < .seconds(5)) }
    do {
        _ = try await ProcessRunner().run(
            "/bin/sh", ["-c", "trap \"\" TERM; sleep 30"], timeout: .milliseconds(500))
        Issue.record("A child ignoring SIGTERM must throw timedOut")
    } catch ProcessRunner.Failure.timedOut {}
}

@Test(.timeLimit(.minutes(1))) func processRunnerTimesOutWhenGrandchildKeepsStdoutOpen() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    defer { #expect(start.duration(to: clock.now) < .seconds(5)) }
    do {
        _ = try await ProcessRunner().run(
            "/bin/sh", ["-c", "sleep 30 & exit 0"], timeout: .milliseconds(500))
        Issue.record("An exited child with stdout held open must throw timedOut")
    } catch ProcessRunner.Failure.timedOut {}
}

@Test(.timeLimit(.minutes(1))) func processRunnerDeadlineWinsOverSuccessfulSIGTERMExit() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    defer { #expect(start.duration(to: clock.now) < .seconds(5)) }
    do {
        _ = try await ProcessRunner().run(
            "/bin/sh", ["-c", "trap \"exit 0\" TERM; sleep 30 & wait"], timeout: .milliseconds(500))
        Issue.record("A process past its deadline must throw timedOut even when SIGTERM exits zero")
    } catch ProcessRunner.Failure.timedOut {}
}

@Test(.timeLimit(.minutes(1))) func processRunnerCancellationFinishesPromptlyWithAnError() async throws {
    let task = Task {
        do {
            _ = try await ProcessRunner().run("/bin/sleep", ["30"], timeout: .seconds(60))
            return false
        } catch {
            return true
        }
    }
    defer { task.cancel() }
    try await Task.sleep(for: .milliseconds(300))
    let clock = ContinuousClock()
    let cancellationStart = clock.now
    task.cancel()
    let threw = await task.value
    #expect(cancellationStart.duration(to: clock.now) < .seconds(5))
    #expect(threw, "Cancelling ProcessRunner must throw instead of returning normally")
}

@Test func processRunnerUsesArgvAndTheRequestedDirectory() async throws {
    let fixture = try ConfigCheckoutFixture()
    defer { fixture.remove() }
    let literal = "$(echo expanded); * ' quoted"
    let output = try await ProcessRunner().run(
        "/usr/bin/printf", ["%s", literal], in: fixture.root, timeout: .seconds(5))
    #expect(output.status == 0)
    #expect(String(decoding: output.stdout, as: UTF8.self) == literal)
    let cwd = try await ProcessRunner().run("/bin/pwd", [], in: fixture.root, timeout: .seconds(5))
    #expect(cwd.status == 0)
    let actualPath = String(decoding: cwd.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    #expect(URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().path
            == fixture.root.resolvingSymlinksInPath().path)
}
