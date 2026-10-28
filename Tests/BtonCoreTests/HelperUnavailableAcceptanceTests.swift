@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct HelperUnavailableAcceptanceTests {
    @Test func ownHelperIsSatisfiedByTheAgentsWork() {
        let note = Helpers.unavailable(agent: "codex", helpers: ["codex"])
        #expect(note.contains(Helpers.tool))
        #expect(note.contains("you are the codex agent"))
        #expect(note.contains("not a blocker"))
        #expect(note.contains("satisfied by your own work"))
    }

    @Test func anotherHelperDoesNotClaimTheAgentsOwnWork() {
        let note = Helpers.unavailable(agent: "claude", helpers: ["codex"])
        #expect(note.contains("codex"))
        #expect(!note.contains("satisfied by your own work"))
    }

    @Test(arguments: ["codex", "claude"])
    func unavailableNoteIsASCIIAndBounded(agent: String) {
        let note = Helpers.unavailable(agent: agent, helpers: ["codex"])
        #expect(note.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(note.count < 700)
    }
}
