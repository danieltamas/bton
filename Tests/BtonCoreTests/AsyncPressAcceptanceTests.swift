@testable import BtonCore
import Foundation
import Testing

struct AsyncPressAcceptanceTests {
    @MainActor
    @Test func performHoldsIDUntilActionReturnsOrThrows() async {
        let actions = InFlightActions()
        let id = "refresh"
        #expect(!actions.isRunning(id))
        let performed = await actions.perform(id) {
            #expect(actions.isRunning(id))
            #expect(actions.ids.contains(id))
        }
        #expect(performed)
        #expect(!actions.isRunning(id))
        #expect(actions.ids.isEmpty)

        enum Failure: Error { case expected }
        #expect(!actions.isRunning(id))
        var caughtExpectedError = false
        do {
            try await actions.perform(id) {
                #expect(actions.isRunning(id))
                #expect(actions.ids.contains(id))
                throw Failure.expected
            }
        } catch Failure.expected {
            caughtExpectedError = true
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(caughtExpectedError)
        #expect(!actions.isRunning(id))
        #expect(actions.ids.isEmpty)
    }

    @MainActor
    @Test func performRejectsDuplicateAllowsDifferentIDAndCanRunAgain() async {
        let actions = InFlightActions()
        let id = "stop:first"
        var continuation: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await actions.perform(id) {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while !actions.isRunning(id) { await Task.yield() }

        var duplicateRan = false
        let duplicate = await actions.perform(id) { duplicateRan = true }
        #expect(!duplicate)
        #expect(!duplicateRan)
        #expect(actions.isRunning(id))

        let otherID = "stop:second"
        var differentRan = false
        let different = await actions.perform(otherID) {
            differentRan = true
            #expect(actions.isRunning(id))
            #expect(actions.isRunning(otherID))
        }
        #expect(different)
        #expect(differentRan)
        #expect(!actions.isRunning(otherID))
        #expect(actions.isRunning(id))

        continuation?.resume()
        #expect(await first.value)
        #expect(!actions.isRunning(id))
        var ranAgain = false
        let repeated = await actions.perform(id) {
            ranAgain = true
            #expect(actions.isRunning(id))
        }
        #expect(repeated)
        #expect(ranAgain)
        #expect(actions.ids.isEmpty)
    }

    @Test func buttonPressTasksOnlyAppearInAsyncPress() throws {
        let task = try NSRegularExpression(pattern: #"\bTask\s*[{(]"#)
        let buttons = ["Button(", "PillButton(", "IconButton(", "RunNowButton(",
                       "StartMoveButton(", "floatingAction("]
        var hits: [String] = []
        for file in try sourceFiles() where file.lastPathComponent != "AsyncPress.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                guard task.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                let nearby = lines[max(0, index - 4)...index]
                if nearby.contains(where: { line in buttons.contains(where: { line.contains($0) }) }) {
                    hits.append("Sources/Bton/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(hits.isEmpty, "Button presses must use AsyncPress. Hits:\n\(hits.joined(separator: "\n"))")
    }

    @Test func inFlightPerformAppearsExactlyOnceAndOnlyInAsyncPress() throws {
        let files = try sourceFiles()
        let asyncPress = try #require(files.first { $0.lastPathComponent == "AsyncPress.swift" },
                                     "Sources/Bton/AsyncPress.swift must exist")
        let needle = "inFlight.perform("
        let content = try String(contentsOf: asyncPress, encoding: .utf8)
        #expect(content.components(separatedBy: needle).count - 1 == 1,
                "AsyncPress.swift must contain inFlight.perform( exactly once")
        var hits: [String] = []
        for file in files where file != asyncPress {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains(needle) {
                hits.append("Sources/Bton/\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(hits.isEmpty, "Only AsyncPress.swift may call inFlight.perform(. Hits:\n\(hits.joined(separator: "\n"))")
    }

    private func sourceFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Bton")
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
