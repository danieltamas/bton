import AppKit
import BtonCore
import SwiftUI

/// Who makes the model a job runs, read from the model's API name or the agent's name.
enum Vendor {
    case anthropic, openai, other

    init(model: String) {
        let name = model.lowercased()
        if name.hasPrefix("claude") {
            self = .anthropic
        } else if name.hasPrefix("gpt") || name.hasPrefix("codex") || name.wholeMatch(of: /o[0-9].*/) != nil {
            self = .openai
        } else {
            self = .other
        }
    }

    init(agent: String?) {
        switch agent {
        case "claude"?: self = .anthropic
        case "codex"?: self = .openai
        default: self = .other
        }
    }

    var color: Color {
        switch self {
        case .anthropic: Color(hex: 0xD97757)
        case .openai: Color.white.opacity(0.92)
        case .other: Theme.neutral
        }
    }

    /// The bundled mark; `swift run` has no bundle and falls back to a symbol.
    var image: NSImage? {
        let name = switch self {
        case .anthropic: "LogoClaude"
        case .openai: "LogoOpenAI"
        case .other: ""
        }
        guard !name.isEmpty, let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    var fallbackSymbol: String {
        switch self {
        case .anthropic: "sparkle"
        case .openai: "circle.hexagongrid"
        case .other: "cpu"
        }
    }
}

struct VendorLogo: View {
    let vendor: Vendor
    var size: CGFloat = 14

    init(model: String, size: CGFloat = 14) {
        vendor = Vendor(model: model)
        self.size = size
    }

    init(vendor: Vendor, size: CGFloat = 14) {
        self.vendor = vendor
        self.size = size
    }

    var body: some View {
        Group {
            if let image = vendor.image {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: vendor.fallbackSymbol).resizable().scaledToFit()
            }
        }
        .foregroundStyle(vendor.color)
        .frame(width: size, height: size)
    }
}

/// `claude-opus-5-5-20261001` reads as "Opus 5.5", `gpt-5-codex` as "GPT-5 Codex".
func modelDisplayName(_ model: String) -> String {
    if let match = model.lowercased().wholeMatch(of: /claude-([a-z]+)-([0-9]+)(?:-([0-9]{1,2}))?(?:-[0-9]{8})?/) {
        let version = match.3.map { "\(match.2).\($0)" } ?? String(match.2)
        return "\(match.1.capitalized) \(version)"
    }
    let parts = model.split(separator: "-").map(String.init)
    if parts.first?.lowercased() == "gpt", parts.count >= 2 {
        return (["GPT-\(parts[1])"] + parts.dropFirst(2).map(\.capitalized)).joined(separator: " ")
    }
    return model
}

/// The models a job has used so far, busiest first; before its first call, the agent itself.
struct ModelBadges: View {
    let job: Job
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            let models = job.usage.filter { $0.value != TokenUsage() }
                .sorted { $0.value.output + $0.value.input > $1.value.output + $1.value.input }.map(\.key)
            if models.isEmpty {
                badge(vendor: Vendor(agent: job.agent), text: (job.agent ?? "command").capitalized)
            } else {
                ForEach(models.prefix(compact ? 2 : 3), id: \.self) { model in
                    badge(vendor: Vendor(model: model), text: modelDisplayName(model))
                }
            }
        }
    }

    private func badge(vendor: Vendor, text: String) -> some View {
        HStack(spacing: 4) {
            VendorLogo(vendor: vendor, size: 11)
            Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(vendor.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(vendor.color.opacity(0.22), lineWidth: 0.5))
    }
}

/// What agents are doing right now, above the PR list: the move, the PR, the models at work,
/// how long it has run and what it has cost so far.
struct ActiveStrip: View {
    @Environment(AppStore.self) private var store
    let jobs: [Job]
    let schedules: [ScheduleEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PulseDot(color: Theme.color(for: .running))
                Eyebrow(text: "Active now · \(jobs.count)", color: Theme.color(for: .running))
            }
            .padding(.leading, 4)
            ForEach(jobs) { job in
                card(job)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Motion.spring) { store.watchingJob = job.id } }
                    .help("Watch what the agent does")
            }
        }
    }

    private func card(_ job: Job) -> some View {
        let color = Theme.color(forMove: job.key.move)
        return Bezel(radius: 14, fill: Theme.core, glow: color) {
            HStack(spacing: 10) {
                GlyphDisc(symbol: Theme.symbol(forMove: job.key.move), color: color, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(of: job)).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    ModelBadges(job: job, compact: true)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    if let cost = job.cost { Cost(value: cost) }
                    Text(job.startedAt, style: .timer).font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
        }
    }

    /// "Reviewing #343", "Fixing #326", or the schedule's name.
    private func title(of job: Job) -> String {
        if let entry = schedules.first(where: { $0.item == job.key.item }) {
            return entry.name + (store.focus[job.id].map { " · on #\($0)" } ?? "")
        }
        let verb = switch job.key.move {
        case "review": "Reviewing"
        case "fix": "Fixing"
        case "merge": "Merging"
        default: job.key.move.capitalized
        }
        let number = job.key.item.hasPrefix("pr-") ? " #\(job.key.item.dropFirst(3))" : " \(job.key.item)"
        return verb + number + " · " + (job.key.repo.split(separator: "/").last.map(String.init) ?? job.key.repo)
    }
}
