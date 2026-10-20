import Foundation

/// Where token prices come from, so nobody types them: LiteLLM's public model price list, which
/// tracks the vendors' pricing pages in one JSON file (the vendors publish none). Refreshed once a
/// day by the engine and at install. A failed or implausible refresh keeps the prices Bton already has.
public enum PriceFeed {
    public static let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    public static let source = "LiteLLM model price list"
    public static let refreshEvery: TimeInterval = 86_400

    public enum Failure: Error, LocalizedError {
        case unreadable(String)
        case implausible(String)

        public var errorDescription: String? {
            switch self {
            case let .unreadable(detail): "The price list could not be read: \(detail)"
            case let .implausible(detail): "The price list looks wrong, so the old prices stay: \(detail)"
            }
        }
    }

    /// Anthropic and OpenAI models by their API names, in USD per million tokens. Region and
    /// gateway variants (`anthropic.claude-…`, `azure/…`) are left out: agents report plain names.
    /// A missing cache price is the input price; a cache price that is there but invalid drops the
    /// model, since guessing it could under-count.
    public static func parse(_ data: Data) throws -> [String: ModelPrice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable("not a JSON object")
        }
        var models: [String: ModelPrice] = [:]
        for (name, value) in root {
            guard let entry = value as? [String: Any],
                  ["anthropic", "openai"].contains(entry["litellm_provider"] as? String),
                  isModelName(name),
                  let input = perMillion(entry["input_cost_per_token"]),
                  let output = perMillion(entry["output_cost_per_token"]),
                  let cacheRead = optional(entry["cache_read_input_token_cost"], perMillion),
                  let cacheWrite = optional(entry["cache_creation_input_token_cost"], perMillion) else { continue }
            models[name] = ModelPrice(input: input, cacheRead: cacheRead ?? input, cacheWrite: cacheWrite ?? input, output: output)
        }
        try checkPlausible(models)
        return models
    }

    public static func fetch(session: URLSession = .shared) async throws -> [String: ModelPrice] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.unreadable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try parse(data)
    }

    /// Replaces the feed's models, keeping the owner's custom prices.
    @discardableResult
    public static func refresh(home: BtonHome, now: Date = .now,
                               fetch: () async throws -> [String: ModelPrice] = { try await fetch() }) async throws -> PriceList {
        let models = try await fetch()
        return try replace(home: home, with: models, source: source, now: now)
    }

    /// Loads after the download, never before it, so custom rows saved meanwhile survive.
    private static func replace(home: BtonHome, with models: [String: ModelPrice], source: String, now: Date) throws -> PriceList {
        try PriceList.update(home: home) { list in
            // A feed that lost half its models since the last one is a broken download.
            if list.source == Self.source, source == Self.source, models.count * 2 < list.models.count {
                throw Failure.implausible("\(models.count) models, down from \(list.models.count)")
            }
            // Before the feed, the owner typed every price into `models`; those become custom rows.
            if list.source == nil, !list.models.isEmpty {
                list.custom = list.models.merging(list.custom ?? [:]) { _, owners in owners }
            }
            list.models = models
            list.source = source
            list.updatedAt = now
        }
    }

    public static func isStale(_ list: PriceList, now: Date = .now) -> Bool {
        guard let updated = list.updatedAt else { return true }
        return now.timeIntervalSince(updated) >= refreshEvery
    }

    /// API names only: lowercase letters, digits, dashes, colons, and dots inside a version
    /// (`gpt-4.1`). Any other dot marks a gateway variant (`anthropic.claude-…`), so it is out.
    static func isModelName(_ name: String) -> Bool {
        name.count <= 80 && name.wholeMatch(of: /[a-z0-9][a-z0-9.:-]*/) != nil
            && name.firstMatch(of: /[^0-9]\.|\.[^0-9]/) == nil && !name.hasSuffix(".")
    }

    /// A feed this small, or without a Claude model, is a broken download, not a price change.
    private static func checkPlausible(_ models: [String: ModelPrice]) throws {
        guard models.count >= 5, models.keys.contains(where: { $0.hasPrefix("claude-") }) else {
            throw Failure.implausible("\(models.count) models")
        }
    }

    private static let ceiling: Decimal = 10_000

    /// `.some(nil)` when the field is absent, nil when it is there but invalid, `null` included.
    private static func optional(_ value: Any?, _ read: (Any?) -> Decimal?) -> Decimal?? {
        guard let value else { return .some(nil) }
        guard let decimal = read(value) else { return nil }
        return .some(decimal)
    }

    private static func perMillion(_ value: Any?) -> Decimal? {
        decimal(value).map { $0 * 1_000_000 }.map(rounded).flatMap { $0 <= ceiling ? $0 : nil }
    }

    /// Through the number's shortest text form, so 2.5e-07 is exactly 0.25 per million, not a
    /// binary-float neighbour.
    private static func decimal(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              let decimal = Decimal(string: "\(number.doubleValue)", locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return decimal <= ceiling ? decimal : nil
    }

    private static func rounded(_ value: Decimal) -> Decimal {
        var value = value, result = Decimal()
        NSDecimalRound(&result, &value, 6, .plain)
        return result
    }
}
