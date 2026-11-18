@testable import BtonCore
import Foundation
import Testing

final class MoveLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

extension StartMovesFixture {
    static let approvalRound = "1792411200"
    static let rejectionRound = "1792411260"
    var mergeKey: JobKey {
        JobKey(repo: repo, item: "pr-7", move: "merge", head: "abcdef01", round: Self.approvalRound)
    }
    /// Opt in: the original no-review fix fixture remains unchanged for its other callers.
    func prepareMerge(checks: String? = nil, who: String = "author", approved: Bool = true) throws {
        try editFlow { flow in
            flow["reviews"] = ["small": [["heading": "## Review:", "notByAuthor": true]]]
            flow["moves"] = [
                ["move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author"],
                ["move": "review", "when": ["no_review_or_response_newer"], "who": "reviewer"],
                ["move": "merge", "when": ["approved_current_head"] + (checks.map { ["checks_green:\($0)"] } ?? []), "who": who]
            ]
        }
        try reviews(approved ? ["approve"] : [])
        try editPR { $0["reviewRequests"] = ["nodes": [["requestedReviewer": ["__typename": "User", "login": "teammate"]]]] }
    }

    func reviews(_ verdicts: [String], head: String? = nil) throws {
        try editPR { pr in
            let reviewed = head ?? (pr["headRefOid"] as? String ?? "abcdef01")
            pr["comments"] = ["nodes": verdicts.enumerated().map { index, verdict in
                ["author": ["login": "reviewer"], "authorAssociation": "MEMBER",
                 "body": "## Review: \(verdict) (head \(reviewed))",
                 "createdAt": "2026-10-19T12:\(String(format: "%02d", index)):00Z"] as [String: Any]
            }]
        }
    }

    func editPR(_ change: (inout [String: Any]) -> Void) throws {
        try editJSONLine(prefix: "{\"data\":") { payload in
            var data = payload["data"] as! [String: Any]
            var repository = data["repository"] as! [String: Any]
            var prs = repository["pullRequests"] as! [String: Any]
            var nodes = prs["nodes"] as! [[String: Any]]
            change(&nodes[0])
            prs["nodes"] = nodes
            repository["pullRequests"] = prs
            data["repository"] = repository
            payload["data"] = data
        }
    }

    func editFlow(_ change: (inout [String: Any]) -> Void) throws {
        try editJSONLine(prefix: "{\"version\":", change)
    }

    private func editJSONLine(prefix: String, _ change: (inout [String: Any]) -> Void) throws {
        let gh = root.appendingPathComponent("gh")
        let script = try String(contentsOf: gh, encoding: .utf8)
        let line = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix(prefix) })
        var object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        change(&object)
        // Preserve the prefix used by the existing fixture's readers after serialization.
        let key = prefix == "{\"version\":" ? "version" : "data"
        let value = object.removeValue(forKey: key)!
        let first = String(decoding: try JSONSerialization.data(withJSONObject: [key: value], options: [.sortedKeys]), as: UTF8.self)
        let rest = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let replacement = String(first.dropLast()) + (object.isEmpty ? "}" : "," + rest.dropFirst())
        try script.replacingOccurrences(of: line, with: replacement).write(to: gh, atomically: true, encoding: .utf8)
    }
}
