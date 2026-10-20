@testable import BtonCore
import Foundation
import Testing

private enum ScheduleModelFixture {
    static let repo = "synthetic/widget"
    static let model = "claude-opus-5-5"
    static let now = Date(timeIntervalSince1970: 120_030)
    static let session = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!
    static let invalidModels = [
        "", "--model", "-opus", "two models", "opus/model", "opus;model", "$(x)",
        "opus\nmodel", "opus\n", String(repeating: "a", count: 101),
        ".opus", "_opus", ":opus", "[opus]", "opus+model", "cl\u{00E1}ude",
    ]

    static func entry(model: String? = nil) -> ScheduleEntry {
        ScheduleEntry(name: "Synthetic check", everyMinutes: 10, enabled: true,
                      repo: repo, agent: "claude", prompt: "Inspect the synthetic widget.",
                      number: 7, model: model)
    }

    static func candidates(_ entry: ScheduleEntry, runNow: Set<String> = []) -> [DispatchCandidate] {
        DispatchPlanner.scheduled([entry], jobs: [], repo: repo, defaultBranch: "main",
                                  me: "octo", now: now, runNow: runNow)
    }

    static func expectPinned(_ argv: [String], model: String = ScheduleModelFixture.model) throws {
        let options = Array(argv.prefix(while: { $0 != "--" }))
        #expect(options.filter { $0 == "--model" }.count == 1)
        #expect(!options.contains { $0.hasPrefix("--model=") })
        let index = try #require(options.firstIndex(of: "--model"))
        #expect(Array(options.dropFirst(index).prefix(2)) == ["--model", model])
    }
}

struct ScheduleModelAcceptanceTests {
    @Test func scheduleWithoutModelInConfigDecodesAsNil() throws {
        let json = #"{"repos":[],"pollSeconds":45,"maxAgents":2,"agents":{},"schedules":[{"name":"Synthetic check","everyMinutes":10,"enabled":true}]}"#
        let config = try JSONDecoder().decode(BtonConfig.self, from: Data(json.utf8))
        #expect(config.schedules.count == 1)
        #expect(try #require(config.schedules.first).model == nil)
        #expect(ScheduleEntry(name: "Synthetic check", everyMinutes: 10, enabled: true).model == nil)
    }

    @Test func scheduleModelCodablePreservesValueAndNil() throws {
        for model: String? in [nil, ScheduleModelFixture.model, "claude-sonnet-5-5[1m]"] {
            let encoded = try JSONEncoder().encode(ScheduleModelFixture.entry(model: model))
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if let model {
                #expect(object["model"] as? String == model)
            } else {
                #expect(object["model"] == nil || object["model"] is NSNull)
            }
            let decoded = try JSONDecoder().decode(ScheduleEntry.self, from: encoded)
            #expect(decoded.model == model)
        }
        let explicitNull = Data(#"{"name":"Synthetic check","everyMinutes":10,"enabled":true,"model":null}"#.utf8)
        #expect(try JSONDecoder().decode(ScheduleEntry.self, from: explicitNull).model == nil)
    }

    @Test func scheduleModelIsMutable() {
        var entry = ScheduleModelFixture.entry()
        entry.model = ScheduleModelFixture.model
        #expect(entry.model == ScheduleModelFixture.model)
        entry.model = nil
        #expect(entry.model == nil)
    }

    @Test(arguments: [
        "a", "Z", "0", "claude-opus-5-5", "claude-sonnet-5-5[1m]", "gpt-5.1-codex",
        "us.anthropic.x:0", "A0._:[]-", String(repeating: "a", count: 100),
    ])
    func validModelNamesAreAccepted(model: String) {
        #expect(ScheduleEntry.isValidModel(model))
    }

    @Test(arguments: ScheduleModelFixture.invalidModels)
    func invalidModelNamesAreRejected(model: String) {
        #expect(!ScheduleEntry.isValidModel(model))
    }

    @Test(arguments: ["claude", "/opt/synthetic/bin/claude"])
    func claudeModelOverridesEveryTemplateModel(executable: String) throws {
        let argv = AgentHardening.hardened([
            executable, "--model", "old-first", "--model=old-second", "-p", "{prompt}",
            "--model", "old-third", "--session-id", "{session}",
        ], model: ScheduleModelFixture.model)
        try ScheduleModelFixture.expectPinned(argv)
        for old in ["old-first", "old-second", "old-third", "--model=old-second"] {
            #expect(!argv.contains(old))
        }
        #expect(argv.contains("{prompt}"))
        #expect(argv.contains("{session}"))
    }

    @Test func pinnedModelPrecedesTerminatorAndLeavesPositionalsUntouched() throws {
        let positional = ["{prompt}", "--model", "positional-model", "--model=literal", "{session}"]
        let argv = AgentHardening.hardened(
            ["claude", "--model=old", "-p", "--"] + positional,
            model: ScheduleModelFixture.model)
        try ScheduleModelFixture.expectPinned(argv)
        let terminator = try #require(argv.firstIndex(of: "--"))
        #expect(argv.filter { $0 == "--" }.count == 1)
        #expect(Array(argv.dropFirst(terminator + 1)) == positional)
        #expect(!argv.contains("--model=old"))
    }

    @Test(arguments: ["{prompt}", "{session}", "prefix-{prompt}", "--session={session}"])
    func modelReplacementNeverConsumesPlaceholders(placeholder: String) throws {
        let argv = AgentHardening.hardened(["claude", "--model", placeholder],
                                           model: ScheduleModelFixture.model)
        try ScheduleModelFixture.expectPinned(argv)
        #expect(argv.filter { $0 == placeholder }.count == 1)
    }

    @Test(arguments: [["--model"], ["--model", "--", "{prompt}"], ["--model", "-p", "{prompt}"]])
    func missingTemplateModelValueDoesNotConsumeFollowingArguments(options: [String]) throws {
        let argv = AgentHardening.hardened(["claude"] + options, model: ScheduleModelFixture.model)
        try ScheduleModelFixture.expectPinned(argv)
        for argument in options.dropFirst() { #expect(argv.contains(argument)) }
        if options.contains("--") { #expect(Array(argv.suffix(2)) == ["--", "{prompt}"]) }
    }

    @Test(arguments: [["--model", "template-model"], ["--model=template-model"]])
    func nilModelKeepsTemplateModelAsWritten(options: [String]) {
        let template = ["claude"] + options + ["-p", "{prompt}"]
        let argv = AgentHardening.hardened(template, model: nil)
        #expect(Array(argv.prefix(template.count)) == template)
        #expect(argv == AgentHardening.hardened(template))
    }

    @Test(arguments: ["codex", "agent", "/synthetic/bin/claude-wrapper"])
    func nonClaudeTemplateIsUnchangedWithAnyModel(executable: String) {
        let template = [executable, "--model=own", "--model", "other", "{prompt}", "--", "{session}"]
        for model: String? in [nil, ScheduleModelFixture.model, "invalid model"] {
            #expect(AgentHardening.hardened(template, model: model) == template)
        }
        #expect(AgentHardening.hardened([], model: ScheduleModelFixture.model).isEmpty)
    }

    @Test(arguments: [
        ["claude", "-p", "{prompt}"],
        ["claude", "--model=old", "--model", "older", "-p", "{prompt}"],
        ["claude", "-p", "--", "{prompt}", "--model=positional"],
    ])
    func modelHardeningIsIdempotent(template: [String]) throws {
        let once = AgentHardening.hardened(template, model: ScheduleModelFixture.model)
        try ScheduleModelFixture.expectPinned(once)
        #expect(AgentHardening.hardened(once, model: ScheduleModelFixture.model) == once)
    }

    @Test func dispatchArgvPinsModelAndKeepsPromptOneElement() throws {
        let prompt = "Synthetic task\n--model injected; $(x) 'quoted' {session}"
        let argv = DispatchPlanner.argv([
            "claude", "--model=old", "--session-id", "{session}", "-p", "--", "{prompt}",
        ], prompt: prompt, session: ScheduleModelFixture.session,
            instructions: "Synthetic team guidance.", values: [:], model: ScheduleModelFixture.model)
        try ScheduleModelFixture.expectPinned(argv)
        #expect(argv.filter { $0 == "--model" }.count == 1)
        #expect(argv.filter { Array($0.utf8) == Array(prompt.utf8) }.count == 1)
        #expect(Array(argv.suffix(2)) == ["--", prompt])
        #expect(argv.contains(ScheduleModelFixture.session.uuidString.lowercased()))
        #expect(!argv.contains("--model=old"))
    }

    @Test func scheduledCandidatePreservesOptionalModel() throws {
        for model: String? in [nil, ScheduleModelFixture.model, "claude-sonnet-5-5[1m]"] {
            let candidates = ScheduleModelFixture.candidates(ScheduleModelFixture.entry(model: model))
            #expect(candidates.count == 1)
            #expect(try #require(candidates.first).model == model)
        }
    }

    @Test(arguments: ScheduleModelFixture.invalidModels)
    func invalidScheduledModelFailsClosedEvenForRunNow(model: String) {
        let entry = ScheduleModelFixture.entry(model: model)
        #expect(ScheduleModelFixture.candidates(entry).isEmpty)
        #expect(ScheduleModelFixture.candidates(entry, runNow: ["schedule-7"]).isEmpty)
    }

    @Test func pullRequestCandidateHasNoModel() throws {
        let json = #"""
        {"version":1,"base":"main","tier":{"marker":"Tier:","values":["feature"],"default":"feature"},
         "reviews":{"feature":[{"heading":"## Review:"}]},"fixed":"## Fixed:",
         "moves":[{"move":"review","when":["no_review_or_response_newer"],"who":"author"}],
         "dispatch":{"review":{"agent":"claude","prompt":"Synthetic review.","timeoutMinutes":5}},
         "checks":{"beforeSession":[],"beforeMerge":[]},
         "caps":{"openPullRequestsPerDeveloper":2,"openPullRequestsTeam":6},
         "stale":{"pingHours":24,"escalateHours":48,"escalateTo":"octo"}}
        """#
        let flow = try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
        let pr = PullRequest(repo: ScheduleModelFixture.repo, number: 12, title: "Synthetic PR",
                             author: "octo", authorAssociation: "OWNER",
                             url: URL(string: "https://example.invalid/pull/12")!,
                             headSha: String(repeating: "a", count: 40), headRef: "synthetic", baseRef: "main",
                             body: "Tier: feature", isDraft: false, labels: [], assignees: ["octo"],
                             comments: [], updatedAt: ScheduleModelFixture.now)
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: "octo", repo: ScheduleModelFixture.repo)
        #expect(candidates.count == 1)
        #expect(try #require(candidates.first).model == nil)
    }
}
