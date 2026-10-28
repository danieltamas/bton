import Foundation

extension Engine {
    /// Why the repo's jobs wait this tick: a service its environment names (`DATABASE_URL`,
    /// a Redis) did not answer the probe. Every candidate of the repo is held, drafts and the
    /// registry job included: the environment is the repo's on this Mac, and a held tick costs
    /// nothing, while a check against a dead database costs its whole timeout. Each run-next
    /// pick of the repo keeps its place with the hold as its reason, as a pick waiting for the
    /// code graph does. Nil when every service answers, or the environment names none.
    func environmentHold(_ repo: WatchedRepo) async -> String? {
        let endpoints = EnvironmentProbe.endpoints(in: repo.environment ?? [:])
        guard !endpoints.isEmpty, let hold = EnvironmentProbe.hold(await EnvironmentProbe.unreachable(endpoints)) else { return nil }
        let prefix = repo.slug.lowercased() + "#"
        for pick in next where pick.hasPrefix(prefix) { deferred[pick] = hold }
        return hold
    }
}
