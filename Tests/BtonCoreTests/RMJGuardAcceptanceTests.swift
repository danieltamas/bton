@testable import BtonCore
import Foundation
import Testing

/// An agent inside a Bton job runs the repo's tests where the job runs: RMJ's guard hook, which
/// would send them to the Mac owner's build box and block the agent, is told to stand down.
struct RMJGuardAcceptanceTests {
    @Test func everyAgentRunsWithTheGuardOff() {
        // RMJ reads exactly "off": "0" or "Off" leave the guard on.
        #expect(Dispatcher.agentEnvironment == ["RMJ_GUARD": "off"])
    }

    @Test func aRepoEnvironmentCannotTurnTheGuardBackOn() {
        let bton = ["BTON_JOB": "synthetic"].merging(Dispatcher.agentEnvironment) { $1 }
        let environment = DispatchPlanner.processEnvironment(repo: ["RMJ_GUARD": "on", "RX_LOCAL": "1"], bton: bton)
        #expect(environment["RMJ_GUARD"] == "off")
        #expect(environment["RX_LOCAL"] == "1", "a repo's other variables still reach the agent")
    }
}
