import BtonCore
import SwiftUI

/// The repo page's Release action: floats over the feature list for the owner named in the flow's
/// `release.who` once the release is due or its PR is open, shows the run while the release job
/// goes, and stays out of everyone else's way (they see the standing in the header).
private struct ReleaseAction: ViewModifier {
    @Environment(AppStore.self) private var store
    let slug: String
    let report: FeatureReport?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentMargins(.bottom, 64, for: .scrollContent)
                .overlay(alignment: .bottomTrailing) {
                    action.shadow(color: .black.opacity(0.35), radius: 10, y: 4).padding(.trailing, 14).padding(.bottom, 12)
                }
        } else {
            content
        }
    }

    private var isMine: Bool {
        guard let who = store.flows[slug]?.flow?.release?.who, let me = store.me else { return false }
        return who.caseInsensitiveCompare(me) == .orderedSame
    }

    @ViewBuilder private var action: (some View)? {
        if let job = store.jobs.first(where: { $0.status == .running && $0.key.move == Release.move
                                                && $0.key.repo.caseInsensitiveCompare(slug) == .orderedSame }) {
            PillButton(title: "Releasing", symbol: "shippingbox", prominent: false) {
                withAnimation(Motion.spring) { store.viewingRepo = nil; store.watchingJob = job.id }
            }
            .help("The release job runs its checks and the merge: see its log")
        } else if store.isNext(repo: slug, item: Release.item) {
            StartingLabel(repo: slug, reason: store.waitingReason(repo: slug, item: Release.item))
        } else if isMine, let standing = report?.release, Self.offers(standing) {
            PillButton(title: "Release", symbol: "shippingbox") { Task { await store.runNext(repo: slug, item: Release.item) } }
                .help(Self.help(standing))
        }
    }

    static func offers(_ standing: ReleaseStanding) -> Bool {
        switch standing {
        case .due, .open: true
        case .blocked, .waiting, .unknown: false
        }
    }

    static func help(_ standing: ReleaseStanding) -> String {
        if case .open = standing { return "Run the release checks and merge the release PR" }
        return "Open the release PR with the release notes from the registry"
    }
}

extension View {
    func releaseAction(slug: String, report: FeatureReport?) -> some View {
        modifier(ReleaseAction(slug: slug, report: report))
    }
}
