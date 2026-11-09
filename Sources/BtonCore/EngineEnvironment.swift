import Foundation

extension Engine {
    /// Why the repo's jobs wait this tick: a service its environment names (`DATABASE_URL`,
    /// a Redis) did not answer the probe. The repo's candidates from `first` on that need the
    /// environment leave `pending`, the registry job included: the environment is the repo's on
    /// this Mac, and a held tick costs nothing, while a check against a dead database costs its
    /// whole timeout. The text-only jobs stay and start. Each other run-next pick of the repo
    /// keeps its place with the hold as its reason, as a pick waiting for the code graph does.
    /// Nil when every service answers, or the environment names none.
    func environmentHold(_ repo: WatchedRepo, pending: inout [(candidate: DispatchCandidate, clone: URL, flow: Flow?)],
                         from first: Int) async -> String? {
        let endpoints = EnvironmentProbe.endpoints(in: repo.environment ?? [:])
        guard !endpoints.isEmpty, let hold = EnvironmentProbe.hold(await EnvironmentProbe.unreachable(endpoints)) else { return nil }
        let textOnly = pending[first...].filter(\.candidate.textOnly)
        pending.removeSubrange(first...)
        pending += textOnly
        let starting = Set(textOnly.map { Self.pick(repo: $0.candidate.key.repo, item: $0.candidate.key.item) })
        let prefix = repo.slug.lowercased() + "#"
        for pick in next where pick.hasPrefix(prefix) && !starting.contains(pick) { deferred[pick] = hold }
        return hold
    }
}
