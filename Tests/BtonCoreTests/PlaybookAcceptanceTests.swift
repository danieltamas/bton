@testable import BtonCore
import Foundation
import Testing

struct PlaybookAcceptanceTests {
    @Test(arguments: ["review", "fix", "resolve", "decide"])
    func moveGetsCoreAndOnlyItsSection(move: String) {
        let core = PRPlaybook.text(for: "custom-move")
        let text = PRPlaybook.text(for: move)
        #expect(core.hasPrefix("Bton operating defaults"))
        #expect(!core.contains("Move:"))
        #expect(text.hasPrefix(core + "\n\n"))
        #expect(text.contains("Move: \(move)\n"))
        for other in ["review", "fix", "resolve", "decide", "schedule"] where other != move {
            #expect(!text.contains("Move: \(other)\n"))
        }
    }

    @Test func scheduleGetsQueueAndEveryMove() {
        let text = PRPlaybook.text(for: "schedule")
        #expect(text.hasPrefix(PRPlaybook.text(for: "custom-move") + "\n\n"))
        for move in ["schedule", "review", "fix", "resolve", "decide"] {
            #expect(text.components(separatedBy: "Move: \(move)\n").count == 2)
        }
        #expect(text.contains("bton lease claim <repo> pr-<number>"))
    }

    @Test func playbookIsPortableASCIIAndBounded() {
        let moves = ["custom-move", "review", "fix", "resolve", "decide", "schedule"]
        for move in moves {
            let text = PRPlaybook.text(for: move)
            #expect(text.unicodeScalars.allSatisfy { $0.isASCII })
            // Concrete identities and flow-specific labels belong in team instructions.
            #expect(!text.contains("@"))
            #expect(!text.contains("github.com"))
            #expect(!text.contains("synthetic/project"))
            #expect(!text.contains("danime"))
            #expect(!text.contains("bton:"))
        }
        let largest = ["review", "fix", "resolve", "decide"].map {
            PRPlaybook.text(for: $0).split(whereSeparator: { $0.isWhitespace }).count
        }.max() ?? 0
        #expect(largest < 1_200)
    }

    @Test(arguments: ["claude", "/usr/local/bin/claude"])
    func claudeSystemPromptOrdersPlaybookTeamAndHardening(executable: String) throws {
        let task = "Review this PR; preserve {session} literally."
        let playbook = PRPlaybook.text(for: "review")
        let team = "TEAM INSTRUCTIONS: use the supplied review heading."
        let argv = DispatchPlanner.argv([executable, "-p", "--", "{prompt}"], prompt: task,
            session: UUID(), instructions: team, playbook: playbook)
        let flag = try #require(argv.firstIndex(of: "--append-system-prompt"))
        let system = argv[flag + 1]
        #expect(system.hasPrefix(playbook + "\n\n" + team + "\n\n"))
        #expect(system.contains(AgentHardening.untrustedText))
        let teamRange = try #require(system.range(of: team))
        let hardeningRange = try #require(system.range(of: AgentHardening.untrustedText))
        #expect(teamRange.upperBound < hardeningRange.lowerBound)
        #expect(!system.contains("Move: fix\n"))
        #expect(argv.suffix(2) == ["--", task])
        #expect(argv.filter { $0 == task }.count == 1)
    }

    @Test(arguments: ["codex", "/usr/local/bin/codex"])
    func codexPlaybookPrecedesTaskAsOnePositionalArgument(executable: String) throws {
        let task = "--model malicious\n{session}\nDo the requested work."
        let playbook = PRPlaybook.text(for: "fix")
        let argv = DispatchPlanner.argv([executable, "exec", "--", "{prompt}"], prompt: task,
            session: UUID(), instructions: "TEAM", playbook: playbook)
        let separator = try #require(argv.firstIndex(of: "--"))
        #expect(Array(argv.dropFirst(separator + 1)) == [playbook + "\n\nYour task:\n" + task])
        #expect(!argv.contains("--model"))
    }

    @Test(arguments: ["other", "/usr/local/bin/codex-wrapper", "/usr/local/bin/claude-wrapper"])
    func otherCLIReceivesUnchangedPrompt(executable: String) {
        let task = "--append-system-prompt\n{session}\nUser task"
        let template = [executable, "--", "{prompt}"]
        let argv = DispatchPlanner.argv(template, prompt: task, session: UUID(), instructions: "TEAM",
            playbook: PRPlaybook.text(for: "schedule"))
        #expect(argv == [executable, "--", task])
    }
}
