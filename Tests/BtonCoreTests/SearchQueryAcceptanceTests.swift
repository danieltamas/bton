@testable import BtonCore
import Testing

@Suite(ProcessBound())
struct SearchQueryAcceptanceTests {
    @Test func trimsWhitespaceAndNewlinesAndReportsEmpty() {
        #expect(SearchQuery(" \n\t CAL \r\n").text == "CAL")
        for raw in ["", " ", "\t\n\r "] {
            let query = SearchQuery(raw)
            #expect(query.text == "")
            #expect(query.isEmpty)
            #expect(query.matches(numbers: [], texts: []))
            #expect(query.matches(numbers: [367], texts: ["anything"]))
        }
        #expect(!SearchQuery(" # ").isEmpty)
        #expect(SearchQuery("36 fix").text == "36 fix")
    }

    @Test func digitsMatchOnlyDecimalNumberPrefixes() {
        for raw in ["36", "#36", " \n#36\t"] {
            let query = SearchQuery(raw)
            #expect(query.matches(numbers: [360], texts: []))
            #expect(query.matches(numbers: [36], texts: []))
            #expect(query.matches(numbers: [1, 369], texts: []))
            #expect(!query.matches(numbers: [136, 3, 6], texts: ["Fix 36"]))
            #expect(!query.matches(numbers: [], texts: ["36"]))
        }
        #expect(SearchQuery("367").matches(numbers: [3670], texts: []))
        #expect(!SearchQuery("367").matches(numbers: [], texts: ["Fix 367"]))
        #expect(!SearchQuery("#367").matches(numbers: [], texts: ["Fix #367"]))
        #expect(!SearchQuery("036").matches(numbers: [36], texts: []))
        #expect(SearchQuery("0").matches(numbers: [0], texts: []))
    }

    @Test func otherQueriesMatchTextCaseInsensitivelyAndIgnoreNumbers() {
        let cases: [(String, String)] = [
            ("CAL", "Outlook calendar"), ("fix", "Prefix FIXTURE suffix"),
            ("#", "PR #367"), ("#36a", "Fix #36A now"),
            ("36 fix", "Issue 36 FIX today"), ("-1", "Value -1 here")
        ]
        for (raw, text) in cases {
            let query = SearchQuery(raw)
            #expect(query.matches(numbers: [], texts: ["unrelated", text]))
            #expect(!query.matches(numbers: [36, 367, -1], texts: ["unrelated"]))
            #expect(!query.matches(numbers: [36, 367, -1], texts: []))
        }
    }
}
