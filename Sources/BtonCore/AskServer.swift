import Foundation

/// Bton's MCP server for a job (`bton ask-server`), over JSON-RPC 2.0, one message per line: `ask`
/// for the job's helpers, and `graph` for the code graph when the job has one. Only the helpers
/// Bton named when it started the job can be asked, and `graph` runs one fixed program; the
/// agent's arguments never choose one.
public struct AskServer: Sendable {
    let helpers: [String]
    let graph: (@Sendable (_ question: String) async -> Helpers.AskResult)?
    let ask: @Sendable (_ agent: String, _ question: String) async -> Helpers.AskResult

    public init(helpers: [String], graph: (@Sendable (_ question: String) async -> Helpers.AskResult)? = nil,
                ask: @escaping @Sendable (_ agent: String, _ question: String) async -> Helpers.AskResult) {
        self.helpers = helpers
        self.graph = graph
        self.ask = ask
    }

    /// The reply line, or nil when none is due (a notification).
    public func respond(to line: String) async -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let reply: [String: Any]
        switch message["method"] as? String {
        case "initialize":
            reply = ["result": [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "bton", "version": "1"],
            ]]
        case "ping":
            reply = ["result": [String: Any]()]
        case "tools/list":
            reply = ["result": ["tools": (helpers.isEmpty ? [] : [tool]) + (graph == nil ? [] : [graphTool])]]
        case "tools/call":
            reply = await call(params)
        default:
            reply = ["error": ["code": -32601, "message": "method not found"]]
        }
        return Self.encode(reply.merging(["jsonrpc": "2.0", "id": id]) { $1 })
    }

    private var tool: [String: Any] {
        [
            "name": "ask",
            "description": "Ask another agent for a second opinion. It works in the same checkout, read-only, "
                + "and does not see this conversation: put everything it needs in the question.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent": ["type": "string", "enum": helpers],
                    "question": ["type": "string"],
                ],
                "required": ["agent", "question"],
            ],
        ]
    }

    private var graphTool: [String: Any] {
        [
            "name": "graph",
            "description": "Ask the code graph of this checkout where something lives and how it connects: "
                + "question is what you look for. Answers with the graph's matches and source slices.",
            "inputSchema": [
                "type": "object",
                "properties": ["question": ["type": "string"]],
                "required": ["question"],
            ],
        ]
    }

    private func call(_ params: [String: Any]) async -> [String: Any] {
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        if params["name"] as? String == "graph", let graph {
            guard let question = arguments["question"] as? String else {
                return ["error": ["code": -32602, "message": "graph takes question, a string"]]
            }
            return Self.toolResult(await graph(question))
        }
        guard params["name"] as? String == "ask" else { return Self.toolResult(Helpers.AskResult(text: "unknown tool", isError: true)) }
        guard let agent = arguments["agent"] as? String, let question = arguments["question"] as? String else {
            return ["error": ["code": -32602, "message": "ask takes agent and question, both strings"]]
        }
        guard helpers.contains(agent) else {
            return Self.toolResult(Helpers.AskResult(text: "\(agent) is not one of this schedule's helpers", isError: true))
        }
        return Self.toolResult(await ask(agent, question))
    }

    private static func toolResult(_ result: Helpers.AskResult) -> [String: Any] {
        ["result": ["content": [["type": "text", "text": result.text]], "isError": result.isError]]
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
