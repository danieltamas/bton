import Foundation
import Observation

/// The presses running now, by id: the one way a view runs an async action. A press holds its
/// id until the action returns or throws, and a second press with the same id meanwhile is
/// nothing, so the button it came from can show the press and refuse another.
@MainActor @Observable public final class InFlightActions {
    public private(set) var ids: Set<String> = []

    public init() {}

    public func isRunning(_ id: String) -> Bool { ids.contains(id) }

    /// Runs `action` unless `id` is already running (then false, and nothing runs). The id is
    /// removed when the action returns or throws; a thrown error reaches the caller.
    @discardableResult
    public func perform(_ id: String, _ action: () async throws -> Void) async rethrows -> Bool {
        guard ids.insert(id).inserted else { return false }
        defer { ids.remove(id) }
        try await action()
        return true
    }
}
