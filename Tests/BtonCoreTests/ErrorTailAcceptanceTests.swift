import BtonCore
import Testing

struct ErrorTailAcceptanceTests {
    @Test func shortTextIsUnchanged() {
        let text = "command output\n\nfinished"
        #expect(SessionTranscript.preview(text) == text)
    }

    @Test func emptyTextIsUnchanged() {
        #expect(SessionTranscript.preview("") == "")
    }

    @Test(arguments: [5, 12])
    func exactlyTheLineLimitIsUnchanged(lines: Int) {
        let text = (1...lines).map { "line \($0)" }.joined(separator: "\n")
        #expect(SessionTranscript.preview(text, lines: lines) == text)
    }

    @Test func defaultPreviewKeepsTheFirstThreeAndLastEightLines() {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let preview = SessionTranscript.preview(text)
        #expect(preview == "line 1\nline 2\nline 3\n...\nline 13\nline 14\nline 15\nline 16\nline 17\nline 18\nline 19\nline 20")
        #expect(preview.split(separator: "\n", omittingEmptySubsequences: false).count == 12)
    }

    @Test(arguments: [5, 2, 0, -1])
    func minimumPreviewKeepsTheFirstThreeAndLastLine(lines: Int) {
        let text = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7"
        let preview = SessionTranscript.preview(text, lines: lines)
        #expect(preview == "line 1\nline 2\nline 3\n...\nline 7")
        #expect(preview.split(separator: "\n", omittingEmptySubsequences: false).count == 5)
    }

    @Test(arguments: ["\n", "\n\n\n"])
    func trailingNewlinesAreTrimmedBeforeCountingAndSelectingLines(suffix: String) {
        let fiveLines = "line 1\nline 2\nline 3\nline 4\nline 5"
        #expect(SessionTranscript.preview(fiveLines + suffix, lines: 5) == fiveLines)
        #expect(SessionTranscript.preview(fiveLines + "\nline 6" + suffix, lines: 5)
                == "line 1\nline 2\nline 3\n...\nline 6")
        #expect(SessionTranscript.preview("short" + suffix) == "short")
        #expect(SessionTranscript.preview(suffix) == "")
    }

    @Test func fiveLineShellFailureKeepsItsFinalError() {
        let error = "error: fetching ref refs/remotes/origin/develop failed: incorrect old value provided"
        let text = "git fetch origin\nremote: Enumerating objects: 5, done.\nremote: Counting objects: 100% (5/5), done.\nFrom github.com:example/repository\n" + error
        #expect(SessionTranscript.preview(text) == text)
        let preview = SessionTranscript.preview(text, lines: 5)
        #expect(preview == text)
        #expect(preview.split(separator: "\n").last == Substring(error))
    }
}
