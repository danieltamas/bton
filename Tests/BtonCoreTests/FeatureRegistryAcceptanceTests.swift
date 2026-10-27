@testable import BtonCore
import Foundation
import Testing

// The registry example from spec 2a, shared by the five acceptance suites.
enum FeatureAcceptanceData {
    static let specExample = #"""
    {
      "version": 1,
      "areas": [
        { "id": "whatsapp-intake", "name": "WhatsApp intake", "paths": ["gateway/src/whatsapp/**"] }
      ],
      "features": [
        {
          "id": "filing-dedupe",
          "name": "Filing dedupe",
          "summary": "Skips a WhatsApp file already filed in the case.",
          "area": "whatsapp-intake",
          "parent": null,
          "paths": ["gateway/src/whatsapp/filing.ts", "gateway/src/whatsapp/intake-handler.ts"],
          "issues": [{ "number": 402, "why": "closes" }],
          "prs": [{ "number": 428, "why": "closes" }, { "number": 419, "why": "files" }],
          "firstSeen": "2026-10-03",
          "closed": null
        }
      ]
    }
    """#

    static func object() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(specExample.utf8)) as? [String: Any])
    }

    static func registry(_ object: [String: Any]) throws -> FeatureRegistry {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case let .ready(registry) = FeatureRegistry.load(data) else {
            Issue.record("Expected a valid acceptance registry")
            throw CocoaError(.coderReadCorrupt)
        }
        return registry
    }

    static func feature(issues: [Int] = [], prs: [Int] = [], firstSeen: String? = "2026-10-03") throws -> FeatureRegistry.Feature {
        var object = try object()
        var row = try #require((object["features"] as? [[String: Any]])?.first)
        row["issues"] = issues.map { ["number": $0, "why": "closes"] as [String: Any] }
        row["prs"] = prs.map { ["number": $0, "why": "closes"] as [String: Any] }
        row["firstSeen"] = firstSeen.map { $0 as Any } ?? NSNull()
        object["features"] = [row]
        return try #require(registry(object).feature("filing-dedupe"))
    }

    static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    static var release: [String: Any] { [
        "from": "develop", "to": "main", "who": "danieltamas",
        "when": ["ahead_commits:50", "ahead_days:7", "features_waiting:5"],
        "blockedBy": ["pr_in_review_on_paths:migrations/**"],
        "checks": [["bash", "scripts/check.sh"]], "merge": "merge-commit", "timeoutMinutes": 40
    ] }

    static func flowData(release: [String: Any]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: FlowFixture.data()) as? [String: Any])
        object["release"] = release
        return try JSONSerialization.data(withJSONObject: object)
    }
}

struct FeatureRegistryAcceptanceTests {
    @Test func decodesTheSpecExample() throws {
        let registry = try FeatureAcceptanceData.registry(FeatureAcceptanceData.object())
        #expect(FeatureRegistry.relativePath == ".bton/features.json")
        #expect(FeatureRegistry.supportedVersion == 1)
        #expect(registry.version == 1)
        #expect(registry.areas.map(\.id) == ["whatsapp-intake"])
        #expect(registry.areas.first?.paths == ["gateway/src/whatsapp/**"])
        let feature = try #require(registry.feature("filing-dedupe"))
        #expect(feature.prs.map(\.number) == [428, 419])
        #expect(feature.prs[1].why == "files")
        #expect(feature.parent == nil)
        #expect(feature.closed == nil)
        #expect(feature.firstSeen == "2026-10-03")
        #expect(registry.feature("unknown") == nil)
        #expect(registry.linkedNumbers == [402, 419, 428])
        #expect(FeatureRegistry.whys == ["closes", "branch", "label", "files", "title"])
    }

    @Test func missingAndUnknownVersionAreNone() {
        #expect(FeatureRegistry.load(nil) == .none)
        #expect(FeatureRegistry.load(Data(#"{"version":2,"areas":[],"features":[]}"#.utf8)) == .none)
        // Version handling precedes decoding v1 fields.
        #expect(FeatureRegistry.load(Data(#"{"version":2,"areas":"not an array"}"#.utf8)) == .none)
    }

    @Test(arguments: ["area", "duplicate feature", "duplicate area", "missing parent", "parent cycle", "why"])
    func invalidRegistriesSayWhy(fault: String) throws {
        var object = try FeatureAcceptanceData.object()
        var rows = try #require(object["features"] as? [[String: Any]])
        var areas = try #require(object["areas"] as? [[String: Any]])
        switch fault {
        case "area": rows[0]["area"] = "unknown"
        case "duplicate feature": rows.append(rows[0])
        case "duplicate area": areas.append(areas[0])
        case "missing parent": rows[0]["parent"] = "missing"
        case "parent cycle":
            rows[0]["parent"] = "child"
            var child = rows[0]; child["id"] = "child"; child["parent"] = "filing-dedupe"
            rows.append(child)
        default: rows[0]["issues"] = [["number": 402, "why": "guess"]]
        }
        object["features"] = rows; object["areas"] = areas
        guard case let .invalid(reason) = FeatureRegistry.load(try JSONSerialization.data(withJSONObject: object)) else {
            Issue.record("Expected invalid registry for \(fault)"); return
        }
        let word = fault.contains("duplicate") ? "duplicate" : fault.contains("parent") ? "parent" : fault
        #expect(reason.lowercased().contains(word))
    }

    @Test func malformedVersionOneIsInvalid() {
        guard case let .invalid(reason) = FeatureRegistry.load(Data(#"{"version":1,"areas":"#.utf8)) else {
            Issue.record("Malformed version 1 must be invalid, never none"); return
        }
        #expect(!reason.isEmpty)
    }

    @Test func linkedNumbersAreSortedAndUnique() throws {
        let feature = try FeatureAcceptanceData.feature(issues: [428, 402, 402], prs: [428, 419])
        var object = try FeatureAcceptanceData.object()
        // Repeated links are permitted; the read set must still contain each number once.
        object["features"] = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: [[
            "id": feature.id, "name": feature.name, "summary": feature.summary, "area": feature.area,
            "paths": feature.paths, "issues": [["number": 428, "why": "closes"], ["number": 402, "why": "label"]],
            "prs": [["number": 428, "why": "branch"], ["number": 419, "why": "title"]]
        ]]))
        #expect(try FeatureAcceptanceData.registry(object).linkedNumbers == [402, 419, 428])
    }

    @Test func flowDecodesRelease() throws {
        guard case let .ready(flow) = Flow.load(try FeatureAcceptanceData.flowData(release: FeatureAcceptanceData.release)) else {
            Issue.record("Expected ready flow"); return
        }
        let release = try #require(flow.release)
        #expect(release.from == "develop")
        #expect(release.to == "main")
        #expect(release.who == "danieltamas")
        #expect(release.when == ["ahead_commits:50", "ahead_days:7", "features_waiting:5"])
        #expect(release.blockedBy == ["pr_in_review_on_paths:migrations/**"])
        #expect(release.checks == [["bash", "scripts/check.sh"]])
        #expect(release.merge == "merge-commit")
        #expect(release.timeoutMinutes == 40)
    }

    @Test func flowWithoutReleaseIsNil() throws { #expect(try FlowFixture.flow().release == nil) }

    @Test(arguments: [("merge", "squash"), ("to", "develop"), ("to", "-x"), ("from", "bad..branch")])
    func flowRefusesBadRelease(field: String, value: String) throws {
        var release = FeatureAcceptanceData.release; release[field] = value
        guard case let .invalid(reason) = Flow.load(try FeatureAcceptanceData.flowData(release: release)) else {
            Issue.record("Expected invalid release \(field)=\(value)"); return
        }
        #expect(!reason.isEmpty)
    }

    @Test func flowAcceptsFastForward() throws {
        var release = FeatureAcceptanceData.release; release["merge"] = "fast-forward"
        guard case let .ready(flow) = Flow.load(try FeatureAcceptanceData.flowData(release: release)) else {
            Issue.record("fast-forward is supported"); return
        }
        #expect(flow.release?.merge == "fast-forward")
    }
}
