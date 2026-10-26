@testable import BtonCore
import Testing

/// Bound subprocess-heavy test bodies, not SwiftPM workers. Waiting suspends rather than
/// blocking the cooperative pool, and parameterized cases each acquire their own permit.
struct ProcessBound: TestTrait, SuiteTrait, TestScoping {
    typealias TestScopeProvider = Self

    var isRecursive: Bool { true }
    private static let permits = ProcessPermits()

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing body: @Sendable () async throws -> Void) async throws {
        await Self.permits.acquire()
        do {
            try await Dispatcher.$agentPollInterval.withValue(.milliseconds(20)) {
                try await body()
            }
        } catch {
            await Self.permits.release()
            throw error
        }
        await Self.permits.release()
    }
}

private actor ProcessPermits {
    private var available = 4
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
