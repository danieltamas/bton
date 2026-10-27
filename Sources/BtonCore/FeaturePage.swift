import Foundation

/// The page's chips: what ships at the next release, what is being built, what is live, and
/// everything not started.
public enum FeatureFilter: String, CaseIterable, Sendable {
    case shipsNext = "ships next", building, live, ideas
}

/// The repo page as rows: areas in registry order, each feature under its area with its
/// sub-features under it, narrowed by a chip and the search. Pure, so the views stay thin.
public struct FeaturePage: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String { feature.id }
        public let feature: FeatureRegistry.Feature
        public let standing: FeatureStanding
        /// 0 for a feature, 1 for a sub-feature, and so on.
        public let depth: Int

        public init(feature: FeatureRegistry.Feature, standing: FeatureStanding, depth: Int) {
            self.feature = feature
            self.standing = standing
            self.depth = depth
        }
    }

    public struct AreaRows: Sendable, Equatable, Identifiable {
        public var id: String { area.id }
        public let area: FeatureRegistry.Area
        public let rows: [Row]
        /// Per status, over the rows: what a collapsed area shows.
        public let counts: [FeatureStatus: Int]

        public init(area: FeatureRegistry.Area, rows: [Row]) {
            self.area = area
            self.rows = rows
            counts = rows.reduce(into: [:]) { $0[$1.standing.status, default: 0] += 1 }
        }
    }

    public let areas: [AreaRows]

    /// Closed features are left out. A chip keeps a feature whose status matches and the parents
    /// of a kept sub-feature; the search keeps a feature whose name, summary, id or linked
    /// numbers match, and its parents. An area with nothing left is left out, unless neither a
    /// chip nor a search narrows the page.
    public static func make(registry: FeatureRegistry, report: FeatureReport, filter: FeatureFilter?, query: SearchQuery) -> FeaturePage {
        let open = registry.features.filter { $0.closed == nil }
        let standing = { (feature: FeatureRegistry.Feature) in
            report.standings[feature.id] ?? FeatureStanding(status: .idea, timeline: [], openIssues: 0, openPullRequests: 0, changes: [])
        }
        let narrowed = filter != nil || !query.isEmpty
        var kept = Set(open.filter { feature in
            (filter.map { matches($0, standing(feature).status) } ?? true)
                && query.matches(numbers: (feature.issues + feature.prs).map(\.number), texts: [feature.name, feature.summary, feature.id])
        }.map(\.id))
        // A kept sub-feature needs its parents on the page to be read in place.
        for feature in open where kept.contains(feature.id) {
            var parent = feature.parent
            while let id = parent, kept.insert(id).inserted { parent = registry.feature(id)?.parent }
        }
        let byParent = Dictionary(grouping: open.filter { kept.contains($0.id) }) { $0.parent ?? "" }
        func rows(under parent: String, area: String, depth: Int) -> [Row] {
            (byParent[parent] ?? []).filter { $0.area == area || depth > 0 }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .flatMap { [Row(feature: $0, standing: standing($0), depth: depth)] + rows(under: $0.id, area: area, depth: depth + 1) }
        }
        let areas = registry.areas.map { AreaRows(area: $0, rows: rows(under: "", area: $0.id, depth: 0)) }
        return FeaturePage(areas: narrowed ? areas.filter { !$0.rows.isEmpty } : areas)
    }

    public init(areas: [AreaRows]) {
        self.areas = areas
    }

    public static func matches(_ filter: FeatureFilter, _ status: FeatureStatus) -> Bool {
        switch filter {
        case .shipsNext: status == .inDevelop
        case .building: status == .building
        case .live: status == .live
        case .ideas: status == .ready || status == .spec || status == .idea
        }
    }

    /// How many open features the chip would show.
    public static func count(_ filter: FeatureFilter, report: FeatureReport) -> Int {
        guard let registry = report.registry.registry else { return 0 }
        return registry.features.filter { feature in
            feature.closed == nil && report.standings[feature.id].map { matches(filter, $0.status) } ?? matches(filter, .idea)
        }.count
    }

    /// "14 features in develop that main lacks. Last release Oct 19." Only with a `release`
    /// section: without one nothing waits between branches.
    public static func summary(report: FeatureReport, to: String, now: Date) -> String? {
        guard report.hasRelease else { return nil }
        let waiting = count(.shipsNext, report: report)
        var text = "\(waiting) feature\(waiting == 1 ? "" : "s") in develop that \(to) lacks."
        if let last = report.lastRelease { text += " Last release \(Self.monthDay(last))." }
        return text
    }

    /// "100 commits, 8 days": what the base has that the release branch lacks, and for how long.
    public static func ahead(commits: Int?, since: Date?, now: Date) -> String? {
        guard let commits, commits > 0 else { return nil }
        var text = "\(commits) commit\(commits == 1 ? "" : "s")"
        if let since {
            let days = max(0, Int(now.timeIntervalSince(since) / 86_400))
            text += ", \(days) day\(days == 1 ? "" : "s")"
        }
        return text
    }

    static func monthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
