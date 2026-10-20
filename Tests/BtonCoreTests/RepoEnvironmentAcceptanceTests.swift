@testable import BtonCore
import Foundation
import Testing

struct RepoEnvironmentAcceptanceTests {
    @Test func legacyRepoConfigDecodesWithoutEnvironment() throws {
        let data = Data(#"{"pollSeconds":30,"maxAgents":1,"agents":{},"schedules":[],"repos":[{"slug":"synthetic/project","path":"/tmp/synthetic","branch":"main"}]}"#.utf8)
        let config = try JSONDecoder().decode(BtonConfig.self, from: data)
        let repo = try #require(config.repos.first)
        #expect(repo.environment == nil)
        #expect(WatchedRepo(slug: "synthetic/project", path: nil, branch: "main").environment == nil)
    }

    @Test func repoEnvironmentSurvivesConfigRoundTrip() throws {
        let environment = ["DATABASE_URL": "postgres://test:test@127.0.0.1:5999/app", "EMPTY": ""]
        var config = BtonConfig.initial
        config.repos = [WatchedRepo(slug: "synthetic/project", path: "/tmp/synthetic",
                                   branch: "develop", environment: environment)]
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let repos = try #require(json["repos"] as? [[String: Any]])
        #expect(repos.first?["environment"] as? [String: String] == environment)
        let decoded = try JSONDecoder().decode(BtonConfig.self, from: data)
        #expect(decoded.repos == config.repos)
        #expect(decoded.repos.first?.environment == environment)
    }

    @Test func environmentParserPreservesValuesAndIgnoresComments() throws {
        let text = "\n  # ignored=comment\r\n \t \n  DATABASE_URL =postgres://test:test@127.0.0.1:5999/app\r\nTOKEN=a=b==\nSPACES=  inner spaces  \r\nEMPTY=\nHASH=# literal\nQUOTED=\"literal\"\nCR=left\rright\r\n"
        #expect(try WatchedRepo.parseEnvironment(text) == [
            "DATABASE_URL": "postgres://test:test@127.0.0.1:5999/app",
            "TOKEN": "a=b==", "SPACES": "  inner spaces  ", "EMPTY": "",
            "HASH": "# literal", "QUOTED": "\"literal\"", "CR": "left\rright",
        ])
        #expect(try WatchedRepo.parseEnvironment("\n  # comment\n\r\n") == [:])
    }

    @Test func environmentNamesAcceptBoundariesAndCaseSensitiveExceptions() throws {
        let longest = String(repeating: "A", count: 100)
        let environment = [longest: "test", "_": "", "aZ_09": "test", "path": "test",
                           "Home": "test", "bton_LOCAL": "test", "git_LOCAL": "test"]
        #expect(try WatchedRepo.parseEnvironment(WatchedRepo.environmentText(environment)) == environment)
        #expect(WatchedRepo.environmentProblem(environment) == nil)
    }

    @Test(arguments: [
        "9INVALID", "BAD-NAME", "BAD NAME", "BAD.NAME", "ÅNAME",
        String(repeating: "A", count: 101), "PATH", "HOME", "MCP_TOOL_TIMEOUT",
        "BTON_", "BTON_LOCAL", "GIT_", "GIT_CONFIG_COUNT",
    ])
    func invalidEnvironmentNamesAreRejectedNamingTheKey(_ key: String) {
        do {
            _ = try WatchedRepo.parseEnvironment("\(key)=test")
            Issue.record("Invalid or reserved environment name must throw: \(key)")
        } catch {
            #expect(error.localizedDescription.contains(key))
        }
        let problem = WatchedRepo.environmentProblem([key: "test"])
        #expect(problem?.contains(key) == true)
    }

    @Test(arguments: ["MISSING_EQUALS", "=test", "   =test"])
    func malformedEnvironmentLinesAreRejectedNamingTheLine(_ line: String) {
        do {
            _ = try WatchedRepo.parseEnvironment("VALID=test\n\(line)")
            Issue.record("Malformed environment line must throw")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains(line) || message.contains("2"))
        }
    }

    @Test func duplicateEnvironmentKeysAreRejectedAfterTrimming() {
        do {
            _ = try WatchedRepo.parseEnvironment("DATABASE_URL=first\n DATABASE_URL =second")
            Issue.record("Duplicate environment keys must throw")
        } catch {
            #expect(error.localizedDescription.contains("DATABASE_URL"))
        }
    }

    @Test func nulEnvironmentValuesAreRejectedNamingTheKey() {
        let environment = ["DATABASE_URL": "test\0value"]
        do {
            _ = try WatchedRepo.parseEnvironment("DATABASE_URL=test\0value")
            Issue.record("A NUL in an environment value must throw")
        } catch {
            #expect(error.localizedDescription.contains("DATABASE_URL"))
        }
        #expect(WatchedRepo.environmentProblem(environment)?.contains("DATABASE_URL") == true)
        #expect(WatchedRepo.environmentProblem(["": "test"]) != nil)
    }

    @Test func environmentTextIsSortedAndRoundTripsVerbatim() throws {
        let environment = ["Z_LAST": "a=b  ", "A_FIRST": "", "MIDDLE": "  test # literal"]
        let text = WatchedRepo.environmentText(environment)
        #expect(text == "A_FIRST=\nMIDDLE=  test # literal\nZ_LAST=a=b  ")
        #expect(try WatchedRepo.parseEnvironment(text) == environment)
        #expect(WatchedRepo.environmentText([:]) == "")
        #expect(WatchedRepo.environmentProblem([:]) == nil)
        #expect(WatchedRepo.environmentProblem(environment) == nil)
    }

    @Test func processEnvironmentKeepsRepoValuesAndBtonWinsEveryClash() {
        let repo = ["DATABASE_URL": "postgres://test:test@127.0.0.1:5999/app", "EMPTY": "",
                    "PATH": "/evil", "HOME": "/tmp/repo", "BTON_JOB": "repo",
                    "SHARED": "repo", "LITERAL": "  a=b  "]
        let bton = ["PATH": "/usr/bin:/bin", "HOME": "/tmp/synthetic-home",
                    "BTON_JOB": "synthetic-job", "SHARED": "bton", "MCP_TOOL_TIMEOUT": "1000"]
        #expect(DispatchPlanner.processEnvironment(repo: repo, bton: bton) == [
            "DATABASE_URL": "postgres://test:test@127.0.0.1:5999/app", "EMPTY": "",
            "PATH": "/usr/bin:/bin", "HOME": "/tmp/synthetic-home", "BTON_JOB": "synthetic-job",
            "SHARED": "bton", "LITERAL": "  a=b  ", "MCP_TOOL_TIMEOUT": "1000",
        ])
        #expect(DispatchPlanner.processEnvironment(repo: repo, bton: [:]) == repo)
        #expect(DispatchPlanner.processEnvironment(repo: [:], bton: bton) == bton)
        #expect(DispatchPlanner.processEnvironment(repo: [:], bton: [:]) == [:])
        #expect(DispatchPlanner.processEnvironment(repo: ["SHARED": "repo"], bton: ["SHARED": ""])
                == ["SHARED": ""])
    }
}
