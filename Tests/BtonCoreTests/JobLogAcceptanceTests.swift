@testable import BtonCore
import Foundation
import Testing

struct JobLogAcceptanceTests {
    @Test func noteCreatesPrivateLogAndAppendsTimestampedLinesInOrder() throws {
        try JobLogFixture.withStore { store in
            let id = UUID()
            let url = store.logURL(id)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            store.note(id, "Synthetic first note")
            let first = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o600)
            store.note(id, "Synthetic second note")
            let contents = try Data(contentsOf: url)
            #expect(contents.starts(with: first))
            try JobLogFixture.expectNotes(contents, messages: ["Synthetic first note", "Synthetic second note"])
        }
    }

    @Test func notePreservesExistingAgentStderrByteForByte() throws {
        try JobLogFixture.withStore { store in
            let id = UUID()
            // No trailing newline: appending must not rewrite or normalize the agent's bytes.
            let stderr = Data([0xFF, 0x00]) + Data("Synthetic stderr\r\npartial".utf8)
            try stderr.write(to: store.logURL(id))
            store.note(id, "Synthetic first note")
            store.note(id, "Synthetic second note")
            let contents = try Data(contentsOf: store.logURL(id))
            #expect(contents.starts(with: stderr))
            try JobLogFixture.expectNotes(Data(contents.dropFirst(stderr.count)),
                messages: ["Synthetic first note", "Synthetic second note"])
        }
    }

    @Test func trimPreservesFilesAtOrBelowLimitByteForByte() throws {
        try JobLogFixture.withStore { store in
            let id = UUID()
            let limit = 8
            for size in [0, limit - 1, limit] {
                let output = Data((0..<size).map { UInt8($0) })
                let log = Data(repeating: 0xFF, count: size)
                try output.write(to: store.outputURL(id))
                try log.write(to: store.logURL(id))
                store.trim(id, limit: limit)
                #expect(try Data(contentsOf: store.outputURL(id)) == output)
                #expect(try Data(contentsOf: store.logURL(id)) == log)
            }
        }
    }

    @Test func trimRetainsExactByteTailsAndIndependentRemovalCounts() throws {
        try JobLogFixture.withStore { store in
            let id = UUID()
            let output = Data([0, 1, 2, 3, 4, 5, 6, 7, 0xFF, 0x00, 0xC3, 0xA9])
            let log = Data([9, 8, 7, 6, 5, 4, 3, 2, 1])
            try output.write(to: store.outputURL(id))
            try log.write(to: store.logURL(id))
            store.trim(id, limit: 4)
            #expect(try Data(contentsOf: store.outputURL(id))
                == Data("[8 earlier bytes trimmed]\n".utf8) + Data([0xFF, 0x00, 0xC3, 0xA9]))
            #expect(try Data(contentsOf: store.logURL(id))
                == Data("[5 earlier bytes trimmed]\n".utf8) + Data([4, 3, 2, 1]))
        }
    }

    @Test(arguments: [false, true])
    func trimHandlesEachFileIndependentlyAndLeavesMissingFilesMissing(logIsLarge: Bool) throws {
        try JobLogFixture.withStore { store in
            let id = UUID()
            let largeURL = logIsLarge ? store.logURL(id) : store.outputURL(id)
            let otherURL = logIsLarge ? store.outputURL(id) : store.logURL(id)
            let small = Data([0, 0xFF])
            try Data([1, 2, 3, 4, 5]).write(to: largeURL)
            try small.write(to: otherURL)
            store.trim(id, limit: 3)
            #expect(try Data(contentsOf: largeURL) == Data("[2 earlier bytes trimmed]\n".utf8) + Data([3, 4, 5]))
            #expect(try Data(contentsOf: otherURL) == small)
            try FileManager.default.removeItem(at: largeURL)
            store.trim(id, limit: 3)
            #expect(!FileManager.default.fileExists(atPath: largeURL.path))
            #expect(try Data(contentsOf: otherURL) == small)
            try FileManager.default.removeItem(at: otherURL)
            store.trim(id, limit: 3)
            #expect(!FileManager.default.fileExists(atPath: largeURL.path))
            #expect(!FileManager.default.fileExists(atPath: otherURL.path))
        }
    }

    @Test func trimUsesTwoMillionByteDefaultLimit() throws {
        try JobLogFixture.withStore { store in
            let id = UUID()
            let tail = Data(repeating: 0xAB, count: 2_000_000)
            try (Data([0, 1, 2]) + tail).write(to: store.outputURL(id))
            try tail.write(to: store.logURL(id))
            store.trim(id)
            #expect(try Data(contentsOf: store.outputURL(id)) == Data("[3 earlier bytes trimmed]\n".utf8) + tail)
            #expect(try Data(contentsOf: store.logURL(id)) == tail)
        }
    }

    @Test func pruneRemovesOnlyExpiredFinishedArtifactsCountsJobsAndKeepsRecords() throws {
        try JobLogFixture.withStore { store in
            #expect(JobStore.keepDays == 30)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let cutoff = now.addingTimeInterval(-30 * 86_400)
            let expired = [Job.Status.succeeded, .failed, .cancelled].map {
                JobLogFixture.job(status: $0, endedAt: cutoff.addingTimeInterval(-1))
            }
            let absent = JobLogFixture.job(status: .failed, endedAt: cutoff.addingTimeInterval(-1))
            let retained = [
                JobLogFixture.job(status: .running, endedAt: cutoff.addingTimeInterval(-1)),
                JobLogFixture.job(status: .failed, endedAt: nil),
                JobLogFixture.job(status: .succeeded, endedAt: cutoff),
                JobLogFixture.job(status: .cancelled, endedAt: cutoff.addingTimeInterval(1)),
            ]
            let jobs = expired + [absent] + retained
            for job in jobs { try store.save(job) }
            // One job has all three artifacts; others have just one, including exit-only.
            let removedURLs = JobLogFixture.artifacts(store, expired[0].id)
                + [store.logURL(expired[1].id), store.exitURL(expired[2].id)]
            let keptURLs = retained.flatMap { JobLogFixture.artifacts(store, $0.id) }
            let bytes = Data([0, 0xFF, 10, 42])
            for url in removedURLs + keptURLs { try bytes.write(to: url) }
            #expect(store.prune(now: now) == 3)
            for job in expired + [absent] {
                for url in JobLogFixture.artifacts(store, job.id) {
                    #expect(!FileManager.default.fileExists(atPath: url.path))
                }
            }
            for url in keptURLs { #expect(try Data(contentsOf: url) == bytes) }
            #expect(Set(store.all().map(\.id)) == Set(jobs.map(\.id)))
            #expect(store.prune(now: now) == 0)
            #expect(Set(store.all().map(\.id)) == Set(jobs.map(\.id)))
        }
    }

    @Test func pruneHonorsCustomKeepingDaysAndStrictCutoff() throws {
        try JobLogFixture.withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let cutoff = now.addingTimeInterval(-2 * 86_400)
            let old = JobLogFixture.job(status: .succeeded, endedAt: cutoff.addingTimeInterval(-1))
            let exact = JobLogFixture.job(status: .succeeded, endedAt: cutoff)
            let bytes = Data("Synthetic artifact".utf8)
            for job in [old, exact] {
                try store.save(job)
                for url in JobLogFixture.artifacts(store, job.id) { try bytes.write(to: url) }
            }
            #expect(store.prune(now: now, keepingDays: 2) == 1)
            for url in JobLogFixture.artifacts(store, old.id) {
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
            for url in JobLogFixture.artifacts(store, exact.id) {
                #expect(try Data(contentsOf: url) == bytes)
            }
            #expect(Set(store.all().map(\.id)) == Set([old.id, exact.id]))
            #expect(store.prune(now: now, keepingDays: 2) == 0)
        }
    }
}

private enum JobLogFixture {
    static func withStore(_ body: (JobStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-job-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        try body(JobStore(home: home))
    }

    static func expectNotes(_ bytes: Data, messages: [String]) throws {
        let text = try #require(String(data: bytes, encoding: .utf8))
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == messages.count + 1)
        #expect(lines.last == "")
        let formatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (line, message) in zip(lines, messages) {
            let parts = line.components(separatedBy: " bton: ")
            #expect(parts.count == 2)
            let timestamp = try #require(parts.first)
            #expect(formatter.date(from: timestamp) != nil || fractionalFormatter.date(from: timestamp) != nil)
            #expect(line == "\(timestamp) bton: \(message)")
        }
    }

    static func job(status: Job.Status, endedAt: Date?) -> Job {
        Job(id: UUID(), key: JobKey(repo: "synthetic/repo", item: "pr-1", move: "review", head: "synthetic-head"),
            agent: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: endedAt, status: status)
    }

    static func artifacts(_ store: JobStore, _ id: UUID) -> [URL] {
        [store.outputURL(id), store.logURL(id), store.exitURL(id)]
    }
}
