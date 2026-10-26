@testable import BtonCore
import Foundation
import Testing

private enum PriceFeedFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    enum FetchFailure: Error { case offline }

    static func data(_ json: String) -> Data { Data(json.utf8) }

    static func price(_ value: Decimal) -> ModelPrice {
        ModelPrice(input: value, cacheRead: value, cacheWrite: value, output: value)
    }

    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-prices-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static let feedEntries = #"""
    "claude-test": {"litellm_provider":"anthropic","input_cost_per_token":2.5e-07,"output_cost_per_token":1.25e-06,"cache_read_input_token_cost":4e-06,"cache_creation_input_token_cost":1e-05},
    "gpt-test": {"litellm_provider":"openai","input_cost_per_token":1e-06,"output_cost_per_token":2e-06},
    "gpt-test:2": {"litellm_provider":"openai","input_cost_per_token":0,"output_cost_per_token":0},
    "claude-other": {"litellm_provider":"anthropic","input_cost_per_token":3e-06,"output_cost_per_token":4e-06},
    "gpt-boundary": {"litellm_provider":"openai","input_cost_per_token":0.01,"output_cost_per_token":0.01}
    """#

    static func feed(_ extra: [String] = []) -> Data {
        data("{" + ([feedEntries] + extra).joined(separator: ",") + "}")
    }

    static var saved: PriceList {
        PriceList(models: ["old-model": price(Decimal(string: "0.25")!)],
                  custom: ["owner-model": price(Decimal(string: "1.25")!)],
                  source: "previous", updatedAt: now.addingTimeInterval(-100_000))
    }

    static func expectSaved(_ list: PriceList, home: BtonHome) {
        let loaded = PriceList.load(home: home)
        #expect(loaded.models == list.models)
        #expect(loaded.custom == list.custom)
        #expect(loaded.source == list.source)
        #expect(loaded.updatedAt == list.updatedAt)
    }
}

@Suite(ProcessBound())
struct PriceFeedAcceptanceTests {
    @Test func feedConvertsScientificNotationToExactDecimalsAndDefaultsCaches() throws {
        let models = try PriceFeed.parse(PriceFeedFixture.feed())
        #expect(models.count == 5)
        let price = try #require(models["claude-test"])
        #expect(price.input == Decimal(string: "0.25"))
        #expect(price.output == Decimal(string: "1.25"))
        #expect(price.cacheRead == Decimal(string: "4"))
        #expect(price.cacheWrite == Decimal(string: "10"))
        #expect(models["gpt-test"] == ModelPrice(input: 1, cacheRead: 1, cacheWrite: 1, output: 2))
        #expect(models["gpt-test:2"] == PriceFeedFixture.price(0))
        #expect(models["gpt-boundary"] == PriceFeedFixture.price(10_000))
    }

    @Test func feedFiltersProviderAndModelNameBoundaries() throws {
        let entry = #"{"litellm_provider":"anthropic","input_cost_per_token":1e-06,"output_cost_per_token":2e-06}"#
        let invalid = ["anthropic.claude-x", "azure/gpt-5", "us.anthropic.claude-x", "Claude-X",
                       "", "gpt_test", "gpt test", String(repeating: "a", count: 81)]
        let longest = String(repeating: "a", count: 80)
        var extra = invalid.map { "\"\($0)\":\(entry)" }
        extra.append("\"\(longest)\":\(entry)")
        for provider in ["vertex_ai", "bedrock", "azure"] {
            extra.append("\"\(provider.replacingOccurrences(of: "_", with: "-"))-model\":{\"litellm_provider\":\"\(provider)\",\"input_cost_per_token\":0.000001,\"output_cost_per_token\":0.000002}")
        }
        let models = try PriceFeed.parse(PriceFeedFixture.feed(extra))
        #expect(Set(models.keys) == Set(["claude-test", "gpt-test", "gpt-test:2", "claude-other", "gpt-boundary", longest]))
    }

    @Test func feedSkipsMissingAndInvalidRequiredPrices() throws {
        let invalidValues = ["-0.000001", "\"0.000001\"", "\"bad\"", "true", "false", "null", "0.010001"]
        var extra: [String] = []
        for field in ["input_cost_per_token", "output_cost_per_token"] {
            let other = field == "input_cost_per_token" ? "output_cost_per_token" : "input_cost_per_token"
            extra.append("\"missing-\(field.replacingOccurrences(of: "_", with: "-"))\":{\"litellm_provider\":\"openai\",\"\(other)\":0.000001}")
            for (index, value) in invalidValues.enumerated() {
                extra.append("\"bad-\(field.replacingOccurrences(of: "_", with: "-"))-\(index)\":{\"litellm_provider\":\"openai\",\"\(field)\":\(value),\"\(other)\":0.000001}")
            }
        }
        #expect(try PriceFeed.parse(PriceFeedFixture.feed(extra)).count == 5)
    }

    @Test func feedDefaultsEachMissingCacheFieldIndependently() throws {
        let extra = [
            #""claude-read-only":{"litellm_provider":"anthropic","input_cost_per_token":1e-06,"output_cost_per_token":2e-06,"cache_read_input_token_cost":2.5e-07}"#,
            #""claude-write-only":{"litellm_provider":"anthropic","input_cost_per_token":1e-06,"output_cost_per_token":2e-06,"cache_creation_input_token_cost":1.25e-06}"#
        ]
        let models = try PriceFeed.parse(PriceFeedFixture.feed(extra))
        #expect(models["claude-read-only"] == ModelPrice(input: 1, cacheRead: Decimal(string: "0.25")!, cacheWrite: 1, output: 2))
        #expect(models["claude-write-only"] == ModelPrice(input: 1, cacheRead: 1, cacheWrite: Decimal(string: "1.25")!, output: 2))
    }

    @Test func feedSkipsEntriesWithInvalidExplicitCachePrices() throws {
        var extra: [String] = []
        for (fieldIndex, field) in ["cache_read_input_token_cost", "cache_creation_input_token_cost"].enumerated() {
            for (index, value) in ["-0.000001", "\"bad\"", "true", "false", "0.010001"].enumerated() {
                extra.append("\"bad-cache-\(fieldIndex)-\(index)\":{\"litellm_provider\":\"anthropic\",\"input_cost_per_token\":0.000001,\"output_cost_per_token\":0.000002,\"\(field)\":\(value)}")
            }
        }
        #expect(try PriceFeed.parse(PriceFeedFixture.feed(extra)).count == 5)
    }

    @Test func feedRejectsUnreadableAndImplausibleTables() throws {
        for json in ["not JSON", "[]"] {
            do {
                _ = try PriceFeed.parse(PriceFeedFixture.data(json))
                Issue.record("Expected an unreadable feed")
            } catch PriceFeed.Failure.unreadable { }
        }
        let four = PriceFeedFixture.feedEntries.components(separatedBy: "\n").dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ","))
        let noClaude = PriceFeedFixture.feedEntries.replacingOccurrences(of: "claude-", with: "gpt-")
        for json in ["{}", "{\(four)}", "{\(noClaude)}"] {
            do {
                _ = try PriceFeed.parse(PriceFeedFixture.data(json))
                Issue.record("Expected an implausible feed")
            } catch PriceFeed.Failure.implausible { }
        }
    }

    @Test func refreshReplacesFeedModelsAndPreservesCustomPrices() async throws {
        let root = try PriceFeedFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        try PriceFeedFixture.saved.save(home: home)
        let models = try PriceFeed.parse(PriceFeedFixture.feed())
        let list = try await PriceFeed.refresh(home: home, now: PriceFeedFixture.now, fetch: { models })
        #expect(list.models == models)
        #expect(list.models["old-model"] == nil)
        #expect(list.custom == PriceFeedFixture.saved.custom)
        #expect(list.source == PriceFeed.source)
        #expect(list.updatedAt == PriceFeedFixture.now)
        #expect(FileManager.default.fileExists(atPath: PriceList.url(home: home).path))
        PriceFeedFixture.expectSaved(list, home: home)
    }

    @Test func refreshFailureRethrowsAndLeavesSavedFileUnchanged() async throws {
        let root = try PriceFeedFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        try PriceFeedFixture.saved.save(home: home)
        let before = try Data(contentsOf: PriceList.url(home: home))
        do {
            _ = try await PriceFeed.refresh(home: home, now: PriceFeedFixture.now,
                                            fetch: { throw PriceFeedFixture.FetchFailure.offline })
            Issue.record("Refresh must rethrow the fetch failure")
        } catch PriceFeedFixture.FetchFailure.offline { }
        #expect(try Data(contentsOf: PriceList.url(home: home)) == before)
        PriceFeedFixture.expectSaved(PriceFeedFixture.saved, home: home)
    }

    @Test func refreshFailureLeavesSavedFileUnchanged() async throws {
        let root = try PriceFeedFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        try PriceFeedFixture.saved.save(home: home)
        let before = try Data(contentsOf: PriceList.url(home: home))
        do {
            _ = try await PriceFeed.refresh(home: home, now: PriceFeedFixture.now,
                                         fetch: { throw PriceFeedFixture.FetchFailure.offline })
            Issue.record("Refresh must throw when the fetch fails")
        } catch PriceFeedFixture.FetchFailure.offline { }
        #expect(try Data(contentsOf: PriceList.url(home: home)) == before)
        PriceFeedFixture.expectSaved(PriceFeedFixture.saved, home: home)
    }

    @Test func stalenessUsesExactDailyBoundary() {
        let now = PriceFeedFixture.now
        #expect(PriceFeed.isStale(PriceList(models: [:]), now: now))
        for age: TimeInterval in [0, 1, 86_399, 86_399.5] {
            #expect(!PriceFeed.isStale(PriceList(models: [:], updatedAt: now.addingTimeInterval(-age)), now: now))
        }
        for age: TimeInterval in [86_400, 86_401, 172_800] {
            #expect(PriceFeed.isStale(PriceList(models: [:], updatedAt: now.addingTimeInterval(-age)), now: now))
        }
    }

    @Test func priceListRoundTripPreservesMetadataAndLoadsLegacyShape() throws {
        let root = try PriceFeedFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        try PriceFeedFixture.saved.save(home: home)
        PriceFeedFixture.expectSaved(PriceFeedFixture.saved, home: home)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: PriceList.url(home: home))) as? [String: Any])
        let timestamp = try #require(json["updatedAt"] as? String)
        #expect(ISO8601DateFormatter().date(from: timestamp) == PriceFeedFixture.saved.updatedAt)
        let legacy = #"{"models":{"legacy-model":{"input":0.25,"cacheRead":0.1,"cacheWrite":1.25,"output":4}}}"#
        try PriceFeedFixture.data(legacy).write(to: PriceList.url(home: home))
        let loaded = PriceList.load(home: home)
        #expect(loaded.models["legacy-model"] == ModelPrice(input: Decimal(string: "0.25")!, cacheRead: Decimal(string: "0.1")!,
                                                            cacheWrite: Decimal(string: "1.25")!, output: 4))
        #expect(loaded.custom == nil)
        #expect(loaded.source == nil)
        #expect(loaded.updatedAt == nil)
    }

    @Test func priceLookupHonorsExactLongestPrefixAndCustomTies() {
        let p = PriceFeedFixture.price
        let list = PriceList(models: ["claude-": p(1), "claude-sonnet": p(2), "claude-sonnet-exact": p(3),
                                      "gpt-": p(4), "gpt-long": p(5)],
                             custom: ["claude-": p(6), "claude-sonnet-exact": p(7), "gpt-longer": p(8)])
        #expect(list.price(for: "claude-sonnet-exact") == p(7))
        #expect(list.price(for: "claude-sonnet") == p(2))
        #expect(list.price(for: "claude-sonnet-dated") == p(2))
        #expect(list.price(for: "claude-other") == p(6))
        #expect(list.price(for: "claude-sonnet-exact-dated") == p(7))
        #expect(list.price(for: "gpt-longer-dated") == p(8))
        #expect(list.price(for: "unknown-model") == nil)
    }

    @Test func costIsNilForAnyUsedModelWithoutPrice() {
        let list = PriceList(models: ["known": PriceFeedFixture.price(1)])
        for tokens in [TokenUsage(input: 1), TokenUsage(cacheRead: 1), TokenUsage(cacheWrite: 1), TokenUsage(output: 1)] {
            #expect(PriceList.cost(of: ["known": TokenUsage(input: 1_000_000), "unknown": tokens], prices: list) == nil)
        }
        #expect(PriceList.cost(of: ["known": TokenUsage(input: 1_000_000)], prices: list) == Decimal(1))
    }
}
