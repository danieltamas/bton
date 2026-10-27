import Foundation

/// Why Take it wrote nothing.
public enum TakeError: Error, Equatable, LocalizedError {
    /// The PR, its move or its owner is not what the pressed row showed.
    case changed
    /// A Bton holds the PR's lease, or the lease could not be read.
    case busy

    public var errorDescription: String? {
        switch self {
        case .changed: "The PR changed since the last sync; nothing was taken."
        case .busy: "A Bton is working on this PR; nothing was taken. Try again when it is done."
        }
    }
}

extension Engine {
    /// Take it: assigns the PR to me alone on GitHub, under its lease, so every Mac reads the move as
    /// mine, and puts it first in line. Checked against a fresh read of the owner the row showed.
    /// `pressed`: a person asked for it; the sync's own take leaves the checks' `BTON_PRESSED` unset.
    public func take(repo: String, number: Int, from owner: String?, pressed: Bool = true) async throws -> Move {
        let config = try BtonConfig.loadOrCreate(home: home)
        let branch = config.repos.first { $0.slug.caseInsensitiveCompare(repo) == .orderedSame }?.branch
        // Read before the claim, so a stale row writes nothing, and again under the lease: another
        // Mac may take or start the move while the claim is pushed.
        let me = try await takeable(repo: repo, number: number, from: owner, branch: branch).me
        let item = "pr-\(number)"
        let leases = try await dispatcher(me: me, repos: config.repos).leases
        guard let lease = LeaseItem(item), case let .claimed(held)? = try? await leases.claim(lease, in: repo)
        else { throw TakeError.busy }
        // Once more on a failure; a lease left held only delays this Mac's own start until it expires.
        let release = { [log] in
            for attempt in 1...2 {
                do {
                    return try await leases.release(held, ran: false)
                } catch where attempt == 2 {
                    log("\(repo)#\(number): Take it could not release the PR's lease, which frees when it expires: \(error.localizedDescription)")
                } catch {}
            }
        }
        let taken: Move
        do {
            let fresh = try await takeable(repo: repo, number: number, from: owner, branch: branch)
            // A claim pushed, or reads made, while the Mac slept can leave the lease expired by now:
            // it must outlast the assign too.
            guard held.isLive(at: .now + 60) else { throw TakeError.busy }
            try await github.assign(me, replacing: fresh.pr.assignees, repo: repo, number: number)
            taken = fresh.move
        } catch {
            await release()
            throw error
        }
        await release()
        runNext(repo: repo, item: item, pressed: pressed)
        log("\(repo)#\(number): took \(taken.name) from \(owner ?? "nobody"), assigned \(me)")
        return taken
    }

    /// The open PR, its move once taken and my login, while the PR's move still has the owner the
    /// row showed and is one I can take.
    private func takeable(repo: String, number: Int, from owner: String?,
                          branch: String?) async throws -> (me: String, pr: PullRequest, move: Move) {
        let flow = Flow.load(try await github.flowFile(repo: repo, branch: branch)).flow
        let read = try await github.openPullRequests(repo: repo)
        guard let flow, let pr = read.pullRequests.first(where: { $0.number == number }),
              let current = FlowEngine.move(for: pr, flow: flow),
              current.owner?.lowercased() == owner?.lowercased(),
              let taken = FlowEngine.takeover(of: pr, flow: flow, me: read.viewer)
        else { throw TakeError.changed }
        return (read.viewer, pr, taken)
    }
}

extension Engine {
    /// At most this many PRs are taken per sync: a flow change must not reassign a whole queue at once.
    static let autoTakeLimit = 2

    /// The PRs whose move Take it could take, not yet tried at their owner and head.
    static func autoTakeable(_ pullRequests: [PullRequest], flow: Flow, me: String, repo: String, tried: Set<String>) -> [PullRequest] {
        pullRequests.filter { pr in
            FlowEngine.takeover(of: pr, flow: flow, me: me) != nil && !tried.contains(autoTakeKey(pr, repo: repo))
        }
    }

    static func autoTakeKey(_ pr: PullRequest, repo: String) -> String {
        "\(pick(repo: repo, item: "pr-\(pr.number)"))@\(pr.move?.owner?.lowercased() ?? "")@\(pr.headSha)"
    }

    /// Takes the teammates' moves a repo with `takeMoves` leaves waiting; a refusal (changed, busy)
    /// is logged and not retried on this owner and head.
    func autoTake(_ pullRequests: [PullRequest], flow: Flow, repo: String, me: String) async {
        for pr in Self.autoTakeable(pullRequests, flow: flow, me: me, repo: repo, tried: autoTaken).prefix(Self.autoTakeLimit) {
            autoTaken.insert(Self.autoTakeKey(pr, repo: repo))
            do {
                _ = try await take(repo: repo, number: pr.number, from: pr.move?.owner, pressed: false)
            } catch {
                log("\(repo)#\(pr.number): automatic Take it stopped: \(error.localizedDescription)")
            }
        }
    }
}
