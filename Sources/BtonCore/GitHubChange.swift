import Foundation

extension GitHubClient {
    /// The ETag of the repo's open-PR list, 30 newest-updated: a push, an assignee, a requested
    /// review, a label, a comment, a close or a merge all change it. Asked with the tag already
    /// known, GitHub answers 304 and counts nothing against the quota, so it can be asked often.
    /// Checks finishing do not change it: the sync's own poll reads those.
    public func pullListTag(repo: String, known: String?) async throws -> String? {
        var arguments = ["api", "-i", "repos/\(repo)/pulls?state=open&sort=updated&direction=desc&per_page=30"]
        if let known { arguments += ["-H", "If-None-Match: \(known)"] }
        let result = try await runner.run(ghPath, arguments, timeout: .seconds(30))
        guard result.status == 0 else { throw Failure.ghFailed(status: result.status, stderr: result.stderr) }
        return Self.listTag(fromResponse: String(decoding: result.stdout, as: UTF8.self), known: known)
    }

    /// The tag a `gh api -i` response carries: the one asked with on a 304, the header's on a 200.
    static func listTag(fromResponse response: String, known: String?) -> String? {
        var lines = response.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).makeIterator()
        if let status = lines.next(), status.contains(" 304") { return known }
        while let line = lines.next(), !line.isEmpty {
            guard line.lowercased().hasPrefix("etag:") else { continue }
            return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
