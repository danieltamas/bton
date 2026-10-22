import Testing
@testable import BtonCore

struct IssueAskRoundTwoRegressionTests {
    @Test func unmatchedBacktickRunsDoNotHideMention() {
        // Neither run has an equal-length partner, so both are literal text.
        #expect(IssueAsks.mentions("Please check `` this @owner `", login: "owner"))
    }

    @Test func escapedOpeningBacktickDoesNotHideMention() {
        #expect(IssueAsks.mentions(#"Please check \` this @owner `"#, login: "owner"))
    }

    @Test func backslashInsideSpanDoesNotEscapeClosingBacktick() {
        #expect(IssueAsks.mentions(#"`a\` @owner"#, login: "owner"))
        #expect(!IssueAsks.mentions(#"`a\` @someone"#, login: "owner"))
    }

    @Test func spansCannotCrossBlankLines() {
        for newline in ["\n", "\r\n"] {
            for blank in ["", " ", "\t", " \t "] {
                let text = "`start\(newline)\(blank)\(newline)@owner end`"
                #expect(IssueAsks.mentions(text, login: "owner"))
            }
        }
    }

    @Test func spansCanCrossSoftLineBreaks() {
        for newline in ["\n", "\r\n"] {
            #expect(!IssueAsks.mentions("`start\(newline)@owner end`", login: "owner"))
        }
    }

    @Test func escapedBackslashesStillAllowRealCodeSpans() {
        // An even number of backslashes leaves the following backtick unescaped.
        #expect(!IssueAsks.mentions(#"\\` @owner `"#, login: "owner"))
        #expect(IssueAsks.mentions(#"\\\` @owner `"#, login: "owner"))
    }

    @Test func onlyEqualLengthRunsCloseSpans() {
        #expect(!IssueAsks.mentions("`` a ` @owner ``` b ``", login: "owner"))
        #expect(IssueAsks.mentions("`` a ` hidden `` @owner", login: "owner"))
    }

    @Test func unmatchedRunDoesNotPreventLaterRealSpan() {
        #expect(!IssueAsks.mentions("`` unmatched ` @owner `", login: "owner"))
        #expect(IssueAsks.mentions("`` unmatched ` @someone ` @owner", login: "owner"))
    }
}
