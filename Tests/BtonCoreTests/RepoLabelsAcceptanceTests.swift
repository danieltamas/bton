import Foundation
import Testing
@testable import BtonCore

@Suite struct RepoLabelsAcceptanceTests {
    private func label(_ name: String) -> RepoLabel {
        RepoLabel(name: name, color: "0075ca")
    }

    private func labels() -> [RepoLabel] {
        [label("stage:triage"), label("stage:spec"), label("stage:ready"), label("priority:high"), label("bug")]
    }

    @Test func decodingKeepsOrderAndReadsNullFieldsAsEmpty() throws {
        let json = """
        [{"color":"0075ca","description":"Docs","name":"documentation"},
        {"color":"d93f0b","description":"","name":"stage:ready"},
        {"name":"bare","color":null,"description":null}]
        """
        let decoded = try RepoLabels.decode(Data(json.utf8))
        #expect(decoded.map(\.name) == ["documentation", "stage:ready", "bare"])
        #expect(decoded.map(\.color) == ["0075ca", "d93f0b", ""])
        #expect(decoded.map(\.description) == ["Docs", "", ""])
    }

    @Test func decodingRejectsBodiesThatAreNotArrays() {
        for json in ["{}", "null", "\"label\"", "42", "true", "not JSON"] {
            #expect(throws: (any Error).self) {
                try RepoLabels.decode(Data(json.utf8))
            }
        }
    }

    @Test func familyUsesTheLowercasedPrefixThroughTheFirstColon() {
        #expect(RepoLabels.family(of: "stage:ready") == "stage:")
        #expect(RepoLabels.family(of: "Stage:Ready") == "stage:")
        #expect(RepoLabels.family(of: "a:b:c") == "a:")
        #expect(RepoLabels.family(of: "bug") == nil)
        #expect(RepoLabels.family(of: ":odd") == nil)
        #expect(RepoLabel(name: "priority:high", color: "").family == "priority:")
    }

    @Test func alternativesKeepRepoOrderAndExcludeTheCurrentLabelIgnoringCase() {
        let expected = [label("stage:triage"), label("stage:ready")]
        #expect(RepoLabels.alternatives(to: "stage:spec", in: labels()) == expected)
        #expect(RepoLabels.alternatives(to: "Stage:Spec", in: labels()) == expected)
        #expect(RepoLabels.alternatives(to: "bug", in: labels()).isEmpty)
    }

    @Test func availableLeavesOutHeldLabelsIgnoringCaseInRepoOrder() {
        #expect(RepoLabels.available(in: labels(), on: ["stage:spec", "BUG"]) ==
                [label("stage:triage"), label("stage:ready"), label("priority:high")])
    }

    @Test func addingAFamilyLabelReplacesOnlyItsFamily() {
        let edit = RepoLabels.edit(adding: "stage:ready", to: ["priority:high", "stage:spec", "bug"])
        #expect(edit.add == ["stage:ready"])
        #expect(edit.remove == ["stage:spec"])
        let plain = RepoLabels.edit(adding: "bug", to: ["stage:spec"])
        #expect(plain.add == ["bug"])
        #expect(plain.remove == [])
    }

    @Test func addingAHeldLabelDoesNothingIgnoringCase() {
        for name in ["stage:spec", "Stage:Spec"] {
            let edit = RepoLabels.edit(adding: name, to: ["stage:spec"])
            #expect(edit.add == [])
            #expect(edit.remove == [])
        }
    }

    @Test func addingAFamilyLabelRemovesEveryOldFamilyMember() {
        let edit = RepoLabels.edit(adding: "stage:ready", to: ["stage:spec", "stage:triage"])
        #expect(edit.add == ["stage:ready"])
        #expect(edit.remove == ["stage:spec", "stage:triage"])
    }

    @Test func applyingAnEditKeepsExistingOrderThenAppendsAddedLabels() {
        let applied = RepoLabels.apply((add: ["stage:ready"], remove: ["stage:spec"]),
                                      to: ["priority:high", "stage:spec", "bug"])
        #expect(applied == ["priority:high", "bug", "stage:ready"])
    }

    @Test func cachePersistsReposAndTrustsOnlyRecordsLessThanADayOld() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = BtonHome(environment: ["BTON_HOME": dir.path])
        let time = Date(timeIntervalSince1970: 1_000_000)
        let empty = RepoLabels.load(home: home)
        #expect(empty.repos.isEmpty)
        #expect(empty.fresh("o/r", now: time) == nil)
        #expect(RepoLabels.maxAge == 86400)
        #expect(RepoLabels.url(home: home) == dir.appendingPathComponent("labels.json"))

        let saved = [label("a"), label("b")]
        try RepoLabels.remember(saved, repo: "O/R", now: time, home: home)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("labels.json").path))
        let loaded = RepoLabels.load(home: home)
        #expect(loaded.fresh("o/r", now: time) == saved)
        #expect(loaded.fresh("O/R", now: time.addingTimeInterval(24 * 3600 - 1)) == saved)
        #expect(loaded.fresh("o/r", now: time.addingTimeInterval(24 * 3600)) == nil)
        #expect(loaded.fresh("o/r", now: time.addingTimeInterval(-1)) == nil)
        #expect(loaded.fresh("other/repo", now: time) == nil)

        let second = [label("bug")]
        try RepoLabels.remember(second, repo: "other/repo", now: time, home: home)
        let both = RepoLabels.load(home: home)
        #expect(both.fresh("o/r", now: time) == saved)
        #expect(both.fresh("other/repo", now: time) == second)
        #expect(both.repos.count == 2)
    }
}
