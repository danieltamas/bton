import BtonCore
import SwiftUI

/// One feature: what it is, where its code lives, the statuses it went through and the PRs
/// that changed it.
struct FeatureDetail: View {
    @Environment(AppStore.self) private var store
    let slug: String
    let row: FeaturePage.Row
    let close: () -> Void

    var body: some View {
        let feature = row.feature
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Back to the features", action: close)
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.name).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    HStack(spacing: 6) {
                        FeatureStatusChip(status: row.standing.status)
                        if let since = row.standing.since {
                            RelativeTime(date: since) { "for \($0)" }.font(.meta).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(feature.summary)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !feature.paths.isEmpty {
                        section("Paths") {
                            ForEach(feature.paths, id: \.self) { path in
                                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    if !row.standing.timeline.isEmpty {
                        section("Timeline") {
                            ForEach(Array(row.standing.timeline.enumerated()), id: \.offset) { _, event in
                                HStack(spacing: 8) {
                                    FeatureStatusChip(status: event.status)
                                    if let at = event.at {
                                        Text(at.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                    if let number = event.number { NumberLink(slug: slug, number: number) }
                                }
                                .font(.meta)
                            }
                        }
                    }
                    if !row.standing.changes.isEmpty {
                        section("Changes") {
                            ForEach(row.standing.changes, id: \.self) { number in
                                let fact = store.features[slug]?.facts.pullRequests[number]
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    NumberLink(slug: slug, number: number)
                                    Text(fact.map { $0.title.isEmpty ? "merged" : $0.title } ?? "merged")
                                        .foregroundStyle(Theme.textSecondary).lineLimit(2)
                                    Spacer(minLength: 0)
                                    if let at = fact?.mergedAt {
                                        Text(at.formatted(.dateTime.day().month(.abbreviated).year())).foregroundStyle(Theme.textTertiary)
                                            .lineLimit(1).fixedSize()
                                    }
                                }
                                .font(.meta)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 2)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: title)
            content()
        }
    }
}

/// `#428` as a link to the issue or PR on GitHub, which sends a PR number to the PR.
private struct NumberLink: View {
    let slug: String
    let number: Int

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(slug)/issues/\(number)")!)
        } label: {
            Text("#\(number)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.mint)
        }
        .buttonStyle(PressStyle())
        .help("Open #\(number) on GitHub")
    }
}
