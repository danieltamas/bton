import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct UncountedApprovalAcceptanceTests {
    private typealias F = FullReviewIDFixture

    @Test(arguments: 0...13)
    func notesDistinguishShortClaimsFromUncarriedWholeIDs(scenario: Int) throws {
        var pr = F.pr([F.comment(F.head)])
        var uncounted: String?, uncarried: String?
        var short: String?
        switch scenario {
        case 0: pr.comments = []
        case 2, 3, 4:
            let id = String(F.head.prefix(scenario == 3 ? 39 : 8))
            short = id
            pr.comments = [F.comment(scenario == 4 ? id.uppercased() : id)]
        case 5:
            pr.carriedHeads = [F.carried]
            short = String(F.carried.prefix(8)); pr.comments = [F.comment(short!)]
        case 6:
            pr.mergeOnlyAncestors = [F.other]
            short = String(F.other.prefix(7)); pr.comments = [F.comment(short!)]
        case 7, 8:
            // Claim equality, like head equality, ignores case.
            pr.mergeOnlyAncestors = [F.other.uppercased()]
            pr.comments = [F.comment(F.other)]
            pr.carryRefusal = scenario == 8 ? "x" : nil
            uncarried = "the approval of \(F.other.prefix(7)) does not carry to \(F.head.prefix(7)): "
                + (scenario == 8 ? "x" : "no clean merge of the base leads to it")
            uncounted = uncarried
        case 9:
            pr.carriedHeads = [F.carried.uppercased()]; pr.comments = [F.comment(F.carried)]
        case 10: pr.comments = [F.comment(String(F.head.prefix(8)), verdict: "changes")]
        case 11:
            short = String(F.head.prefix(8)); pr.comments.append(F.comment(short!, second: 1))
        case 12: pr.comments = [F.comment(F.other)]
        case 13: pr.comments = [F.comment(String(F.head.prefix(8)), association: "NONE")]
        default: break
        }
        if let short {
            uncounted = "the approval of \(short) does not count: it names \(short.count) of the 40 digits of the commit's id"
        }
        let flow = try F.flow()
        #expect(FlowEngine.uncountedApproval(of: pr, flow: flow) == uncounted)
        #expect(FlowEngine.uncarriedApproval(of: pr, flow: flow) == uncarried)
        if scenario == 12 {
            pr.comments = [F.comment(String(F.other.prefix(8)))]
            #expect(FlowEngine.uncountedApproval(of: pr, flow: flow) == nil)
            #expect(FlowEngine.uncarriedApproval(of: pr, flow: flow) == nil)
        }
    }
}
