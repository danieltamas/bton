import Foundation

/// The "Star on GitHub" offer in the panel footer. It asks GitHub once whether the owner's `gh`
/// account has starred Bton, remembers a yes in `config.json` (`starredRepo`) and never asks
/// again. Starring is the owner's own click through their own logged-in `gh`: nothing goes
/// anywhere else and nothing is logged.
public struct RepoStar: Sendable {
    public enum Standing: Equatable, Sendable { case starred, notStarred, unknown }

    /// Runs `gh` with arguments; its exit status and standard output.
    public typealias GH = @Sendable ([String]) async -> (status: Int32, output: String)

    public static let repo = "danieltamas/bton"

    private let home: BtonHome
    private let gh: GH

    public init(home: BtonHome, gh: @escaping GH = RepoStar.realGH) {
        self.home = home
        self.gh = gh
    }

    /// Whether the footer offers the star, from disk alone: no config yet offers; a config that
    /// cannot be read does not (the app cannot run on it either).
    public func shouldOffer() -> Bool {
        guard FileManager.default.fileExists(atPath: home.configURL.path) else { return true }
        guard let data = try? Data(contentsOf: home.configURL),
              let config = try? JSONDecoder().decode(BtonConfig.self, from: data) else { return false }
        return config.starredRepo != true
    }

    /// Asks GitHub once; a yes is remembered. No `gh`, no login or no answer is `unknown`, and
    /// nothing is offered then.
    public func refresh() async -> Standing {
        guard shouldOffer() else { return .starred }
        let answer = await gh(["api", "-i", "user/starred/\(Self.repo)"])
        switch Self.httpStatus(answer.output) {
        case 204:
            await remember()
            return .starred
        case 404: return .notStarred
        default: return .unknown
        }
    }

    /// Stars Bton for the owner's `gh` account. True when GitHub said so (204), and then it is remembered.
    public func star() async -> Bool {
        let answer = await gh(["api", "-i", "-X", "PUT", "user/starred/\(Self.repo)"])
        guard Self.httpStatus(answer.output) == 204 else { return false }
        await remember()
        return true
    }

    /// The flag into the config on disk, through the config's own atomic writer, keeping the rest.
    /// On the main actor, where the app's own settings writes run, so neither loses the other's change.
    @MainActor private func remember() {
        guard var config = try? BtonConfig.loadOrCreate(home: home) else { return }
        config.starredRepo = true
        try? config.save(to: home.configURL)
    }

    /// The status of `gh api -i`'s first line, `HTTP/2.0 204 No Content`.
    static func httpStatus(_ output: String) -> Int? {
        guard let line = output.split(whereSeparator: \.isNewline).first, line.hasPrefix("HTTP/") else { return nil }
        return line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
    }

    /// `gh` where the app finds every program (a menu bar app has a thin PATH), 30 s at most.
    public static let realGH: GH = { arguments in
        guard let gh = Executables.resolve("gh") else { return (127, "") }
        guard let output = try? await ProcessRunner().run(gh, arguments, environment: ["PATH": Executables.searchPath(for: gh)],
                                                          timeout: .seconds(30)) else { return (1, "") }
        return (output.status, String(decoding: output.stdout, as: UTF8.self))
    }
}
