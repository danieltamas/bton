import Foundation

/// Bton's own releases, for Settings > About: what this build is and how it stands against the
/// latest one on GitHub.
public enum BtonRelease {
    public static let repo = "danieltamas/bton"
    public static let url = URL(string: "https://github.com/\(repo)")!

    public struct Build: Equatable, Sendable {
        public let version: String
        /// Commits after the release's tag: a build from a checkout.
        public let commitsAfter: Int
        public let commit: String?
        public let dirty: Bool

        public init(version: String, commitsAfter: Int, commit: String?, dirty: Bool) {
            self.version = version
            self.commitsAfter = commitsAfter
            self.commit = commit
            self.dirty = dirty
        }
    }

    /// `version` is the bundle's; `source` is `git describe --tags --always --dirty` of a build
    /// from a checkout (`BtonSource` in Info.plist), nil for a release.
    public static func build(version: String, source: String?) -> Build {
        guard var rest = source, !rest.isEmpty else { return Build(version: version, commitsAfter: 0, commit: nil, dirty: false) }
        let dirty = rest.hasSuffix("-dirty")
        if dirty { rest.removeLast("-dirty".count) }
        if let match = rest.wholeMatch(of: /v?(\d+\.\d+\.\d+)(?:-(\d+)-g([0-9a-f]+))?/) {
            return Build(version: String(match.1), commitsAfter: match.2.flatMap { Int($0) } ?? 0,
                         commit: match.3.map(String.init), dirty: dirty)
        }
        return Build(version: version, commitsAfter: 0, commit: rest, dirty: dirty)
    }

    /// `x.y.z` against `x.y.z`, numerically; nil when either is not one.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let left = numbers(a), let right = numbers(b) else { return nil }
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = (version.hasPrefix("v") ? version.dropFirst() : Substring(version)).split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && !$0.isEmpty ? Int($0) : nil }
        return parts.count == 3 && values.count == 3 ? values : nil
    }

    public enum Standing: Equatable, Sendable {
        case latest, behind(latest: String), ahead, unknown
    }

    public static func standing(of build: Build, latestTag: String) -> Standing {
        switch compare(build.version, latestTag) {
        case .orderedAscending: .behind(latest: latestTag)
        case .orderedSame: build.commitsAfter == 0 && !build.dirty ? .latest : .ahead
        case .orderedDescending: .ahead
        case nil: .unknown
        }
    }
}

extension GitHubClient {
    public func latestReleaseTag() async throws -> String {
        try Self.decodeLatestRelease(try await gh(["api", "repos/\(BtonRelease.repo)/releases/latest"]))
    }

    public static func decodeLatestRelease(_ data: Data) throws -> String {
        struct Release: Decodable { let tag_name: String }
        return try JSONDecoder().decode(Release.self, from: data).tag_name
    }
}
