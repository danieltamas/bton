import BtonCore
import Foundation
import Testing

// Expected values come from docs/PLAN.md, U11 - About.
struct AboutAcceptanceTests {
    @Test func buildRecognizesEveryDocumentedSourceForm() {
        let rows: [(String?, String, Int, String?, Bool)] = [
            (nil, "9.8.7", 0, nil, false),
            ("", "9.8.7", 0, nil, false),
            ("v0.3.0", "0.3.0", 0, nil, false),
            ("v0.3.0-dirty", "0.3.0", 0, nil, true),
            ("v0.3.0-2-g733f8b4", "0.3.0", 2, "733f8b4", false),
            ("v0.3.0-2-g733f8b4-dirty", "0.3.0", 2, "733f8b4", true),
            ("733f8b4", "9.8.7", 0, "733f8b4", false),
            ("733f8b4-dirty", "9.8.7", 0, "733f8b4", true),
        ]
        for (source, version, commitsAfter, commit, dirty) in rows {
            let actual = BtonRelease.build(version: "9.8.7", source: source)
            #expect(actual == BtonRelease.Build(version: version, commitsAfter: commitsAfter,
                                                commit: commit, dirty: dirty))
        }
    }

    @Test func compareUsesNumericComponentsAndOptionalVPrefixes() {
        let rows: [(String, String, ComparisonResult)] = [
            ("0.0.0", "0.0.0", .orderedSame),
            ("v0.3.0", "0.3.0", .orderedSame),
            ("0.3.0", "v0.3.0", .orderedSame),
            ("v0.3.0", "v0.3.0", .orderedSame),
            ("0.10.0", "0.9.9", .orderedDescending),
            ("0.9.9", "0.10.0", .orderedAscending),
            ("10.0.0", "9.99.99", .orderedDescending),
            ("1.2.10", "1.2.9", .orderedDescending),
            ("1.2.3", "1.2.4", .orderedAscending),
            ("1.99.99", "2.0.0", .orderedAscending),
        ]
        for (left, right, expected) in rows {
            #expect(BtonRelease.compare(left, right) == expected)
        }
    }

    @Test func compareRejectsInvalidInputOnEitherSide() {
        let invalid = ["", "v", "1", "1.2", "1.2.3.4", ".2.3", "1..3", "1.2.",
                       "-1.2.3", "1.-2.3", "1.2.-3", "one.2.3", "1.two.3", "1.2.three",
                       "1.2.3-beta", "vv1.2.3"]
        for version in invalid {
            #expect(BtonRelease.compare(version, "1.2.3") == nil)
            #expect(BtonRelease.compare("1.2.3", version) == nil)
            #expect(BtonRelease.compare(version, version) == nil)
        }
    }

    @Test func standingFollowsVersionThenCheckoutState() {
        // All four checkout states matter even when the versions differ or cannot parse.
        let versions: [(String, String, BtonRelease.Standing)] = [
            ("0.9.9", "v0.10.0", .behind(latest: "v0.10.0")),
            ("0.9.9", "0.10.0", .behind(latest: "0.10.0")),
            ("0.10.0", "v0.9.9", .ahead),
            ("invalid", "v0.3.0", .unknown),
            ("0.3.0", "invalid", .unknown),
            ("invalid", "invalid", .unknown),
        ]
        for commitsAfter in [0, 2] {
            for dirty in [false, true] {
                for (version, tag, expected) in versions {
                    let build = BtonRelease.Build(version: version, commitsAfter: commitsAfter,
                                                 commit: "733f8b4", dirty: dirty)
                    #expect(BtonRelease.standing(of: build, latestTag: tag) == expected)
                }
                let equal = BtonRelease.Build(version: "0.3.0", commitsAfter: commitsAfter,
                                             commit: nil, dirty: dirty)
                let expected: BtonRelease.Standing = commitsAfter == 0 && !dirty ? .latest : .ahead
                #expect(BtonRelease.standing(of: equal, latestTag: "v0.3.0") == expected)
            }
        }
    }

    @Test func decodeLatestReleaseReadsCapturedGitHubObject() throws {
        // Captured gh api repos/danieltamas/bton/releases/latest: scratchpad/latest-release.json.
        // Retained fields verbatim; omitted author, assets, body and other unrelated fields.
        let fixture = Data(#"""
        {
          "url": "https://api.github.com/repos/danieltamas/bton/releases/420506313",
          "html_url": "https://github.com/danieltamas/bton/releases/tag/v0.3.0",
          "id": 420506313,
          "tag_name": "v0.3.0",
          "target_commitish": "main",
          "name": "v0.3.0",
          "draft": false,
          "prerelease": false
        }
        """#.utf8)
        #expect(try GitHubClient.decodeLatestRelease(fixture) == "v0.3.0")
    }
}
