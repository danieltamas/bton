import BtonCore
import Foundation
import Testing

struct CostAcceptanceTests {
    @Test func assistantUsageDeduplicatesMessagesAndSeparatesModels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.jsonl")
        let repeated = #"{"type":"assistant","requestId":"request-1","message":{"id":"message-1","model":"synthetic-sonnet","usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300,"output_tokens":40}}}"#
        let second = #"{"type":"assistant","requestId":"request-2","message":{"id":"message-2","model":"synthetic-opus","usage":{"input_tokens":11,"cache_read_input_tokens":22,"cache_creation_input_tokens":33,"output_tokens":44}}}"#
        let user = #"{"type":"user","requestId":"request-user","message":{"id":"user-1","model":"synthetic-sonnet","usage":{"input_tokens":999999,"output_tokens":999999}}}"#
        try ([repeated, repeated, "not JSON", second, user, repeated].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(try ClaudeSessions.usage(ofSessionFile: file) == [
            "synthetic-sonnet": TokenUsage(input: 100, cacheRead: 200, cacheWrite: 300, output: 40),
            "synthetic-opus": TokenUsage(input: 11, cacheRead: 22, cacheWrite: 33, output: 44)
        ])
    }

    @Test func deduplicationUsesBothMessageAndRequestID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.jsonl")
        let rows = [("m1", "r1"), ("m1", "r2"), ("m2", "r1")].map { message, request in
            "{\"type\":\"assistant\",\"requestId\":\"\(request)\",\"message\":{\"id\":\"\(message)\",\"model\":\"synthetic\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}"
        }
        try rows.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(try ClaudeSessions.usage(ofSessionFile: file)["synthetic"] == TokenUsage(input: 30, output: 6))
    }

    @Test func sessionLookupUsesLowercaseUUIDInProjectDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("synthetic-encoded-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!
        let file = project.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        try Data().write(to: file)
        let found = try #require(ClaudeSessions.sessionFile(id: id, projectsRoot: directory))
        #expect(found.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(ClaudeSessions.sessionFile(id: UUID(), projectsRoot: directory) == nil)
    }

    @Test func pricesPreferExactThenLongestPrefix() throws {
        let short = ModelPrice(input: 1, cacheRead: 1, cacheWrite: 1, output: 1)
        let long = ModelPrice(input: 2, cacheRead: 2, cacheWrite: 2, output: 2)
        let exact = ModelPrice(input: 3, cacheRead: 3, cacheWrite: 3, output: 3)
        let prices = PriceList(models: ["claude": short, "claude-sonnet": long,
            "claude-sonnet-5-5-20261001": exact])
        #expect(prices.price(for: "claude-sonnet-5-5-20261001") == exact)
        #expect(prices.price(for: "claude-sonnet-5-5-20261002") == long)
        #expect(prices.price(for: "claude-other") == short)
        #expect(prices.price(for: "unknown") == nil)
        let restored = try JSONDecoder().decode(PriceList.self, from: JSONEncoder().encode(prices))
        #expect(restored.models == prices.models)
    }

    @Test func modelCostMatchesHandComputationAndUnknownIsNotFree() {
        let prices = PriceList(models: [
            "synthetic-a": ModelPrice(input: 3, cacheRead: Decimal(string: "0.30")!, cacheWrite: Decimal(string: "3.75")!, output: 15),
            "synthetic-b": ModelPrice(input: 5, cacheRead: 1, cacheWrite: 6, output: 25)
        ])
        let usage = [
            "synthetic-a": TokenUsage(input: 1_000_000, cacheRead: 2_000_000, cacheWrite: 400_000, output: 100_000),
            "synthetic-b": TokenUsage(input: 200_000, cacheRead: 300_000, cacheWrite: 100_000, output: 20_000)
        ]
        // A: 3 + 0.60 + 1.50 + 1.50 = 6.60; B: 1 + 0.30 + 0.60 + 0.50 = 2.40; total $9.00.
        #expect(PriceList.cost(of: usage, prices: prices) == Decimal(9))
        for tokens in [TokenUsage(input: 1), TokenUsage(cacheRead: 1), TokenUsage(cacheWrite: 1), TokenUsage(output: 1)] {
            var unknown = usage
            unknown["unpriced"] = tokens
            #expect(PriceList.cost(of: unknown, prices: prices) == nil)
        }
        var zero = usage
        zero["unpriced"] = TokenUsage()
        #expect(PriceList.cost(of: zero, prices: prices) == Decimal(9))
    }

    @Test func priceListLoadMissingInvalidAndValidFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = BtonHome(environment: ["BTON_HOME": directory.path])
        #expect(PriceList.load(home: home).models.isEmpty)
        let file = directory.appendingPathComponent("prices.json")
        try Data("not JSON".utf8).write(to: file)
        #expect(PriceList.load(home: home).models.isEmpty)
        let price = ModelPrice(input: 3, cacheRead: 1, cacheWrite: 4, output: 15)
        try JSONEncoder().encode(PriceList(models: ["synthetic": price])).write(to: file)
        #expect(PriceList.load(home: home).models == ["synthetic": price])
    }
}
