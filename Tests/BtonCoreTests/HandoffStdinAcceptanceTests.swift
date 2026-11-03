@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct HandoffStdinAcceptanceTests {
    @Test func handoffPostsExactArgvAndBodyOnStdinWithoutLeavingATemporaryFile() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("handoff-stdin-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let before = Set(try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)
            .filter { $0.hasPrefix("bton-handoff-") })
        let gh = root.appendingPathComponent("gh")
        try """
        #!/bin/sh
        case "$1 $2" in
          'api user') printf 'sender';;
          'issue view') printf '{"comments":[]}';;
          'issue comment')
            printf '%s\\n' "$@" > "${0%/*}/argv"
            cat > "${0%/*}/stdin";;
          *) exit 17;;
        esac
        """.write(to: gh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let posted = try await GitHubClient(ghPath: gh.path).handOff(to: "teammate",
            text: "Read the plan.\nQuotes ' and $ stay data.", repo: "synthetic/project", issue: 7)
        #expect(posted)
        #expect(try String(contentsOf: root.appendingPathComponent("argv"), encoding: .utf8)
            == "issue\ncomment\n7\n--repo\nsynthetic/project\n--body-file\n-\n")
        #expect(try String(contentsOf: root.appendingPathComponent("stdin"), encoding: .utf8)
            == "@teammate\n\nRead the plan.\nQuotes ' and $ stay data.\n\n<!-- bton:handoff to=teammate -->")
        let after = Set(try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)
            .filter { $0.hasPrefix("bton-handoff-") })
        #expect(after.subtracting(before).isEmpty)
    }
}
