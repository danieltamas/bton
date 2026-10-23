import Testing
@testable import BtonCore

// Pure acceptance contracts: no installer execution, filesystem access, or network.
struct UpdateAcceptanceTests {
    private static let invalidTags = [
        "", "v", "v0.5", "v0.5.1.2", "v0.5.1-rc1", " v0.5.1", "v0.5.1\n",
        "v0.5.x", "v0.5.1;rm -rf ~", "v\u{0660}.5.1", "vv0.5.1",
        "0..1", ".5.1", "0.5.", "-0.5.1", "+0.5.1", "V0.5.1",
        "0.5.1 ", "0.5.1\r\n", "0.5.1\u{0000}", "0.5.1+build",
    ]

    @Test func installedPathIsTheCanonicalApplication() {
        #expect(BtonRelease.installedPath == "/Applications/Bton.app")
    }

    @Test func updateVersionAcceptsOnlyCompleteASCIIVersions() {
        let rows = [
            ("v0.5.1", "0.5.1"), ("0.5.1", "0.5.1"), ("v0.0.0", "0.0.0"),
            ("12.345.6789", "12.345.6789"), ("v000.05.001", "000.05.001"),
            ("999999999999999999999999999999.5.1", "999999999999999999999999999999.5.1"),
        ]
        for (tag, expected) in rows {
            #expect(BtonRelease.updateVersion(latestTag: tag) == expected)
        }
        for tag in Self.invalidTags {
            #expect(BtonRelease.updateVersion(latestTag: tag) == nil)
        }
    }

    @Test func canUpdateRequiresInstalledLocationAndValidBehindStanding() {
        let paths: [(String, Bool)] = [
            ("/Applications/Bton.app", true), ("/Applications/Bton.app/", true),
            ("/tmp/build/Bton.app", false), ("/Applications/Bton copy.app", false),
            ("/Applications/Bton.app.old", false), ("/Users/x/Applications/Bton.app", false),
            ("", false), ("Applications/Bton.app", false),
            ("/Applications/Bton.app/Contents", false),
        ]
        let standings: [(BtonRelease.Standing, Bool)] = [
            (.behind(latest: "v0.5.1"), true), (.behind(latest: "0.5.1"), true),
            (.latest, false), (.ahead, false), (.unknown, false),
        ] + Self.invalidTags.map { (.behind(latest: $0), false) }
        for (path, installed) in paths {
            for (standing, validBehind) in standings {
                #expect(BtonRelease.canUpdate(bundlePath: path, standing: standing) == (installed && validBehind))
            }
        }
    }

    @Test func updateRunPinsVersionAndPassesInstallerAsOneLiteralArgument() throws {
        let installers = [
            "/Applications/Bton.app/Contents/Resources/install.sh",
            "/Applications/Bton copy.app/Contents/Resources/install.sh",
            "/tmp/installer; echo injected $(whoami) 'quoted' \"double\".sh",
        ]
        let tags = [("v0.5.1", "0.5.1"), ("0.5.1", "0.5.1"), ("v01.02.003", "01.02.003")]
        for installer in installers {
            for (tag, version) in tags {
                for path in ["/usr/bin:/bin:/opt/homebrew/bin", "", "/tmp/path with spaces:$HOME"] {
                    let run = try #require(BtonRelease.updateRun(installer: installer, latestTag: tag, searchPath: path))
                    let expected = BtonRelease.UpdateRun(
                        executable: "/bin/bash", arguments: [installer],
                        environment: ["BTON_VERSION": version, "PATH": path]
                    )
                    #expect(run == expected)
                    #expect(run.executable == "/bin/bash")
                    #expect(run.arguments == [installer])
                    #expect(run.environment == ["BTON_VERSION": version, "PATH": path])
                }
            }
        }
    }

    @Test func updateRunRejectsUntrustedTagsAndRelativeInstallerPaths() {
        for tag in Self.invalidTags {
            #expect(BtonRelease.updateRun(installer: "/synthetic/install.sh", latestTag: tag, searchPath: "/bin") == nil)
        }
        for installer in ["", "install.sh", "./install.sh", "../install.sh", "~/install.sh", "file:///tmp/install.sh", " /tmp/install.sh"] {
            #expect(BtonRelease.updateRun(installer: installer, latestTag: "v0.5.1", searchPath: "/bin") == nil)
        }
    }

    @Test func updateFailureSelectsAndSanitizesLastNonemptyLine() {
        let rows = [
            ("downloading\nbton: checksum mismatch\n\n", "checksum mismatch"),
            ("first\n  final error  \n \t\n", "final error"),
            ("first\r\n bton: download failed \r\n", "download failed"),
            ("\u{001B}[31mbton: checksum mismatch\u{001B}[0m\n", "checksum mismatch"),
            ("\u{001B}[2K\u{001B}[1;31mbton: failed\u{001B}[0m", "failed"),
            ("bton: bad\u{0000}\u{0007}\u{007F}\u{0080}\u{200B}\u{202E}\u{2066}checksum", "badchecksum"),
            ("bton: cannot open Bton.app", "cannot open Bton.app"),
            ("message mentions bton: failure", "message mentions bton: failure"),
            ("bton: bton: failed", "bton: failed"),
            ("bton: caf\u{00E9} failed", "caf\u{00E9} failed"),
        ]
        for (log, expected) in rows {
            #expect(BtonRelease.updateFailure(log: log) == expected)
        }
    }

    @Test func updateFailureFallsBackWhenNoMessageRemains() {
        for log in ["", "\n\r\n", " \t\n  ", "\u{001B}[31m\u{001B}[0m", "\u{0000}\u{0007}\u{200B}", "bton: "] {
            #expect(BtonRelease.updateFailure(log: log) == "the installer stopped without saying why")
        }
    }

    @Test func updateFailureLimitsSanitizedMessageTo200Characters() {
        for character in ["x", "\u{00E9}", "\u{1F680}"] {
            for length in [199, 200, 201, 500] {
                let message = String(repeating: character, count: length)
                let result = BtonRelease.updateFailure(log: "progress\n\u{001B}[31mbton: \(message)\u{001B}[0m\n")
                #expect(result == String(repeating: character, count: min(length, 200)))
                #expect(result.count <= 200)
            }
        }
    }
}
