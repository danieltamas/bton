import Foundation

enum DispatchError: Error, LocalizedError {
    case agentNotFound(String)
    case worktree(String)
    case placeholder(String)
    case environment(String)
    case timedOut(String, minutes: Int)
    case attachment(String)

    var errorDescription: String? {
        switch self {
        case let .agentNotFound(name): "\(name) not found on this Mac's PATH"
        case let .worktree(reason): "worktree: \(reason)"
        case let .placeholder(reason): reason
        case let .environment(reason): "environment: \(reason)"
        case let .attachment(name): "attachment: \(name) is not a plain file name"
        case let .timedOut(command, minutes): "`\(command)` did not finish in \(minutes) minutes and was stopped"
        }
    }
}
