import Foundation

/// A repo's `.bton/features.json`, version 1: the product's areas and features, each feature
/// linked to the issues and PRs that are about it. Read from the branch PRs merge into, like
/// the flow, never from a PR branch. Statuses are never in the file; `FeatureStatuses` computes
/// them at every sync from GitHub and the clone.
public struct FeatureRegistry: Decodable, Sendable, Equatable {
    public static let relativePath = ".bton/features.json"
    public static let supportedVersion = 1
    /// How a link was made: the PR or issue body says it closes the feature's issue, the branch
    /// name, a label, the changed files against the feature's paths, or the title alone.
    public static let whys = ["closes", "branch", "label", "files", "title"]

    public let version: Int
    public let areas: [Area]
    public let features: [Feature]

    /// One part of the product, as the code graph's community hubs show them; `paths` say which
    /// code it owns.
    public struct Area: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let paths: [String]
    }

    public struct Feature: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let summary: String
        public let area: String
        /// Another feature's id for a sub-feature.
        public let parent: String?
        public let paths: [String]
        public let issues: [Link]
        public let prs: [Link]
        /// `YYYY-MM-DD`: when the registry first listed it, and when it was dropped. A feature
        /// is never deleted from the file.
        public let firstSeen: String?
        public let closed: String?
    }

    public struct Link: Decodable, Sendable, Equatable {
        public let number: Int
        public let why: String
    }

    /// nil data is a repo without a registry; an unknown version reads the same, so a newer
    /// Bton's file never shows as broken here.
    public static func load(_ data: Data?) -> RegistryStatus {
        guard let data else { return .none }
        struct Version: Decodable { let version: Int? }
        do {
            guard try JSONDecoder().decode(Version.self, from: data).version == supportedVersion else { return .none }
            let registry = try JSONDecoder().decode(FeatureRegistry.self, from: data)
            if let problem = registry.problem { return .invalid(problem) }
            return .ready(registry)
        } catch {
            return .invalid(String(describing: error))
        }
    }

    public func feature(_ id: String) -> Feature? { features.first { $0.id == id } }

    /// Every issue and PR number a feature links, once, ascending.
    public var linkedNumbers: [Int] {
        Array(Set(features.flatMap { $0.issues.map(\.number) + $0.prs.map(\.number) })).sorted()
    }

    /// What keeps the registry from being used, in the order a person would fix it.
    var problem: String? {
        var ids = Set<String>()
        for area in areas where !ids.insert(area.id).inserted { return "duplicate id: \(area.id)" }
        for feature in features where !ids.insert(feature.id).inserted { return "duplicate id: \(feature.id)" }
        let areaIDs = Set(areas.map(\.id))
        let featureIDs = Set(features.map(\.id))
        for feature in features {
            if !areaIDs.contains(feature.area) { return "area \(feature.area) of \(feature.id) is not an area" }
            if let parent = feature.parent, !featureIDs.contains(parent) { return "parent \(parent) of \(feature.id) is not a feature" }
            for link in feature.issues + feature.prs where !Self.whys.contains(link.why) {
                return "why \(link.why) on #\(link.number) of \(feature.id) is not one of \(Self.whys.joined(separator: ", "))"
            }
        }
        // A parent chain that loops would never end a walk up the tree.
        for feature in features {
            var seen: Set<String> = [feature.id], current = feature.parent
            while let id = current {
                guard seen.insert(id).inserted else { return "parent loop at \(feature.id)" }
                current = self.feature(id)?.parent
            }
        }
        return nil
    }
}

public enum RegistryStatus: Sendable, Equatable {
    case none
    case invalid(String)
    case ready(FeatureRegistry)

    public var registry: FeatureRegistry? {
        if case let .ready(registry) = self { registry } else { nil }
    }
}
