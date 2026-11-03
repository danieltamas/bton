import Testing
@testable import BtonCore

@Suite struct IssueDraftLabelsAcceptanceTests {
    @Test func boundedLeavesExactlyOneHundredFiftyWordsAlone() {
        let reply = (1...150).map { "word\($0)" }.joined(separator: " ") + "."
        let result = IssueDrafts.bounded(reply)
        #expect(result.text == reply)
        #expect(!result.cut)
    }

    @Test(arguments: [". ", "? ", "! ", "\n", "  \n"])
    func boundedCutsTwoHundredWordsAtTheLastSentenceEndWithinTheLimit(ending: String) {
        let first = (1...60).map { "first\($0)" }.joined(separator: " ") + "."
        let second = (1...70).map { "second\($0)" }.joined(separator: " ")
        let tail = (1...70).map { "tail\($0)" }.joined(separator: " ") + "."
        let reply = first + " " + second + ending + tail
        let expected = first + " " + second + (ending.hasSuffix("\n") ? "" : String(ending.prefix(1)))
        let result = IssueDrafts.bounded(reply)
        #expect(result.cut)
        #expect(result.text == expected + " ...")
    }

    @Test func boundedCutsAtTheLastWordWhenNoSentenceFits() {
        let words = (1...200).map { "word\($0)" }
        let result = IssueDrafts.bounded(words.joined(separator: " "))
        #expect(result.cut)
        #expect(result.text == words.prefix(150).joined(separator: " ") + " ...")
    }

    @Test func boundingTheSplitReplyPreservesItsLabelChanges() {
        let reply = (1...200).map { "word\($0)" }.joined(separator: " ")
        let line = "Labels: +stage:ready -stage:spec +priority:high -priority:low"
        let split = IssueDrafts.split(reply + "\n\n" + line)
        let result = IssueDrafts.bounded(split.reply)
        #expect(result.cut)
        #expect(result.text == (1...150).map { "word\($0)" }.joined(separator: " ") + " ...")
        #expect(!result.text.contains("Labels:"))
        #expect(split.reply == reply)
        #expect(split.add == ["stage:ready", "priority:high"])
        #expect(split.remove == ["stage:spec", "priority:low"])
    }

    @Test func labelLineIsSplitFromTheReply() {
        for line in [
            "Labels: +stage:ready -stage:spec +priority:high -priority:low",
            "  lAbElS: +stage:ready,-stage:spec, +priority:high, -priority:low  "
        ] {
            let result = IssueDrafts.split("  Da, intra in sprint.\n\n\(line)\n  ")
            #expect(result.reply == "Da, intra in sprint.")
            #expect(result.add == ["stage:ready", "priority:high"])
            #expect(result.remove == ["stage:spec", "priority:low"])
        }
    }

    @Test func draftWithoutLabelLineKeepsItsTrimmedReply() {
        for reply in ["Da, intra in sprint.", "First paragraph.\n\nSecond paragraph.", ""] {
            let result = IssueDrafts.split(" \n\(reply)\n  ")
            #expect(result.reply == reply)
            #expect(result.add.isEmpty)
            #expect(result.remove.isEmpty)
        }
    }

    @Test func unreadableLabelLineKeepsTheWholeDraft() {
        for word in ["stage:ready", "+", "-", "+-option", "+bad\tname", "+" + String(repeating: "x", count: 51)] {
            let reply = "Da, intra in sprint.\n\nLabels: +bug -stage:spec \(word)"
            let result = IssueDrafts.split(" \n\(reply)\n  ")
            #expect(result.reply == reply)
            #expect(result.add.isEmpty)
            #expect(result.remove.isEmpty)
        }
    }

    @Test func emptyLabelLineKeepsTheWholeDraft() {
        let reply = "Da, intra in sprint.\n\nLabels:"
        let result = IssueDrafts.split(" \n\(reply)\n  ")
        #expect(result.reply == reply)
        #expect(result.add.isEmpty)
        #expect(result.remove.isEmpty)
    }

    @Test func labelLineBeforeMoreTextKeepsTheWholeDraft() {
        let reply = "Da, intra in sprint.\nLabels: +stage:ready -stage:spec\nMore reply text."
        let result = IssueDrafts.split(" \n\(reply)\n  ")
        #expect(result.reply == reply)
        #expect(result.add.isEmpty)
        #expect(result.remove.isEmpty)
    }

    @Test func promptRequestsLabelsWithoutToDo() {
        #expect(IssueDrafts.prompt.contains("Labels:"))
        #expect(!IssueDrafts.prompt.contains("To do"))
    }
}
