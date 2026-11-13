import Foundation

/// Why Take it wrote nothing.
public enum TakeError: Error, Equatable, LocalizedError {
    /// The PR, its move or its owner is not what the pressed row showed.
    case changed
    /// A Bton holds the PR's lease, or the lease could not be read.
    case busy
    /// A service the repo's environment names does not answer on this Mac: the move would wait here.
    case held(String)

    public var errorDescription: String? {
        switch self {
        case .changed: "The PR changed since the last sync; nothing was taken."
        case .busy: "A Bton is working on this PR; nothing was taken. Try again when it is done."
        case let .held(hold): "This Mac cannot run the repo's jobs now, so nothing was taken. \(hold)"
        }
    }
}

extension Engine {
    /// Take it: makes me the PR's only assignee (an `assignee` move) or only requested reviewer (a
    /// `reviewer` move) on GitHub, under its lease, so every Mac reads the move as mine, and puts it
    /// first in line. Checked against a fresh read of the owner the row showed.
    /// `pressed`: a person asked for it; the sync's own take leaves the checks' `BTON_PRESSED` unset.
    public func take(repo: String, number: Int, from owner: String?, pressed: Bool = true) async throws -> Move {
        let config = try BtonConfig.loadOrCreate(home: home)
        let watched = config.repos.first { $0.slug.caseInsensitiveCompare(repo) == .orderedSame }
        let branch = watched?.branch
        // A move taken onto a Mac whose services are down waits there for as long as they are: the
        // teammate keeps it, pressed or automatic.
        if let watched, let hold = await environmentHold(of: watched) { throw TakeError.held(hold) }
        // Read before the claim, so a stale row writes nothing, and again under the lease: another
        // Mac may take or start the move while the claim is pushed.
        let me = try await takeable(repo: repo, number: number, from: owner, branch: branch).me
        let item = "pr-\(number)"
        let leases = try await dispatcher(me: me, config: config).leases
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
        let wrote: String
        do {
            let fresh = try await takeable(repo: repo, number: number, from: owner, branch: branch)
            // A claim pushed, or reads made, while the Mac slept can leave the lease expired by now:
            // it must outlast the assign too.
            guard held.isLive(at: .now + 60) else { throw TakeError.busy }
            if fresh.kind == "reviewer" {
                try await github.requestReview(me, replacing: fresh.pr.requestedReviewers, repo: repo, number: number)
            } else {
                try await github.assign(me, replacing: fresh.pr.assignees, repo: repo, number: number)
            }
            taken = fresh.move
            wrote = fresh.kind == "reviewer" ? "requested review from" : "assigned"
        } catch {
            await release()
            throw error
        }
        await release()
        runNext(repo: repo, item: item, pressed: pressed)
        log("\(repo)#\(number): took \(taken.name) from \(owner ?? "nobody"), \(wrote) \(me)")
        return taken
    }

    /// The open PR, its move once taken, the field that owns it and my login, while the PR's move
    /// still has the owner the row showed and is one I can take.
    private func takeable(repo: String, number: Int, from owner: String?,
                          branch: String?) async throws -> (me: String, pr: PullRequest, move: Move, kind: String) {
        let flow = Flow.load(try await github.flowFile(repo: repo, branch: branch)).flow
        let read = try await github.openPullRequests(repo: repo)
        guard let flow, let pr = read.pullRequests.first(where: { $0.number == number }),
              let current = FlowEngine.move(for: pr, flow: flow),
              current.owner?.lowercased() == owner?.lowercased(),
              let taken = FlowEngine.takeover(of: pr, flow: flow, me: read.viewer),
              let kind = FlowEngine.ownerKind(for: pr, flow: flow)
        else { throw TakeError.changed }
        return (read.viewer, pr, taken, kind)
    }
}

extension Engine {
    /// Give to: hands a PR of mine to `login`, one of the flow's reviewers, by making them the PR's
    /// only assignee (an `assignee` move) or only requested reviewer (a `reviewer` move) on GitHub,
    /// under its lease. No comment: the assignment is the message. Checked against a fresh read.
    public func give(repo: String, number: Int, to login: String) async throws {
        let config = try BtonConfig.loadOrCreate(home: home)
        let branch = config.repos.first { $0.slug.caseInsensitiveCompare(repo) == .orderedSame }?.branch
        let me = try await givable(repo: repo, number: number, to: login, branch: branch).me
        let leases = try await dispatcher(me: me, config: config).leases
        guard let lease = LeaseItem("pr-\(number)"), case let .claimed(held)? = try? await leases.claim(lease, in: repo)
        else { throw TakeError.busy }
        let release = { [log] in
            for attempt in 1...2 {
                do {
                    return try await leases.release(held, ran: false)
                } catch where attempt == 2 {
                    log("\(repo)#\(number): Give to could not release the PR's lease, which frees when it expires: \(error.localizedDescription)")
                } catch {}
            }
        }
        do {
            let fresh = try await givable(repo: repo, number: number, to: login, branch: branch)
            guard held.isLive(at: .now + 60) else { throw TakeError.busy }
            if fresh.kind == "reviewer" {
                try await github.requestReview(login, replacing: fresh.pr.requestedReviewers, repo: repo, number: number)
            } else {
                try await github.assign(login, replacing: fresh.pr.assignees, repo: repo, number: number)
            }
        } catch {
            await release()
            throw error
        }
        await release()
        log("\(repo)#\(number): gave the review to \(login)")
    }

    /// The open PR, the field that owns its move and my login, while `login` is still one it can go to.
    private func givable(repo: String, number: Int, to login: String,
                         branch: String?) async throws -> (me: String, pr: PullRequest, kind: String) {
        let flow = Flow.load(try await github.flowFile(repo: repo, branch: branch)).flow
        let read = try await github.openPullRequests(repo: repo)
        guard let flow, let pr = read.pullRequests.first(where: { $0.number == number }),
              FlowEngine.giveTargets(for: pr, flow: flow, me: read.viewer).contains(where: { $0.caseInsensitiveCompare(login) == .orderedSame }),
              let kind = FlowEngine.ownerKind(for: pr, flow: flow)
        else { throw TakeError.changed }
        return (read.viewer, pr, kind)
    }
}

extension Engine {
    /// At most this many PRs are taken per sync: a flow change must not reassign a whole queue at once.
    static let autoTakeLimit = 2

    /// The PRs whose move Take it could take, not yet tried at their owner, move and head.
    static func autoTakeable(_ pullRequests: [PullRequest], flow: Flow, me: String, repo: String, tried: Set<String>) -> [PullRequest] {
        pullRequests.filter { pr in
            FlowEngine.takeover(of: pr, flow: flow, me: me) != nil && !tried.contains(autoTakeKey(pr, repo: repo))
        }
    }

    /// Per PR, owner, move and head: a review taken at a head must not spend the merge that
    /// follows the approval at the same head, from the same rotation pick.
    static func autoTakeKey(_ pr: PullRequest, repo: String) -> String {
        "\(pick(repo: repo, item: "pr-\(pr.number)"))@\(pr.move?.owner?.lowercased() ?? "")@\(pr.move?.name ?? "")@\(pr.headSha)"
    }

    /// Takes the teammates' moves a repo with `takeMoves` leaves waiting; a refusal (changed, busy)
    /// is logged and not retried on this owner, move and head. A service of the repo that stopped
    /// answering since the sync's probe stops the takes and is returned, so the sync holds the
    /// repo's jobs too; the PR is tried again once the service is back.
    func autoTake(_ pullRequests: [PullRequest], flow: Flow, repo: String, me: String) async -> String? {
        for pr in Self.autoTakeable(pullRequests, flow: flow, me: me, repo: repo, tried: autoTaken).prefix(Self.autoTakeLimit) {
            let key = Self.autoTakeKey(pr, repo: repo)
            autoTaken.insert(key)
            do {
                _ = try await take(repo: repo, number: pr.number, from: pr.move?.owner, pressed: false)
            } catch let TakeError.held(hold) {
                autoTaken.remove(key)
                return hold
            } catch {
                log("\(repo)#\(pr.number): automatic Take it stopped: \(error.localizedDescription)")
            }
        }
        return nil
    }
}
