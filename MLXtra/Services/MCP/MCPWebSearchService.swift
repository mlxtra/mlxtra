import Foundation

struct MCPServerConfig {
    let url: URL
}

private enum MCPHTTPTimeout {
    static let request: TimeInterval = 15
    static let resource: TimeInterval = 30
}

struct MCPTool {
    let name: String
    let description: String
    let inputProperties: [String: Any]
}

enum MCPError: LocalizedError {
    case invalidResponse
    case missingTool
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid MCP response"
        case .missingTool:
            return "No MCP search tool found"
        case .serverError(let message):
            return message
        }
    }
}

private func stringifyJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }

    return string
}

@MainActor
final class MCPWebSearchService {
    private let servers: [String: MCPServerConfig]

    init(
        servers: [String: MCPServerConfig] = [
            "exa": MCPServerConfig(url: URL(string: "https://mcp.exa.ai/mcp")!)
        ]
    ) {
        self.servers = servers
    }

    func searchContext(for query: String) async throws -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        for (name, config) in servers {
            let client = MCPHTTPClient(serverName: name, url: config.url)
            try await client.initialize()

            let tools = try await client.listTools()
            guard let tool = chooseSearchTool(from: tools) else {
                continue
            }

            let result = try await client.callTool(
                name: tool.name,
                arguments: searchArguments(for: tool, query: trimmedQuery)
            )
            let text = extractText(fromToolResult: result)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                return """
                Live web search results from MCP server '\(name)' using tool '\(tool.name)' for query: \(trimmedQuery)

                \(text)
                """
            }
        }

        throw MCPError.missingTool
    }

    func chooseSearchTool(from tools: [MCPTool]) -> MCPTool? {
        tools.first { tool in
            let name = tool.name.lowercased()
            let description = tool.description.lowercased()
            return name.contains("search") || description.contains("web search")
        }
    }

    func searchArguments(for tool: MCPTool, query: String) -> [String: Any] {
        var arguments: [String: Any] = [:]

        if tool.inputProperties["query"] != nil {
            arguments["query"] = query
        } else if tool.inputProperties["q"] != nil {
            arguments["q"] = query
        } else {
            arguments["query"] = query
        }

        for countKey in ["numResults", "num_results", "maxResults", "max_results", "limit"] {
            if tool.inputProperties[countKey] != nil {
                arguments[countKey] = 5
                break
            }
        }

        return arguments
    }

    func extractText(fromToolResult result: [String: Any]) -> String {
        if let content = result["content"] as? [[String: Any]] {
            let parts = content.compactMap { item -> String? in
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    return text
                }
                return item["text"] as? String
            }

            if !parts.isEmpty {
                return parts.joined(separator: "\n\n")
            }
        }

        if let structuredContent = result["structuredContent"] {
            return stringifyJSON(structuredContent)
        }

        return stringifyJSON(result)
    }
}

@MainActor
private final class MCPHTTPClient {
    private let serverName: String
    private let url: URL
    private let session: URLSession
    private var sessionId: String?
    private var nextRequestId = 1

    init(serverName: String, url: URL) {
        self.serverName = serverName
        self.url = url

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = MCPHTTPTimeout.request
        configuration.timeoutIntervalForResource = MCPHTTPTimeout.resource
        self.session = URLSession(configuration: configuration)
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": [
                    "name": "MLXtra",
                    "version": "1.0"
                ]
            ]
        )
        try await notify(method: "notifications/initialized", params: [:])
    }

    func listTools() async throws -> [MCPTool] {
        let result = try await request(method: "tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else {
            return []
        }

        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else {
                return nil
            }

            let inputSchema = tool["inputSchema"] as? [String: Any]
            let properties = inputSchema?["properties"] as? [String: Any] ?? [:]

            return MCPTool(
                name: name,
                description: tool["description"] as? String ?? "",
                inputProperties: properties
            )
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await request(
            method: "tools/call",
            params: [
                "name": name,
                "arguments": arguments
            ]
        )
    }

    private func notify(method: String, params: [String: Any]) async throws {
        _ = try await post([
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ])
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestId = nextRequestId
        nextRequestId += 1

        let responses = try await post([
            "jsonrpc": "2.0",
            "id": requestId,
            "method": method,
            "params": params
        ])

        for response in responses {
            guard response["id"] as? Int == requestId else {
                continue
            }

            if let error = response["error"] {
                throw MCPError.serverError(stringifyJSON(error))
            }

            return response["result"] as? [String: Any] ?? [:]
        }

        throw MCPError.serverError("\(serverName) did not return a response for \(method)")
    }

    private func post(_ payload: [String: Any]) async throws -> [[String: Any]] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = MCPHTTPTimeout.request
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.invalidResponse
        }

        if let sessionId = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            self.sessionId = sessionId
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw MCPError.serverError(message)
        }

        guard !data.isEmpty, let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            return []
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") || body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("event:") {
            return try parseSSE(body)
        }

        let json = try JSONSerialization.jsonObject(with: data)
        if let responses = json as? [[String: Any]] {
            return responses
        }
        if let response = json as? [String: Any] {
            return [response]
        }

        throw MCPError.invalidResponse
    }

    private func parseSSE(_ body: String) throws -> [[String: Any]] {
        var responses: [[String: Any]] = []
        for event in body.components(separatedBy: "\n\n") {
            let dataLines = event
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    guard line.hasPrefix("data:") else { return nil }
                    return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                }

            guard !dataLines.isEmpty else {
                continue
            }

            let dataString = dataLines.joined(separator: "\n")
            guard dataString != "[DONE]", let data = dataString.data(using: .utf8) else {
                continue
            }

            if let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                responses.append(response)
            }
        }

        return responses
    }
}
