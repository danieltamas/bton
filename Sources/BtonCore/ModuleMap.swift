import Foundation

/// A repo's graph folded to a map a person reads: the modules are directories, sized by the
/// code symbols they hold, cut adaptively so a lopsided tree (lexito: 18,000 of 22,000 symbols
/// under gateway/src) still gives about `budget` modules; the links are the calls and imports
/// between them. graphify's page draws its 3,900 communities as dots instead, three quarters
/// of them linked to nothing, which is a picture of an algorithm, not of the repo.
public enum ModuleMap {
    public struct Symbol: Equatable, Sendable {
        public let label: String
        public let file: String
        /// Calls and imports in and out, over the whole graph.
        public let degree: Int
    }

    /// A place in the unit square.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    public struct Community: Equatable, Sendable {
        public let name: String
        public let share: Double
    }

    public struct Module: Equatable, Sendable, Identifiable {
        /// The directory, "" for files at the root. A split directory keeps its own files under its path.
        public let path: String
        public let symbols: Int
        public let files: Int
        /// The community that holds most of the module's symbols, when it holds over half.
        public let communityName: String?
        public let communityShare: Double
        /// The three largest communities in the module with their share, for the panel.
        public let communities: [Community]
        /// The most connected symbols, for the panel.
        public let topSymbols: [Symbol]
        /// "#99 title" of the pull requests whose files fall here, newest first, from the memory.
        public var pullRequests: [String]

        public var id: String { path }
        public var name: String { path.isEmpty ? "(root files)" : path }
        /// The first path component, which gives a module its hue.
        public var group: String { path.split(separator: "/").first.map(String.init) ?? "" }
    }

    public struct Link: Equatable, Sendable {
        public let from: String
        public let to: String
        /// Calls, imports and the like from `from` into `to`.
        public let weight: Int
    }

    public struct Map: Equatable, Sendable {
        public let commit: String?
        public let modules: [Module]
        public let links: [Link]
        public let symbols: Int
        public let files: Int
    }

    /// The relations that mean one piece of code uses another; `contains`, `method` and
    /// `defines` are structure within a file and would link a module to itself.
    public static let useRelations: Set<String> = [
        "calls", "imports", "imports_from", "dynamic_import", "references", "indirect_call",
        "re_exports", "inherits", "extends", "implements",
    ]

    /// Folders that hold a module's tests: never a module of their own.
    public static let testFolders: Set<String> = ["__tests__", "__mocks__", "test", "tests", "spec", "specs"]

    /// How many modules a map aims at; the cut stops at the first count at or over it.
    public static let budgets = [24, 48, 96]
    public static let defaultBudget = 48

    /// The few fields of graph.json the map reads (52 MB on lexito decode in 0.4 s this way).
    struct Graph: Decodable {
        struct Node: Decodable {
            let id: String
            let label: String?
            let source_file: String?
            let file_type: String?
            let community: Int?
            let community_name: String?
        }
        struct Edge: Decodable {
            let source: String
            let target: String
            let relation: String?
        }
        let nodes: [Node]
        let links: [Edge]
        let built_at_commit: String?
    }

    /// The map of a store's graph, with the pull requests from its memory.
    public static func read(store: URL, budget: Int = defaultBudget) throws -> Map {
        let data = try Data(contentsOf: store.appendingPathComponent("graph.json"))
        let graph = try JSONDecoder().decode(Graph.self, from: data)
        var map = build(graph, budget: budget)
        let pulls = pullRequests(in: store.appendingPathComponent(GraphMemory.folderName).appendingPathComponent("prs"))
        map = attach(pulls, to: map)
        return map
    }

    // MARK: - The cut

    /// A directory with the symbols of its own files and of everything below.
    private final class Dir {
        let path: String
        var own = 0
        var total = 0
        var children: [String: Dir] = [:]
        init(path: String) { self.path = path }
    }

    static func build(_ graph: Graph, budget: Int) -> Map {
        // Code only: documents, concepts and the memory's files are not modules.
        let code = graph.nodes.filter { $0.file_type == "code" && $0.source_file != nil }
        let root = Dir(path: "")
        var dirs: [String: Dir] = ["": root]
        for node in code {
            let file = node.source_file!
            let directory = file.split(separator: "/").dropLast().map(String.init)
            var current = root
            current.total += 1
            var path = ""
            for part in directory {
                path = path.isEmpty ? part : path + "/" + part
                let child = current.children[part] ?? { let d = Dir(path: path); current.children[part] = d; dirs[path] = d; return d }()
                child.total += 1
                current = child
            }
            current.own += 1
        }

        // Start with the whole repo as one module and split the largest until the budget is met.
        // A child too small to matter at this budget (a fifth of an even share, or under 3
        // symbols) stays with its parent, so the map is not a cloud of specks around the modules
        // that count; a test folder stays with the module it tests.
        let tiny = max(3, code.count / (budget * 5))
        var modules: Set<String> = [""]
        var splittable = [Dir](arrayLiteral: root)
        while modules.count < budget, let largest = splittable.max(by: { $0.total < $1.total }) {
            splittable.removeAll { $0 === largest }
            let children = largest.children.values.filter { $0.total >= tiny && !testFolders.contains($0.path.split(separator: "/").last.map(String.init) ?? "") }
            guard !children.isEmpty else { continue }
            for child in children {
                modules.insert(child.path)
                splittable.append(child)
            }
            // The split directory keeps its own files and the tiny children under its path.
            if largest.total - children.reduce(0, { $0 + $1.total }) == 0 { modules.remove(largest.path) }
        }

        // A symbol belongs to the longest module path that is a prefix of its directory.
        let sorted = modules.sorted { $0.count > $1.count }
        func module(of file: String) -> String {
            let directory = file.split(separator: "/").dropLast().joined(separator: "/")
            for m in sorted where m.isEmpty || directory == m || directory.hasPrefix(m + "/") { return m }
            return ""
        }
        var moduleOf: [String: String] = [:]
        var nodeFile: [String: String] = [:]
        for node in code {
            let m = module(of: node.source_file!)
            moduleOf[node.id] = m
            nodeFile[node.id] = node.source_file!
        }

        // Degrees and links over the use relations between code symbols.
        var degree: [String: Int] = [:]
        var weights: [String: [String: Int]] = [:]
        for edge in graph.links where edge.relation.map(useRelations.contains) == true {
            guard let a = moduleOf[edge.source], let b = moduleOf[edge.target] else { continue }
            degree[edge.source, default: 0] += 1
            degree[edge.target, default: 0] += 1
            if a != b { weights[a, default: [:]][b, default: 0] += 1 }
        }
        var links: [Link] = []
        for (from, tos) in weights { for (to, weight) in tos { links.append(Link(from: from, to: to, weight: weight)) } }
        links.sort { ($0.weight, $0.from, $0.to) > ($1.weight, $1.from, $1.to) }

        // Each module: counts, its leading community, its most connected symbols.
        var built: [Module] = []
        for path in modules.sorted() {
            let members = code.filter { moduleOf[$0.id] == path }
            guard !members.isEmpty else { continue }
            let files = Set(members.map { $0.source_file! }).count
            var communities: [Int: (count: Int, name: String?)] = [:]
            for n in members { if let c = n.community { communities[c, default: (0, nil)].count += 1; if communities[c]!.name == nil { communities[c]!.name = n.community_name } } }
            let lead = communities.max { $0.value.count < $1.value.count }
            let share = lead.map { Double($0.value.count) / Double(members.count) } ?? 0
            let largest = communities.sorted { $0.value.count > $1.value.count }.prefix(3)
                .compactMap { entry in entry.value.name.map { Community(name: $0, share: Double(entry.value.count) / Double(members.count)) } }
            let top = members
                .map { Symbol(label: $0.label ?? $0.id, file: $0.source_file!, degree: degree[$0.id] ?? 0) }
                .sorted { ($0.degree, $1.label) > ($1.degree, $0.label) }
                .prefix(8)
            built.append(Module(path: path, symbols: members.count, files: files,
                                communityName: share > 0.5 ? lead?.value.name : nil, communityShare: share,
                                communities: largest, topSymbols: Array(top), pullRequests: []))
        }
        built.sort { $0.symbols > $1.symbols }
        return Map(commit: graph.built_at_commit, modules: built, links: links,
                   symbols: code.count, files: Set(code.map { $0.source_file! }).count)
    }

    // MARK: - Pull requests from the memory

    /// A pull request as the memory writes it: "# #99 title" first, a "Files:" list of "- path".
    struct PullRequest: Equatable {
        let number: Int
        let title: String
        let files: [String]
    }

    static func pullRequests(in folder: URL) -> [PullRequest] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap { name -> PullRequest? in
            guard name.hasSuffix(".md"), let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return pullRequest(from: text)
        }
        .sorted { $0.number > $1.number }
    }

    static func pullRequest(from text: String) -> PullRequest? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard let head = lines.first, head.hasPrefix("# #") else { return nil }
        let rest = head.dropFirst(3)
        guard let number = Int(rest.prefix { $0.isNumber }) else { return nil }
        let title = rest.drop { $0.isNumber }.trimmingCharacters(in: .whitespaces)
        lines = lines.dropFirst()
        // The memory writes the file list as a paragraph of its own, "Files:" then one "- path" a
        // line; a "Files:" inside the PR's body is taken only when it has that exact shape.
        var files: [String] = []
        for start in lines.indices where lines[start] == "Files:" && (start == lines.startIndex || lines[lines.index(before: start)].isEmpty) {
            var found: [String] = []
            for line in lines[lines.index(after: start)...] {
                if line.isEmpty { break }
                guard line.hasPrefix("- ") else { found = []; break }
                found.append(String(line.dropFirst(2)))
            }
            if !found.isEmpty { files = found; break }
        }
        return PullRequest(number: number, title: title, files: files)
    }

    /// Each module gets the newest pull requests (at most 6) with a file under it.
    static func attach(_ pulls: [PullRequest], to map: Map) -> Map {
        let sorted = map.modules.map(\.path).sorted { $0.count > $1.count }
        func module(of file: String) -> String? {
            let directory = file.split(separator: "/").dropLast().joined(separator: "/")
            return sorted.first { $0.isEmpty || directory == $0 || directory.hasPrefix($0 + "/") }
        }
        var byModule: [String: [String]] = [:]
        for pr in pulls {
            let line = "#\(pr.number) \(pr.title)"
            for path in Set(pr.files.compactMap(module(of:))) where byModule[path, default: []].count < 6 {
                byModule[path, default: []].append(line)
            }
        }
        var modules = map.modules
        for i in modules.indices { modules[i].pullRequests = byModule[modules[i].path] ?? [] }
        return Map(commit: map.commit, modules: modules, links: map.links, symbols: map.symbols, files: map.files)
    }

    // MARK: - Layout

    /// The radius a module is drawn with, as a share of the square's side: the layout keeps
    /// circles apart by it, the canvas draws them by it, so what the forces separated stays
    /// separate on screen.
    public static func radius(of module: Module, in map: Map) -> Double {
        let largest = Double(map.modules.map(\.symbols).max() ?? 1)
        return 0.008 + 0.04 * (Double(module.symbols) / largest).squareRoot()
    }

    /// Positions in the unit square, the same every time for the same map (a seeded start,
    /// a force layout of fixed length): a person finds a module where it was yesterday.
    /// Fruchterman-Reingold: linked modules pull together by the weight of their links, all
    /// push apart within a few ideal lengths, a mild gravity keeps the unlinked near the rest,
    /// and the square's walls hold everything in.
    public static func layout(_ map: Map) -> [String: Point] {
        let modules = map.modules
        guard !modules.isEmpty else { return [:] }
        let n = modules.count
        let index = Dictionary(uniqueKeysWithValues: modules.enumerated().map { ($1.path, $0) })
        let radius = modules.map { Self.radius(of: $0, in: map) }
        var rng = UInt64(0x9E37_79B9_7F4A_7C15)
        func random() -> Double {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(rng >> 11) / Double(1 << 53)
        }
        var x = (0..<n).map { _ in 0.25 + 0.5 * random() }
        var y = (0..<n).map { _ in 0.25 + 0.5 * random() }
        var pulls: [(Int, Int, Double)] = []
        var seen: [String: Int] = [:]
        for link in map.links {
            guard let a = index[link.from], let b = index[link.to] else { continue }
            let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
            if let i = seen[key] { pulls[i].2 += Double(link.weight) } else { seen[key] = pulls.count; pulls.append((a, b, Double(link.weight))) }
        }
        let maxPull = pulls.map(\.2).max() ?? 1
        let k = 0.8 / Double(n).squareRoot()
        let steps = 600
        for step in 0..<steps {
            let temperature = 0.002 + 0.1 * (1 - Double(step) / Double(steps))
            var dx = [Double](repeating: 0, count: n), dy = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ddx = x[i] - x[j], ddy = y[i] - y[j]
                    var d = (ddx * ddx + ddy * ddy).squareRoot()
                    if d < 1e-4 { ddx = random() - 0.5; ddy = random() - 0.5; d = 1e-3 }
                    // Beyond three ideal lengths the push stops, else the whole map pushes a
                    // module with no links to the walls; gravity brings it back to the rest.
                    let gap = radius[i] + radius[j] + 0.015
                    guard d < 2.5 * k || d < gap else { continue }
                    let force = k * k / d * (d < gap ? 6 : 1)
                    dx[i] += ddx / d * force; dy[i] += ddy / d * force
                    dx[j] -= ddx / d * force; dy[j] -= ddy / d * force
                }
            }
            for (a, b, w) in pulls {
                let ddx = x[a] - x[b], ddy = y[a] - y[b]
                let d = max((ddx * ddx + ddy * ddy).squareRoot(), 1e-4)
                // No pull once two circles touch: the heaviest links must not stack modules.
                let rest = radius[a] + radius[b] + 0.02
                guard d > rest else { continue }
                let force = (d - rest) * (d - rest) / k * (0.15 + 0.85 * (w / maxPull).squareRoot())
                dx[a] -= ddx / d * force; dy[a] -= ddy / d * force
                dx[b] += ddx / d * force; dy[b] += ddy / d * force
            }
            for i in 0..<n {
                dx[i] -= (x[i] - 0.5) * 0.3; dy[i] -= (y[i] - 0.5) * 0.3
                let d = max((dx[i] * dx[i] + dy[i] * dy[i]).squareRoot(), 1e-9)
                let move = min(d, temperature)
                let wall = radius[i] + 0.03
                x[i] = min(1 - wall, max(wall, x[i] + dx[i] / d * move))
                y[i] = min(1 - wall, max(wall, y[i] + dy[i] / d * move))
            }
        }
        var out: [String: Point] = [:]
        for (i, m) in modules.enumerated() { out[m.path] = Point(x: x[i], y: y[i]) }
        return out
    }

    /// What a module is called on the map: its community's name when one holds most of it,
    /// else the last part of its path, with the part before when another module ends the same
    /// way (three modules named `src` say nothing).
    public static func label(of module: Module, in map: Map) -> String {
        if let name = module.communityName { return name }
        if module.path.isEmpty { return module.name }
        let parts = module.path.split(separator: "/").map(String.init)
        let last = parts.last!
        let twins = map.modules.filter { $0.path != module.path && $0.path.split(separator: "/").last.map(String.init) == last }
        return twins.isEmpty || parts.count < 2 ? last : parts.suffix(2).joined(separator: "/")
    }
}
