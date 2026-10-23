@testable import BtonCore
import Testing

struct StartButtonAcceptanceTests {
    // Expected results come from the start-button contract, including a failed
    // head that has no recorded run yet.
    @Test(arguments: [
        (false, false, false, true),
        (false, false, true, true),
        (false, true, false, false),
        (false, true, true, true),
        (true, false, false, false),
        (true, false, true, true),
        (true, true, false, false),
        (true, true, true, true),
    ])
    func currentReviewOffersStartAccordingToTruthTable(
        startsMoves: Bool, ranOnHead: Bool, failedOnHead: Bool, expected: Bool
    ) {
        #expect(DispatchPlanner.offersStart(
            "review", current: "review", startsMoves: startsMoves,
            ranOnHead: ranOnHead, failedOnHead: failedOnHead
        ) == expected)
    }

    @Test func mergeIsAlwaysOfferedForEveryFlagCombination() {
        for current in ["review", "merge", "resolve"] {
            for startsMoves in [false, true] {
                for ranOnHead in [false, true] {
                    for failedOnHead in [false, true] {
                        #expect(DispatchPlanner.offersStart(
                            "merge", current: current, startsMoves: startsMoves,
                            ranOnHead: ranOnHead, failedOnHead: failedOnHead
                        ))
                    }
                }
            }
        }
    }

    @Test func resolveIsAlwaysOfferedForEveryFlagCombination() {
        for current in ["review", "merge", "resolve"] {
            for startsMoves in [false, true] {
                for ranOnHead in [false, true] {
                    for failedOnHead in [false, true] {
                        #expect(DispatchPlanner.offersStart(
                            "resolve", current: current, startsMoves: startsMoves,
                            ranOnHead: ranOnHead, failedOnHead: failedOnHead
                        ))
                    }
                }
            }
        }
    }

    @Test(arguments: ["review", "fix", "decide"])
    func nonCurrentFlowMoveIsNeverOffered(move: String) {
        for current in ["different-flow-move", "merge", "resolve"] {
            for startsMoves in [false, true] {
                for ranOnHead in [false, true] {
                    for failedOnHead in [false, true] {
                        #expect(!DispatchPlanner.offersStart(
                            move, current: current, startsMoves: startsMoves,
                            ranOnHead: ranOnHead, failedOnHead: failedOnHead
                        ))
                    }
                }
            }
        }
    }
}
