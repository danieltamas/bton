import Testing
@testable import BtonCore

@Suite struct IssueDraftLabelsAcceptanceTests {
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
