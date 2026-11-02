@testable import BtonCore
import Testing
import Foundation

struct AgentReadDenyAcceptanceTests {
    private let folders = [
        "~/Desktop", "~/Documents", "~/Downloads", "~/Pictures",
        "~/Music", "~/Movies", "~/Library/CloudStorage",
    ]

    @Test func personalFoldersMatchContract() {
        #expect(AgentHardening.personalFolders == folders)
    }

    @Test(arguments: ["absent", "relative", "invalid", "disabled"])
    func personalFoldersAreDeniedForEverySettingsScenario(scenario: String) throws {
        let input: String?
        switch scenario {
        case "relative": input = ".claude/settings.json"
        case "invalid": input = "{invalid JSON"
        case "disabled": input = #"{"model":"synthetic","sandbox":{"enabled":false,"failIfUnavailable":false,"allowUnsandboxedCommands":true}}"#
        default: input = nil
        }
        let settings = try parse(AgentHardening.lockedSandbox(input))
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
        let denyRead = try #require(filesystem["denyRead"] as? [String])
        let permissions = try #require(settings["permissions"] as? [String: Any])
        let deny = try #require(permissions["deny"] as? [String])
        for folder in folders {
            #expect(denyRead.contains(folder))
            #expect(deny.contains("Read(\(folder)/**)"))
        }
        #expect(sandbox["enabled"] as? Bool == true)
        #expect(sandbox["failIfUnavailable"] as? Bool == true)
        #expect(sandbox["allowUnsandboxedCommands"] as? Bool == false)
    }

    @Test func userRulesSurviveWithoutDuplicatePersonalRules() throws {
        let input = #"{"sandbox":{"filesystem":{"denyRead":["~/Secrets","~/Pictures"],"allowWrite":["/tmp/x"]}},"permissions":{"deny":["Bash(rm:*)","Read(~/Music/**)"],"allow":["Bash(ls:*)"]}}"#
        let settings = try parse(AgentHardening.lockedSandbox(input))
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
        let denyRead = try #require(filesystem["denyRead"] as? [String])
        let permissions = try #require(settings["permissions"] as? [String: Any])
        let deny = try #require(permissions["deny"] as? [String])
        for folder in ["~/Secrets"] + folders {
            #expect(denyRead.filter { $0 == folder }.count == 1)
        }
        for rule in ["Bash(rm:*)"] + folders.map({ "Read(\($0)/**)" }) {
            #expect(deny.filter { $0 == rule }.count == 1)
        }
        #expect(filesystem["allowWrite"] as? [String] == ["/tmp/x"])
        #expect(permissions["allow"] as? [String] == ["Bash(ls:*)"])
    }

    @Test func allowedToolCoexistsWithPersonalFolderDenials() throws {
        let settings = try parse(AgentHardening.lockedSandbox(nil, allowing: ["mcp__x"]))
        let permissions = try #require(settings["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        let deny = try #require(permissions["deny"] as? [String])
        #expect(allow.contains("mcp__x"))
        for folder in folders {
            #expect(deny.contains("Read(\(folder)/**)"))
        }
    }

    @Test(arguments: ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library/CloudStorage"])
    func jobWorktreeExemptsOnlyItsContainingPersonalFolder(folder: String) throws {
        for suffix in ["", "/repo/.worktrees/bton-pr-7"] {
            let working = NSHomeDirectory() + "/" + folder + suffix
            let settings = try parse(AgentHardening.lockedSandbox(nil, working: working))
            try expectPersonalDenials(settings, except: "~/" + folder)
        }
    }

    @Test(arguments: ["Documents2/repo", "Desktop2/repo", "Library/CloudStorage2/repo", ".bton/jobs/pr-7"])
    func worktreeOutsidePersonalFoldersKeepsEveryDenial(path: String) throws {
        let settings = try parse(AgentHardening.lockedSandbox(nil, working: NSHomeDirectory() + "/" + path))
        try expectPersonalDenials(settings)
    }

    @Test func nilWorktreeKeepsEveryPersonalFolderDenied() throws {
        let settings = try parse(AgentHardening.lockedSandbox(nil, working: nil))
        try expectPersonalDenials(settings)
    }

    @Test(arguments: [false, true])
    func hardeningAndDispatchPassThroughJobWorktree(dispatch: Bool) throws {
        let working = NSHomeDirectory() + "/Documents/repo/.worktrees/bton-pr-7"
        let template = ["claude", "-p", "{prompt}"]
        let argv = dispatch
            ? DispatchPlanner.argv(template, prompt: "Synthetic task", session: UUID(), worktree: working)
            : AgentHardening.hardened(template, worktree: working)
        let index = try #require(argv.firstIndex(of: "--settings"))
        let output = try #require(argv.dropFirst(index + 1).first)
        try expectPersonalDenials(parse(output), except: "~/Documents")
    }

    @Test(arguments: ["absent", "invalid", "relative", "missing", "disabled", "enabled"])
    func filesystemIsolationIsAlwaysEnabled(scenario: String) throws {
        let input: String?
        switch scenario {
        case "invalid": input = "{invalid JSON"
        case "relative": input = ".claude/settings.json"
        case "missing": input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        case "disabled": input = #"{"sandbox":{"filesystem":{"disabled":true,"allowWrite":["/tmp/x"]}}}"#
        case "enabled": input = #"{"sandbox":{"filesystem":{"disabled":false,"allowWrite":["/tmp/x"]}}}"#
        default: input = nil
        }
        let settings = try parse(AgentHardening.lockedSandbox(input))
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
        #expect(filesystem["disabled"] as? Bool == false)
        if scenario == "disabled" || scenario == "enabled" {
            #expect(filesystem["allowWrite"] as? [String] == ["/tmp/x"])
        }
        try expectPersonalDenials(settings)
    }

    private func expectPersonalDenials(_ settings: [String: Any], except exempt: String? = nil) throws {
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
        let denyRead = try #require(filesystem["denyRead"] as? [String])
        let permissions = try #require(settings["permissions"] as? [String: Any])
        let deny = try #require(permissions["deny"] as? [String])
        for folder in folders {
            #expect(denyRead.contains(folder) == (folder != exempt))
            #expect(deny.contains("Read(\(folder)/**)") == (folder != exempt))
        }
    }

    private func parse(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
