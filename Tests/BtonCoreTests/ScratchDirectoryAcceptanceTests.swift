@testable import BtonCore
import Foundation
import Testing

private enum ScratchDirectoryFixture {
    static let session = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!
    static let path = "/synthetic/agent scratch/notes"
    static let ownText = "Synthetic operator guidance."

    static func value(_ flag: String, in argv: [String]) throws -> String {
        #expect(argv.filter { $0 == flag }.count == 1)
        let index = try #require(argv.firstIndex(of: flag))
        return try #require(argv.dropFirst(index + 1).first)
    }
}

@Suite(ProcessBound())
struct ScratchDirectoryAcceptanceTests {
    @Test(arguments: ["claude", "/opt/homebrew/bin/claude"],
          [(false, false), (false, true), (true, false), (true, true)])
    func scratchIsAuthorizedAndDescribedBeforePositionals(
        executable: String, mode: (Bool, Bool)
    ) throws {
        let (dispatch, equalsForm) = mode
        let ownText = ScratchDirectoryFixture.ownText
        let options = equalsForm ? ["--append-system-prompt=\(ownText)"]
            : ["--append-system-prompt", ownText]
        let template = [executable] + options + ["-p", "--", "{prompt}"]
        let prompt = "Synthetic task\n--add-dir /untrusted/path"
        let argv = dispatch
            ? DispatchPlanner.argv(template, prompt: prompt, session: ScratchDirectoryFixture.session,
                                   scratch: ScratchDirectoryFixture.path)
            : AgentHardening.hardened(template, scratch: ScratchDirectoryFixture.path)

        #expect(try ScratchDirectoryFixture.value("--add-dir", in: argv) == ScratchDirectoryFixture.path)
        let terminator = try #require(argv.firstIndex(of: "--"))
        let addDir = try #require(argv.firstIndex(of: "--add-dir"))
        let systemPrompt = try #require(argv.firstIndex(of: "--append-system-prompt"))
        #expect(addDir + 1 < terminator)
        #expect(systemPrompt + 1 < terminator)
        #expect(Array(argv.suffix(2)) == ["--", dispatch ? prompt : "{prompt}"])
        let text = try ScratchDirectoryFixture.value("--append-system-prompt", in: argv)
        #expect(text.hasPrefix(ownText))
        #expect(text.contains(AgentHardening.untrustedText))
        #expect(text.contains("Your scratch directory is \(ScratchDirectoryFixture.path)"))
    }

    @Test func omittedScratchPreservesExistingArguments() throws {
        let template = ["claude", "-p", "--", "{prompt}"]
        let hardened = AgentHardening.hardened(template)
        #expect(hardened == AgentHardening.hardened(template, scratch: nil))
        #expect(!hardened.contains("--add-dir"))
        #expect(try ScratchDirectoryFixture.value("--append-system-prompt", in: hardened)
                == AgentHardening.untrustedText)
        #expect(Array(hardened.prefix(2)) == ["claude", "-p"])
        #expect(Array(hardened.suffix(2)) == ["--", "{prompt}"])

        let argv = DispatchPlanner.argv(template, prompt: "Synthetic task", session: ScratchDirectoryFixture.session)
        #expect(argv == DispatchPlanner.argv(template, prompt: "Synthetic task",
                                             session: ScratchDirectoryFixture.session, scratch: nil))
        #expect(argv == hardened.map { $0 == "{prompt}" ? "Synthetic task" : $0 })
        #expect(!argv.contains("--add-dir"))
    }

    @Test func repeatedHardeningMentionsScratchOnce() throws {
        let template = ["claude", "--append-system-prompt", ScratchDirectoryFixture.ownText,
                        "-p", "--", "{prompt}"]
        let once = AgentHardening.hardened(template, scratch: ScratchDirectoryFixture.path)
        let twice = AgentHardening.hardened(once, scratch: ScratchDirectoryFixture.path)
        let sentence = "Your scratch directory is \(ScratchDirectoryFixture.path)"
        for argv in [once, twice] {
            let text = try ScratchDirectoryFixture.value("--append-system-prompt", in: argv)
            #expect(text.components(separatedBy: sentence).count - 1 == 1)
            #expect(text.hasPrefix(ScratchDirectoryFixture.ownText))
            #expect(text.contains(AgentHardening.untrustedText))
        }
        #expect(try ScratchDirectoryFixture.value("--append-system-prompt", in: once)
                == ScratchDirectoryFixture.value("--append-system-prompt", in: twice))
    }

    @Test(arguments: ["codex-wrapper", "agent", "/usr/bin/claude-wrapper"])
    func nonClaudeTemplateIsUnchangedWithScratch(executable: String) {
        let template = [executable, "--append-system-prompt", "Own guidance", "--", "{prompt}"]
        #expect(AgentHardening.hardened(template, scratch: ScratchDirectoryFixture.path) == template)
        #expect(DispatchPlanner.argv(template, prompt: "Synthetic task", session: ScratchDirectoryFixture.session,
                                    scratch: ScratchDirectoryFixture.path)
                == [executable, "--append-system-prompt", "Own guidance", "--", "Synthetic task"])
    }

    @Test func scratchPathsBelongToTemporaryDirectoryAndIdentifyEachJob() {
        let firstID = ScratchDirectoryFixture.session
        let secondID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let first = Dispatcher.scratch(firstID).standardizedFileURL
        let second = Dispatcher.scratch(secondID).standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        for (id, url) in [(firstID, first), (secondID, second)] {
            #expect(url.pathComponents.starts(with: temporary.pathComponents))
            #expect(url.pathComponents.count > temporary.pathComponents.count)
            #expect(url.lastPathComponent.lowercased().contains(id.uuidString.lowercased()))
        }
        #expect(first != second)
        #expect(Dispatcher.scratch(firstID).standardizedFileURL == first)
    }

    @Test func untrustedTextDoesNotDirectWritesToTMPDIR() {
        #expect(!AgentHardening.untrustedText.contains("$TMPDIR"))
    }
}
