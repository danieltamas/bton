import BtonCore
import SwiftUI

/// Beside the map: what the picked module holds and touches, or, with nothing picked, what
/// the picture is of. A linked module in the list is a button that picks it.
struct ModulePanel: View {
    let map: ModuleMap.Map?
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let map, let path = selected, let module = map.modules.first(where: { $0.path == path }) {
                    picked(module, in: map)
                } else {
                    legend
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paneInner)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The map").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text("Each circle is a directory of the repo, sized by the code symbols it holds: functions, classes, tables. A line is the calls and imports between two directories, thicker for more.")
            Text("A circle carries the name of its community when the graph put over half of it in one; else its directory. Coarse, Medium and Fine change how far the directories are split.")
            Text("Click a circle for its communities, the modules it is linked to, its most connected symbols, and the pull requests that touched it. Drag to pan, scroll or pinch to zoom.")
            if let map, let commit = map.commit {
                Text("Built from \(commit.prefix(8)).").foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.meta).foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private func picked(_ module: ModuleMap.Module, in map: ModuleMap.Map) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(module.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(module.symbols.formatted()) symbols in \(module.files.formatted()) \(module.files == 1 ? "file" : "files")")
                .font(.meta).foregroundStyle(Theme.textSecondary)
        }
        if module.communities.contains(where: { $0.share >= 0.1 }) {
            section("Communities") {
                ForEach(module.communities.filter { $0.share >= 0.1 }, id: \.name) { community in
                    row(community.name, trailing: "\(Int(community.share * 100))%")
                }
            }
        }
        let links = neighbours(of: module.path, in: map)
        if !links.isEmpty {
            section("Linked to") {
                ForEach(links, id: \.path) { link in
                    Button { onPick(link.path) } label: {
                        row(Self.short(link.path), symbol: link.symbol, trailing: link.weight.formatted())
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .pointingHandCursor()
                    .help(link.help)
                }
            }
        }
        if !module.topSymbols.isEmpty {
            section("Most connected") {
                // By position: two symbols can share a label (constructors, overloads).
                ForEach(Array(module.topSymbols.enumerated()), id: \.offset) { _, symbol in
                    VStack(alignment: .leading, spacing: 1) {
                        row(symbol.label, trailing: symbol.degree.formatted())
                        Text(Self.short(symbol.file)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
            }
        }
        if !module.pullRequests.isEmpty {
            section("Pull requests here") {
                ForEach(module.pullRequests, id: \.self) { line in
                    Text(line).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.eyebrow).foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func row(_ text: String, symbol: String? = nil, trailing: String) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary) }
            Text(text).font(.meta).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 4)
            Text(trailing).font(.meta).foregroundStyle(Theme.textTertiary).monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    private struct Neighbour {
        let path: String
        let out: Int
        let `in`: Int
        var weight: Int { out + `in` }
        /// Which way the use goes: this module uses the other, the other uses it, or both.
        var symbol: String { out > 0 && `in` > 0 ? "arrow.left.arrow.right" : out > 0 ? "arrow.right" : "arrow.left" }
        var help: String { "\(out.formatted()) uses of it from here, \(`in`.formatted()) uses of this module from there" }
    }

    private func neighbours(of path: String, in map: ModuleMap.Map) -> [Neighbour] {
        var out: [String: Int] = [:], `in`: [String: Int] = [:]
        for link in map.links {
            if link.from == path { out[link.to, default: 0] += link.weight }
            if link.to == path { `in`[link.from, default: 0] += link.weight }
        }
        return Set(out.keys).union(`in`.keys)
            .map { Neighbour(path: $0, out: out[$0] ?? 0, in: `in`[$0] ?? 0) }
            .sorted { $0.weight > $1.weight }
            .prefix(10)
            .map { $0 }
    }

    /// The root module reads as what it is; a long path keeps its tail.
    static func short(_ path: String) -> String {
        if path.isEmpty { return "(root files)" }
        let parts = path.split(separator: "/")
        return parts.count > 3 ? ".../" + parts.suffix(3).joined(separator: "/") : path
    }
}
