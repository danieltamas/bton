import Foundation

/// The release PR's title and body: the features merged into `from` that `to` lacks, by area.
/// Names come from the registry file, which any PR can edit: they are PR body text and nothing
/// else, never a prompt or a command.
public enum ReleaseNotes {
    public static func title(release: Flow.Release, report: FeatureReport) -> String {
        let count = shipping(report).count
        return "Release \(release.from) -> \(release.to): \(count) feature\(count == 1 ? "" : "s")"
    }

    public static func body(report: FeatureReport) -> String {
        var lines = ["Release notes"]
        let features = shipping(report)
        if features.isEmpty {
            lines.append("No registry features in this release.")
        }
        for area in report.registry.registry?.areas ?? [] {
            let own = features.filter { $0.feature.area == area.id }
            guard !own.isEmpty else { continue }
            lines.append("## \(area.name)")
            for (feature, standing) in own {
                let changes = standing.changes.sorted().map { "#\($0)" }.joined(separator: ", ")
                lines.append("- \(feature.name)" + (changes.isEmpty ? "" : " (\(changes))"))
            }
        }
        lines.append("Opened by Bton.")
        return lines.joined(separator: "\n")
    }

    /// The open features in develop, in registry order.
    private static func shipping(_ report: FeatureReport) -> [(feature: FeatureRegistry.Feature, standing: FeatureStanding)] {
        (report.registry.registry?.features ?? []).compactMap { feature in
            guard feature.closed == nil, let standing = report.standings[feature.id], standing.status == .inDevelop else { return nil }
            return (feature, standing)
        }
    }
}
