import Foundation
import Testing
@testable import BtonCore

private actor RepoStarGH {
    private var arguments: [[String]] = []
    private let status: Int32
    private let output: String

    init(status: Int32 = 0, output: String) {
        self.status = status
        self.output = output
    }

    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        self.arguments.append(arguments)
        return (status, output)
    }

    func calls() -> [[String]] { arguments }
}

private func repoStarRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-star-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

struct RepoStarAcceptanceTests {
    @Test func freshHomeOffersAnd404DoesNotCreateConfig() async throws {
        let root = try repoStarRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let gh = RepoStarGH(status: 1, output: "HTTP/2.0 404 Not Found")
        let star = RepoStar(home: home, gh: { await gh.run($0) })

        #expect(star.shouldOffer())
        #expect(!FileManager.default.fileExists(atPath: home.configURL.path))
        let before = await gh.calls()
        #expect(before.isEmpty)
        let standing = await star.refresh()
        #expect(standing == .notStarred)
        #expect(star.shouldOffer())
        #expect(!FileManager.default.fileExists(atPath: home.configURL.path))
        let calls = await gh.calls()
        #expect(calls == [["api", "-i", "user/starred/danieltamas/bton"]])
    }

    @Test func refreshRemembersStarAcrossInstancesAndPreservesConfig() async throws {
        let root = try repoStarRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        var config = BtonConfig.initial
        config.pollSeconds = 123
        try config.save(to: home.configURL)
        let gh = RepoStarGH(output: "HTTP/2.0 204 No Content")
        let star = RepoStar(home: home, gh: { await gh.run($0) })

        let first = await star.refresh()
        #expect(first == .starred)
        #expect(!star.shouldOffer())
        let second = await star.refresh()
        #expect(second == .starred)
        let calls = await gh.calls()
        #expect(calls.count == 1)
        let otherGH = RepoStarGH(status: 1, output: "HTTP/2.0 404 Not Found")
        let reopened = RepoStar(home: home, gh: { await otherGH.run($0) })
        #expect(!reopened.shouldOffer())
        let reopenedStanding = await reopened.refresh()
        #expect(reopenedStanding == .starred)
        let otherCalls = await otherGH.calls()
        #expect(otherCalls.isEmpty)
        let saved = try JSONDecoder().decode(BtonConfig.self, from: Data(contentsOf: home.configURL))
        #expect(saved.starredRepo == true)
        #expect(saved.pollSeconds == 123)
    }

    @Test(arguments: [
        (Int32(0), ""),
        (Int32(0), "HTTP/2.0 500 Internal Server Error"),
        (Int32(127), "")
    ])
    func unknownAnswersAreRetried(answer: (Int32, String)) async throws {
        let root = try repoStarRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let gh = RepoStarGH(status: answer.0, output: answer.1)
        let star = RepoStar(home: home, gh: { await gh.run($0) })

        let first = await star.refresh()
        #expect(first == .unknown)
        #expect(star.shouldOffer())
        #expect(!FileManager.default.fileExists(atPath: home.configURL.path))
        let second = await star.refresh()
        #expect(second == .unknown)
        #expect(star.shouldOffer())
        #expect(!FileManager.default.fileExists(atPath: home.configURL.path))
        let calls = await gh.calls()
        #expect(calls.count == 2)
    }

    @Test func starUsesPUTAndPersistsWithoutReplacingConfig() async throws {
        let root = try repoStarRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        var config = BtonConfig.initial
        config.pollSeconds = 123
        try config.save(to: home.configURL)
        let gh = RepoStarGH(output: "HTTP/2.0 204 No Content")
        let star = RepoStar(home: home, gh: { await gh.run($0) })

        let succeeded = await star.star()
        #expect(succeeded)
        let calls = await gh.calls()
        #expect(calls == [["api", "-i", "-X", "PUT", "user/starred/danieltamas/bton"]])
        #expect(!star.shouldOffer())
        let otherGH = RepoStarGH(status: 1, output: "HTTP/2.0 404 Not Found")
        let reopened = RepoStar(home: home, gh: { await otherGH.run($0) })
        #expect(!reopened.shouldOffer())
        let saved = try JSONDecoder().decode(BtonConfig.self, from: Data(contentsOf: home.configURL))
        #expect(saved.starredRepo == true)
        #expect(saved.pollSeconds == 123)
    }

    @Test(arguments: ["HTTP/2.0 403 Forbidden", ""])
    func failedStarDoesNotCreateConfig(output: String) async throws {
        let root = try repoStarRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let gh = RepoStarGH(status: 1, output: output)
        let star = RepoStar(home: home, gh: { await gh.run($0) })

        let succeeded = await star.star()
        #expect(!succeeded)
        #expect(star.shouldOffer())
        #expect(!FileManager.default.fileExists(atPath: home.configURL.path))
    }

    @Test func corruptConfigFailsClosedWithoutCallingGH() async throws {
        let root = try repoStarRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        try Data("not json".utf8).write(to: home.configURL)
        let gh = RepoStarGH(status: 1, output: "HTTP/2.0 404 Not Found")
        let star = RepoStar(home: home, gh: { await gh.run($0) })

        #expect(!star.shouldOffer())
        let standing = await star.refresh()
        #expect(standing == .starred)
        let calls = await gh.calls()
        #expect(calls.isEmpty)
    }

    @Test func httpStatusReadsHeadersAndRejectsMissingStatus() {
        #expect(RepoStar.httpStatus("HTTP/2.0 204 No Content") == 204)
        #expect(RepoStar.httpStatus("HTTP/1.1 404 Not Found\n{...}") == 404)
        #expect(RepoStar.httpStatus("") == nil)
        #expect(RepoStar.httpStatus("gh: not logged in") == nil)
        #expect(RepoStar.httpStatus("HTTP/2.0 204") == 204)
    }
}
