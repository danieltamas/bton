@testable import BtonCore
import Foundation
import Testing

struct FeaturePageAcceptanceTests {
    @Test func treeOrdersParentsBeforeChildren() throws {
        let f = try FeaturePageFixture.make()
        let page = f.page()
        #expect(page.areas.map(\.id) == ["whatsapp-intake", "empty"])
        #expect(page.areas[0].rows.map(\.id) == ["filing-dedupe", "same-photo", "voice-notes"])
        #expect(page.areas[0].rows.map(\.depth) == [0, 1, 0])
        #expect(page.areas[1].rows.isEmpty)
    }

    @Test func collapsedCountsMatchRows() throws {
        let f = try FeaturePageFixture.make()
        let page = f.page()
        #expect(page.areas[0].counts[.inDevelop] == 2)
        #expect(page.areas[0].counts[.building] == 1)
        #expect(page.areas[0].counts.values.reduce(0, +) == page.areas[0].rows.count)
        #expect(page.areas[1].counts.values.reduce(0, +) == 0)
        for area in page.areas {
            for status in FeatureStatus.allCases {
                #expect((area.counts[status] ?? 0) == area.rows.filter { $0.standing.status == status }.count)
            }
        }
    }

    @Test func chipCountsMatchFilters() throws {
        let f = try FeaturePageFixture.make()
        #expect(FeaturePage.count(.shipsNext, report: f.report) == 2)
        #expect(FeaturePage.count(.building, report: f.report) == 1)
        #expect(FeaturePage.count(.live, report: f.report) == 0)
        #expect(FeaturePage.count(.ideas, report: f.report) == 0)
        #expect(FeatureFilter.allCases.reduce(0) { $0 + FeaturePage.count($1, report: f.report) } == 3)
        for filter in FeatureFilter.allCases {
            let matched = f.page(filter: filter).areas.flatMap(\.rows).filter { FeaturePage.matches(filter, $0.standing.status) }
            #expect(matched.count == FeaturePage.count(filter, report: f.report))
        }
    }

    @Test func filtersMatchOnlyTheirPinnedStatuses() {
        for status in FeatureStatus.allCases {
            #expect(FeaturePage.matches(.retired, status) == (status == .retired))
            #expect(FeaturePage.matches(.shipsNext, status) == (status == .inDevelop))
            #expect(FeaturePage.matches(.building, status) == (status == .building))
            #expect(FeaturePage.matches(.live, status) == (status == .live))
            #expect(FeaturePage.matches(.ideas, status) == [.ready, .spec, .idea].contains(status))
        }
        #expect(FeatureFilter.allCases.map(\.rawValue) == ["ships next", "building", "live", "ideas", "retired"])
        #expect(FeatureFilter.allCases.last == .retired)
    }

    @Test func filterKeepsAMatchingChildsParent() throws {
        var f = try FeaturePageFixture.make()
        f.report.standings["same-photo"] = FeaturePageFixture.standing(.building)
        f.report.standings["voice-notes"] = FeaturePageFixture.standing(.inDevelop)
        let page = f.page(filter: .building)
        #expect(page.areas.map(\.id) == ["whatsapp-intake"])
        #expect(page.areas[0].rows.map(\.id) == ["filing-dedupe", "same-photo"])
        #expect(page.areas[0].rows.map(\.depth) == [0, 1])
        #expect(FeaturePage.count(.building, report: f.report) == 1)
        #expect(page.areas[0].counts[.building] == 1)
        #expect(page.areas[0].counts[.inDevelop] == 1)
    }

    @Test func searchByNumberAndWord() throws {
        let f = try FeaturePageFixture.make()
        #expect(f.page(query: "#433").areas.flatMap(\.rows).map(\.id) == ["voice-notes"])
        #expect(f.page(query: "dedupe").areas.flatMap(\.rows).map(\.id) == ["filing-dedupe"])
        #expect(f.page(query: "SAME-PHOTO").areas.flatMap(\.rows).map(\.id) == ["filing-dedupe", "same-photo"])
        #expect(f.page(query: "transcribes").areas.flatMap(\.rows).map(\.id) == ["voice-notes"])
        #expect(f.page(query: "no matching feature").areas.isEmpty)
        #expect(f.page(query: "dedupe").areas.map(\.id) == ["whatsapp-intake"])
        #expect(f.page(filter: .live, query: "dedupe").areas.isEmpty)
    }

    @Test func summarySentences() throws {
        var f = try FeaturePageFixture.make(extraWaiting: 12)
        // Chosen clock: noon UTC on Oct 27, 2026. Extra standings make the pinned count 14.
        f.report.lastRelease = FeatureAcceptanceData.date("2026-10-19T12:00:00Z")
        let now = FeatureAcceptanceData.date("2026-10-27T12:00:00Z")
        #expect(FeaturePage.summary(report: f.report, to: "main", now: now) == "14 features in develop that main lacks. Last release Oct 19.")
        f.report.hasRelease = false
        #expect(FeaturePage.summary(report: f.report, to: "main", now: now) == nil)
        #expect(FeaturePage.ahead(commits: 100, since: FeatureAcceptanceData.date("2026-10-19T12:00:00Z"), now: now) == "100 commits, 8 days")
        #expect(FeaturePage.ahead(commits: 0, since: nil, now: now) == nil)
        #expect(FeaturePage.ahead(commits: nil, since: nil, now: now) == nil)
    }

    @Test func closedFeaturesAreHiddenByDefaultButVisibleInRetiredAndSearch() throws {
        let f = try FeaturePageFixture.make(includeClosed: true)
        let page = f.page()
        #expect(page.areas.flatMap(\.rows).map(\.id) == ["filing-dedupe", "same-photo", "voice-notes"])
        #expect(page.areas.allSatisfy { $0.counts[.retired] == nil })
        let retired = f.page(filter: .retired)
        #expect(retired.areas.flatMap(\.rows).map(\.id) == ["dropped"])
        #expect(retired.areas.flatMap(\.rows).map { $0.standing.status } == [.retired])
        #expect(retired.areas.first?.counts[.retired] == 1)
        for query in ["Archived capability", "dropped", "#902", "#928"] {
            #expect(f.page(query: query).areas.flatMap(\.rows).map(\.id) == ["dropped"])
        }
        for filter in [FeatureFilter.live, .building, .shipsNext, .ideas] {
            #expect(!f.page(filter: filter).areas.flatMap(\.rows).contains { $0.id == "dropped" })
            #expect(f.page(filter: filter, query: "dropped").areas.isEmpty)
        }
        #expect(FeaturePage.count(.retired, report: f.report) == 1)
        #expect(FeatureFilter.allCases.reduce(0) { $0 + FeaturePage.count($1, report: f.report) } == 4)
    }

    @Test func retiredChildKeepsItsOpenParent() throws {
        let f = try FeaturePageFixture.make(includeClosed: true, closedParent: "same-photo")
        let page = f.page(filter: .retired)
        #expect(page.areas.flatMap(\.rows).map(\.id) == ["filing-dedupe", "same-photo", "dropped"])
        #expect(page.areas.flatMap(\.rows).map(\.depth) == [0, 1, 2])
        #expect(FeaturePage.count(.retired, report: f.report) == 1)
    }

    @Test(arguments: FeatureStatus.allCases)
    func chipCountsUseClosureEvenWithAnInconsistentStanding(status: FeatureStatus) throws {
        var f = try FeaturePageFixture.make(includeClosed: true)
        f.report.standings["dropped"] = FeaturePageFixture.standing(status)
        #expect(FeaturePage.count(.retired, report: f.report) == 1)
        #expect(FeaturePage.count(.live, report: f.report) == 0)
        #expect(FeaturePage.count(.building, report: f.report) == 1)
        #expect(FeaturePage.count(.shipsNext, report: f.report) == 2)
        #expect(FeaturePage.count(.ideas, report: f.report) == 0)
        f.report.standings["voice-notes"] = FeaturePageFixture.standing(.retired)
        #expect(FeaturePage.count(.retired, report: f.report) == 1)
    }

}

private struct FeaturePageFixture {
    let registry: FeatureRegistry
    var report: FeatureReport

    static func standing(_ status: FeatureStatus) -> FeatureStanding {
        .init(status: status, timeline: [.init(status: status, at: nil, number: nil)],
            openIssues: 0, openPullRequests: 0, changes: [])
    }

    static func make(includeClosed: Bool = false, extraWaiting: Int = 0, closedParent: String? = nil) throws -> Self {
        var object = try FeatureAcceptanceData.object()
        var areas = try #require(object["areas"] as? [[String: Any]])
        // Chosen second area is intentionally empty, to exercise unfiltered empty-area display.
        areas.append(["id": "empty", "name": "Empty area", "paths": []])
        object["areas"] = areas
        let parent = try #require((object["features"] as? [[String: Any]])?.first)
        var child = parent
        child["id"] = "same-photo"; child["name"] = "Same-photo detection"
        child["summary"] = "Recognizes repeated photos."; child["parent"] = "filing-dedupe"
        child["issues"] = []; child["prs"] = []
        var voice = parent
        voice["id"] = "voice-notes"; voice["name"] = "Voice note transcription"
        voice["summary"] = "Transcribes voice notes."
        voice["issues"] = [["number": 433, "why": "title"]]; voice["prs"] = []
        // Deliberately scrambled; tree order must come from parentage and names.
        var rows = [voice, child, parent]
        for n in 0..<extraWaiting {
            var waiting = parent
            waiting["id"] = "waiting-\(n)"; waiting["name"] = "Waiting feature \(n)"
            rows.append(waiting)
        }
        object["features"] = rows
        let loaded = try FeatureAcceptanceData.registry(object)
        var features = loaded.features
        if includeClosed {
            features.append(FeatureRegistry.Feature(id: "dropped", name: "Archived capability", summary: "Removed capability.",
                area: "whatsapp-intake", parent: closedParent, paths: [],
                issues: [.init(number: 902, why: "closes")], prs: [.init(number: 928, why: "closes")],
                firstSeen: "2026-09-01", closed: "2026-10-01"))
        }
        let registry = FeatureRegistry(version: loaded.version, areas: loaded.areas, features: features)
        var report = FeatureReport(repo: "synthetic/project", registry: .ready(registry), hasRelease: true)
        report.standings = ["filing-dedupe": standing(.inDevelop), "same-photo": standing(.inDevelop), "voice-notes": standing(.building)]
        for n in 0..<extraWaiting { report.standings["waiting-\(n)"] = standing(.inDevelop) }
        if includeClosed { report.standings["dropped"] = standing(.retired) }
        return Self(registry: registry, report: report)
    }

    func page(filter: FeatureFilter? = nil, query: String = "") -> FeaturePage {
        FeaturePage.make(registry: registry, report: report, filter: filter, query: SearchQuery(query))
    }
}
