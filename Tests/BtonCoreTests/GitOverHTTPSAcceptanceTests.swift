@testable import BtonCore
import Foundation
import Testing

/// Every command a job runs, a check or a flow's command, reaches GitHub the way its agents do:
/// over HTTPS with gh's credential and no terminal prompt. An SSH remote inside a job has no
/// agent to approve the owner's key, so the fetch fails unattended.
@Suite(ProcessBound())
struct GitOverHTTPSAcceptanceTests {
    /// Git without the owner's own configuration, so only what Bton put in the environment shows.
    private static let git = "GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 /usr/bin/git"
    private static let probe = "echo \"instead-of=$(\(git) config --get-all url.https://github.com/.insteadOf | tr '\\n' ' ')\"; "
        + "echo \"helper=$(\(git) config --get-all credential.https://github.com.helper | tail -1)\"; echo \"prompt=$GIT_TERMINAL_PROMPT\""

    @Test func aCheckAndACommandCarryTheHTTPSGitConfiguration() async throws {
        let f = try await CheckTimeFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.start(checks: [["/bin/sh", "-c", Self.probe]], timeout: .seconds(30),
                                   command: ["/bin/sh", "-c", Self.probe + "; touch \"$ACTION_FILE\""])
        let ended = try await f.finished(id)
        #expect(ended.status == .succeeded)
        let lines = f.log(id).components(separatedBy: "\n")
        // Once from the check and once from the command.
        #expect(lines.filter { $0 == "instead-of=git@github.com: ssh://git@github.com/ " }.count == 2)
        #expect(lines.filter { $0 == "helper=!'\(f.root.appendingPathComponent("gh").path)' auth git-credential" }.count == 2)
        #expect(lines.filter { $0 == "prompt=0" }.count == 2)
    }

    /// Git runs the helper through a shell: a gh installed under a path with a space (or a quote)
    /// still answers a credential request.
    @Test func theHelperRunsFromAPathWithASpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton https 'dir' \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gh = root.appendingPathComponent("gh")
        try "#!/bin/sh\n[ \"$1 $2\" = \"auth git-credential\" ] && printf 'username=octo\\npassword=STUB_TOKEN_DATA\\n'\n"
            .write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let environment = Dispatcher.gitOverHTTPS(ghPath: gh.path)
            .merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]) { $1 }
        let filled = try await ProcessRunner().run("/bin/sh", ["-c", "printf 'protocol=https\\nhost=github.com\\n' | /usr/bin/git credential fill"],
                                                   in: root, environment: environment, timeout: .seconds(20))
        #expect(filled.status == 0, Comment(rawValue: filled.stderr))
        #expect(String(decoding: filled.stdout, as: UTF8.self).contains("password=STUB_TOKEN_DATA"))
    }

    /// A repo's environment cannot take these variables over: it is refused as invalid, the way
    /// every variable Bton sets is, so a job never fetches over SSH by configuration either.
    @Test func aRepoEnvironmentCannotSetThemBack() async throws {
        let f = try await CheckTimeFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.start(checks: [], timeout: .seconds(30), environment: ["GIT_CONFIG_COUNT": "0"])
        let ended = try await f.finished(id)
        #expect(ended.status == .failed)
        #expect(ended.detail?.contains("GIT_CONFIG_COUNT is set by Bton") == true)
    }
}
