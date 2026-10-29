import Foundation
import Testing
@testable import BtonCore

private func engineLogRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-log-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func expectEngineLogLine(_ line: String, message: String) throws {
    let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    try #require(parts.count == 2)
    #expect(String(parts[1]) == message)
    let timestamp = String(parts[0])
    let formatter = ISO8601DateFormatter()
    let wholeSeconds = formatter.date(from: timestamp)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(wholeSeconds != nil || formatter.date(from: timestamp) != nil)
    #expect(timestamp.hasSuffix("Z") || timestamp.hasSuffix("+00:00"))
}

struct EngineLogAcceptanceTests {
    @Test func urlIsBtonLogInHome() throws {
        let root = try engineLogRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])

        #expect(EngineLog.url(home: home) == home.url.appendingPathComponent("bton.log"))
        #expect(EngineLog.cap == 1_000_000)
    }

    @Test func sinkAppendsTimestampedLinesInOrder() throws {
        let root = try engineLogRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let sink = EngineLog.sink(home: home)

        sink("first message")
        sink("second message")

        let text = try String(contentsOf: EngineLog.url(home: home), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        try #require(lines.count == 3)
        #expect(lines[2].isEmpty)
        try expectEngineLogLine(lines[0], message: "first message")
        try expectEngineLogLine(lines[1], message: "second message")
    }

    @Test func rotationPreservesOldBytesAndReplacesPreviousBackup() throws {
        let root = try engineLogRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let url = EngineLog.url(home: home)
        let backup = home.url.appendingPathComponent("bton.log.1")
        let sink = EngineLog.sink(home: home)
        let original = Data(repeating: 65, count: EngineLog.cap)
        let replacement = Data(repeating: 66, count: EngineLog.cap + 17)

        for (bytes, message) in [(original, "after first rotation"), (replacement, "after second rotation")] {
            try bytes.write(to: url)
            sink(message)

            #expect(try Data(contentsOf: backup) == bytes)
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            try #require(lines.count == 2)
            #expect(lines[1].isEmpty)
            try expectEngineLogLine(lines[0], message: message)
        }
    }

    @Test func sinkCreatesMissingHomeAndFile() throws {
        let root = try engineLogRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing/nested")
        let home = BtonHome(environment: ["BTON_HOME": missing.path])
        #expect(!FileManager.default.fileExists(atPath: home.url.path))

        EngineLog.sink(home: home)("created home")

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home.url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let text = try String(contentsOf: EngineLog.url(home: home), encoding: .utf8)
        #expect(text.hasSuffix(" created home\n"))
    }

    @Test func embeddedNewlineIsWrittenAsIs() throws {
        let root = try engineLogRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let message = "first part\nsecond part"

        EngineLog.sink(home: home)(message)

        let text = try String(contentsOf: EngineLog.url(home: home), encoding: .utf8)
        #expect(text.contains(message))
        #expect(text.hasSuffix(" \(message)\n"))
    }
}
