import Foundation

/// An agent, model and effort as one line: `claude:sonnet medium`, `codex:gpt-5 high`. This Mac's
/// choice for a repo's work or reviews; the flow names the agent, this says how it runs here.
public struct AgentPick: Equatable, Sendable {
    public let agent: String
    public let model: String?
    public let effort: String?

    /// How hard an agent thinks, in the words `claude --effort` and codex's `model_reasoning_effort` take; the CLI refuses one its model lacks.
    public static let efforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    public init(agent: String, model: String? = nil, effort: String? = nil) {
        self.agent = agent
        self.model = model
        self.effort = effort
    }

    /// nil for text that is not an agent name, a valid model and a known effort, in that shape.
    public init?(_ text: String) {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count <= 2, let head = words.first else { return nil }
        let parts = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard BtonConfig.isAgentName(parts[0]) else { return nil }
        let model = parts.count == 2 ? parts[1] : nil
        if let model, !ScheduleEntry.isValidModel(model) { return nil }
        let effort = words.count == 2 ? words[1] : nil
        if let effort, !Self.efforts.contains(effort) { return nil }
        self.init(agent: parts[0], model: model, effort: effort)
    }

    public var text: String {
        [agent + (model.map { ":" + $0 } ?? ""), effort].compactMap { $0 }.joined(separator: " ")
    }
}
