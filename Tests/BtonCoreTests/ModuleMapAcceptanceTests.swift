@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct ModuleMapAcceptanceTests {
    @Test func oneModuleCountsOnlyCodeAndDistinctFiles() throws {
        let map = ModuleMap.build(try Self.graph(), budget: 1)
        #expect(map.commit == "abc123")
        #expect(map.symbols == 16)
        #expect(map.files == 7)
        let root = try #require(map.modules.first)
        #expect(map.modules.count == 1)
        #expect(root.path == "")
        #expect(root.name == "(root files)")
        #expect(root.symbols == 16)
        #expect(root.files == 7)
        #expect(map.links.isEmpty)
    }

    @Test func adaptiveCutKeepsTestsAndTinyDirectoriesWithTheirModule() throws {
        let map = ModuleMap.build(try Self.graph(), budget: 48)
        #expect(map.modules.map(\.path) == ["app/core", "app/ui", ""])
        #expect(map.modules.map(\.symbols) == [9, 4, 3])
        #expect(map.modules.map(\.files) == [3, 1, 3])
        let core = try #require(map.modules.first { $0.path == "app/core" })
        let ui = try #require(map.modules.first { $0.path == "app/ui" })
        #expect(core.group == "app")
        #expect(core.communityName == "Core Engine")
        #expect(core.communityShare == 6.0 / 9.0)
        #expect(ui.communityName == nil)
        #expect(ui.communityShare == 0.5)
        #expect(Set(ui.communities.map(\.name)) == Set(["Buttons", "Forms"]))
        #expect(ui.communities.count == 2)
        #expect(ui.communities.allSatisfy { $0.share == 0.5 })
        #expect(map.links == [.init(from: "app/ui", to: "app/core", weight: 3),
                              .init(from: "", to: "app/core", weight: 1)])
        // Exact degrees catch structural edges leaking into rankings, including same-module edges.
        #expect(core.topSymbols.count == 8)
        #expect(core.topSymbols.prefix(3).map(\.label) == ["core1", "core2", "core3"])
        #expect(core.topSymbols.prefix(3).map(\.degree) == [3, 2, 1])
        #expect(core.topSymbols.dropFirst(3).allSatisfy { $0.degree == 0 })
        #expect(core.topSymbols.first?.file == "app/core/engine.ts")
    }

    @Test func mapChoicesAndRelationsMatchTheReadingContract() {
        #expect(ModuleMap.budgets == [24, 48, 96])
        #expect(ModuleMap.defaultBudget == 48)
        #expect(ModuleMap.testFolders == Set(["__tests__", "__mocks__", "test", "tests", "spec", "specs"]))
        #expect(ModuleMap.useRelations == Set(["calls", "imports", "imports_from", "dynamic_import",
            "references", "indirect_call", "re_exports", "inherits", "extends", "implements"]))
        #expect(ModuleMap.useRelations.isDisjoint(with: ["contains", "method", "defines"]))
    }

    @Test func pullRequestReadsTheHeadingAndStopsAtABlankLine() throws {
        let pull = try #require(ModuleMap.pullRequest(from:
            "# #99 Improve core engine\n\nFiles:\n- app/core/engine.ts\n- app/ui/view.ts\n\n- ignored.ts"))
        #expect(pull.number == 99)
        #expect(pull.title == "Improve core engine")
        #expect(pull.files == ["app/core/engine.ts", "app/ui/view.ts"])
        #expect(ModuleMap.pullRequest(from: "Some text") == nil)
    }

    @Test func attachingPullRequestsUsesTheCutAndListsEachPullOnce() throws {
        let map = ModuleMap.build(try Self.graph(), budget: 48)
        let pulls: [ModuleMap.PullRequest] = [
            .init(number: 99, title: "Improve core", files: ["app/core/engine.ts", "app/core/types.ts", "app/ui/view.ts"]),
            .init(number: 98, title: "Fix library", files: ["lib/a.ts"])
        ]
        let attached = ModuleMap.attach(pulls, to: map)
        #expect(attached.modules.map(\.pullRequests) == [["#99 Improve core"], ["#99 Improve core"], ["#98 Fix library"]])
        let coreOnly = ModuleMap.attach([.init(number: 97, title: "Core only", files: ["app/core/types.ts"])], to: map)
        #expect(coreOnly.modules.dropFirst().allSatisfy { $0.pullRequests.isEmpty })
        // The caller supplies newest first; the panel must retain that order and stay bounded.
        let many = (90...97).reversed().map {
            ModuleMap.PullRequest(number: $0, title: "Update", files: ["app/core/engine.ts"])
        }
        let capped = ModuleMap.attach(many, to: map)
        #expect(capped.modules.first?.pullRequests == (92...97).reversed().map { "#\($0) Update" })
    }

    @Test func layoutIsRepeatableAndFitsEveryModuleInTheUnitSquare() throws {
        let map = ModuleMap.build(try Self.graph(), budget: 48)
        let points = ModuleMap.layout(map)
        #expect(Set(points.keys) == Set(map.modules.map(\.path)))
        #expect(points == ModuleMap.layout(map))
        #expect(points.values.allSatisfy { (0.0...1.0).contains($0.x) && (0.0...1.0).contains($0.y) })
        let empty = try JSONDecoder().decode(ModuleMap.Graph.self, from: Data(#"{"nodes":[],"links":[]}"#.utf8))
        #expect(ModuleMap.layout(ModuleMap.build(empty, budget: 48)).isEmpty)
    }

    private static func graph() throws -> ModuleMap.Graph {
        // The uneven tree forces a deeper cut while tests and the tiny library stay folded in.
        let json = #"""
        {"built_at_commit":"abc123","nodes":[
          {"id":"readme","label":"README","source_file":"README.md","file_type":"document"},
          {"id":"index","label":"index","source_file":"index.ts","file_type":"code"},
          {"id":"c1","label":"core1","source_file":"app/core/engine.ts","file_type":"code","community":7,"community_name":"Core Engine"},
          {"id":"c2","label":"core2","source_file":"app/core/engine.ts","file_type":"code","community":7,"community_name":"Core Engine"},
          {"id":"c3","label":"core3","source_file":"app/core/engine.ts","file_type":"code","community":7,"community_name":"Core Engine"},
          {"id":"c4","label":"core4","source_file":"app/core/types.ts","file_type":"code","community":7,"community_name":"Core Engine"},
          {"id":"c5","label":"core5","source_file":"app/core/types.ts","file_type":"code","community":7,"community_name":"Core Engine"},
          {"id":"c6","label":"core6","source_file":"app/core/types.ts","file_type":"code","community":7,"community_name":"Core Engine"},
          {"id":"t1","label":"test1","source_file":"app/core/__tests__/engine.ts","file_type":"code"},
          {"id":"t2","label":"test2","source_file":"app/core/__tests__/engine.ts","file_type":"code"},
          {"id":"t3","label":"test3","source_file":"app/core/__tests__/engine.ts","file_type":"code"},
          {"id":"u1","label":"button1","source_file":"app/ui/view.ts","file_type":"code","community":8,"community_name":"Buttons"},
          {"id":"u2","label":"button2","source_file":"app/ui/view.ts","file_type":"code","community":8,"community_name":"Buttons"},
          {"id":"u3","label":"form1","source_file":"app/ui/view.ts","file_type":"code","community":9,"community_name":"Forms"},
          {"id":"u4","label":"form2","source_file":"app/ui/view.ts","file_type":"code","community":9,"community_name":"Forms"},
          {"id":"l1","label":"library1","source_file":"lib/a.ts","file_type":"code"},
          {"id":"l2","label":"library2","source_file":"lib/b.ts","file_type":"code"},
          {"id":"issue","label":"issue","source_file":"memory/issues/1.md","file_type":"document"},
          {"id":"concept","label":"concept","source_file":"ideas/concept.md","file_type":"concept"},
          {"id":"file","label":"engine.ts","source_file":"app/core/engine.ts","file_type":"file"}
        ],"links":[
          {"source":"u1","target":"c1","relation":"calls"},
          {"source":"u2","target":"c1","relation":"calls"},
          {"source":"u3","target":"c2","relation":"calls"},
          {"source":"l1","target":"c2","relation":"imports"},
          {"source":"file","target":"c1","relation":"contains"},
          {"source":"file","target":"c2","relation":"contains"},
          {"source":"c1","target":"c3","relation":"calls"}
        ]}
        """#
        return try JSONDecoder().decode(ModuleMap.Graph.self, from: Data(json.utf8))
    }
}
