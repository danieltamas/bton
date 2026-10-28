import Foundation
import os

/// The services a repo's environment names on this Mac (a test database, a Redis) are asked
/// for a TCP connect before the repo's jobs start: a check that runs an hour against a dead
/// database and then fails with "check ..." tells the owner nothing, while "nothing answers
/// at 127.0.0.1:55439" within seconds does. The three real signals fail closed: refused,
/// timed out, unresolvable. A probe that cannot even make a socket counts as reachable, with
/// the reason in `connects`.
public enum EnvironmentProbe {
    public struct Endpoint: Hashable, Sendable {
        public let key: String
        public let host: String
        public let port: Int
    }

    /// Longer than a service on this Mac ever takes to accept, shorter than a tick.
    public static let timeout: Duration = .seconds(2)

    /// The values that are URLs with a scheme, a host and an explicit port, by key. The user
    /// info of a URL never leaves it: an endpoint carries the host and port only.
    public static func endpoints(in environment: [String: String]) -> [Endpoint] {
        environment.sorted { $0.key < $1.key }.compactMap { key, value in
            guard !value.contains("\0"), let url = URL(string: value), url.scheme != nil,
                  let host = url.host(percentEncoded: false), !host.isEmpty,
                  let port = url.port, (1...65535).contains(port) else { return nil }
            return Endpoint(key: key, host: host, port: port)
        }
    }

    /// The endpoints nothing accepts a connect for within `timeout`, by key; all probed at once.
    public static func unreachable(_ endpoints: [Endpoint], timeout: Duration = timeout) async -> [Endpoint] {
        await withTaskGroup(of: Endpoint?.self) { group in
            for endpoint in endpoints {
                group.addTask { await answers(endpoint, within: timeout) ? nil : endpoint }
            }
            var down: [Endpoint] = []
            for await endpoint in group { if let endpoint { down.append(endpoint) } }
            return down.sorted { $0.key < $1.key }
        }
    }

    /// Why a repo's jobs wait, from the first endpoint by key; nil when every one answers.
    public static func hold(_ down: [Endpoint]) -> String? {
        guard let first = down.min(by: { $0.key < $1.key }) else { return nil }
        let who = down.count > 1 ? "\(first.key) and \(down.count - 1) more" : first.key
        // Foundation hands an IPv6 literal over bare; it reads as an address again in brackets.
        let host = first.host.contains(":") ? "[\(first.host)]" : first.host
        return "\(who): nothing answers at \(host):\(first.port); start the service (Docker?) and Bton goes on"
    }

    /// Whether anything accepts a TCP connect at the endpoint before the clock runs out. The
    /// blocking calls (name resolution, the connect's poll) run off the actor; the first answer
    /// settles it, the deadline or the probe, so a resolve that outlasts the timeout is an
    /// unreachable endpoint, never a stalled tick: the late answer finds nothing to resume.
    static func answers(_ endpoint: Endpoint, within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        let host = endpoint.host, port = endpoint.port
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: nil)
        let settle: @Sendable (Bool) -> Void = { answer in
            pending.withLock { let waiting = $0; $0 = nil; return waiting }?.resume(returning: answer)
        }
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            Task.detached(priority: .utility) { settle(connects(host: host, port: port, deadline: deadline)) }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                settle(false)
            }
        }
    }

    /// A non-blocking connect to each address of the host, each polled for its share of what
    /// is left of the deadline, so one address that swallows packets leaves the next its turn.
    static func connects(host: String, port: Int, deadline: ContinuousClock.Instant) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return false }
        defer { freeaddrinfo(list) }
        var next: UnsafeMutablePointer<addrinfo>? = list
        var left = sequence(first: list) { $0.pointee.ai_next }.reduce(0) { count, _ in count + 1 }
        var probed = false
        while let info = next {
            next = info.pointee.ai_next
            defer { left -= 1 }
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            probed = true
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return true }
            guard errno == EINPROGRESS else { continue }
            let remaining = deadline - ContinuousClock.now
            let milliseconds = (remaining.components.seconds * 1_000 + remaining.components.attoseconds / 1_000_000_000_000_000) / Int64(left)
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(clamping: max(0, milliseconds))) > 0 else { continue }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 { return true }
        }
        // No socket at all is this Mac's limit (descriptors run out), not the service's answer:
        // a Bton defect must not hold every repo.
        return !probed
    }
}
