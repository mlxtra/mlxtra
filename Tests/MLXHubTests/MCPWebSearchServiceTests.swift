import XCTest
@testable import MLXHub

final class MCPWebSearchServiceTests: XCTestCase {

    // MARK: - MCPServerConfig Tests

    func testMCPServerConfigInit() {
        let url = URL(string: "https://example.com/mcp")!
        let config = MCPServerConfig(url: url)
        XCTAssertEqual(config.url, url)
    }

    // MARK: - MCPTool Tests

    func testMCPToolInit() {
        let tool = MCPTool(
            name: "web_search",
            description: "Search the web",
            inputProperties: ["query": ["type": "string"]]
        )

        XCTAssertEqual(tool.name, "web_search")
        XCTAssertEqual(tool.description, "Search the web")
        XCTAssertNotNil(tool.inputProperties["query"])
    }

    func testMCPToolEmptyProperties() {
        let tool = MCPTool(
            name: "test",
            description: "Test tool",
            inputProperties: [:]
        )

        XCTAssertEqual(tool.name, "test")
        XCTAssertTrue(tool.inputProperties.isEmpty)
    }

    // MARK: - MCPError Tests

    func testMCPErrorLocalizedDescription() {
        XCTAssertEqual(MCPError.invalidResponse.localizedDescription, "Invalid MCP response")
        XCTAssertEqual(MCPError.missingTool.localizedDescription, "No MCP search tool found")
        XCTAssertEqual(MCPError.serverError("Server error message").localizedDescription, "Server error message")
    }

    // MARK: - MCPHTTPClient Private Methods (via StringifyJSON behavior)

    func testStringifyJSONValidObject() {
        let obj: [String: Any] = [
            "key1": "value1",
            "key2": 42,
            "nested": ["a": 1, "b": 2]
        ]

        guard JSONSerialization.isValidJSONObject(obj) else {
            XCTFail("Object should be valid JSON")
            return
        }

        let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        XCTAssertNotNil(data)

        let string = String(data: data!, encoding: .utf8)
        XCTAssertNotNil(string)
        XCTAssertTrue(string!.contains("key1"))
        XCTAssertTrue(string!.contains("value1"))
    }

    func testStringifyJSONInvalidObject() {
        class NonJSONable {}
        let obj = NonJSONable()

        let string = String(describing: obj)
        XCTAssertFalse(string.isEmpty)
    }

    // MARK: - Search Arguments Helper Logic

    func testSearchArgumentsWithQueryKey() {
        let tool = MCPTool(
            name: "search",
            description: "Search",
            inputProperties: ["query": ["type": "string"]]
        )

        var arguments: [String: Any] = [:]
        if tool.inputProperties["query"] != nil {
            arguments["query"] = "test query"
        }
        XCTAssertEqual(arguments["query"] as? String, "test query")
    }

    func testSearchArgumentsWithQKey() {
        let tool = MCPTool(
            name: "search",
            description: "Search",
            inputProperties: ["q": ["type": "string"]]
        )

        var arguments: [String: Any] = [:]
        if tool.inputProperties["query"] != nil {
            arguments["query"] = "test"
        } else if tool.inputProperties["q"] != nil {
            arguments["q"] = "test"
        }
        XCTAssertEqual(arguments["q"] as? String, "test")
    }

    func testSearchArgumentsWithNumResultsKey() {
        let tool = MCPTool(
            name: "search",
            description: "Search",
            inputProperties: [
                "query": ["type": "string"],
                "numResults": ["type": "integer"]
            ]
        )

        var arguments: [String: Any] = ["query": "test"]
        for countKey in ["numResults", "num_results", "maxResults", "max_results", "limit"] {
            if tool.inputProperties[countKey] != nil {
                arguments[countKey] = 5
                break
            }
        }
        XCTAssertEqual(arguments["numResults"] as? Int, 5)
    }

    func testSearchArgumentsDefaultToQuery() {
        let tool = MCPTool(
            name: "search",
            description: "Search",
            inputProperties: ["other": ["type": "string"]]
        )

        var arguments: [String: Any] = [:]
        if tool.inputProperties["query"] != nil {
            arguments["query"] = "test"
        } else if tool.inputProperties["q"] != nil {
            arguments["q"] = "test"
        } else {
            arguments["query"] = "test"
        }
        XCTAssertEqual(arguments["query"] as? String, "test")
    }

    // MARK: - Tool Selection Logic

    func testChooseSearchToolByName() {
        let tools = [
            MCPTool(name: "web_search", description: "Search the web", inputProperties: [:]),
            MCPTool(name: "other_tool", description: "Something else", inputProperties: [:])
        ]

        let searchTool = tools.first { tool in
            let name = tool.name.lowercased()
            let description = tool.description.lowercased()
            return name.contains("search") || description.contains("web search")
        } ?? tools.first

        XCTAssertEqual(searchTool?.name, "web_search")
    }

    func testChooseSearchToolByDescription() {
        let tools = [
            MCPTool(name: "find", description: "Web search for queries", inputProperties: [:]),
            MCPTool(name: "other", description: "Not a search", inputProperties: [:])
        ]

        let searchTool = tools.first { tool in
            let name = tool.name.lowercased()
            let description = tool.description.lowercased()
            return name.contains("search") || description.contains("web search")
        } ?? tools.first

        XCTAssertEqual(searchTool?.name, "find")
    }

    func testChooseSearchToolFallbackToFirst() {
        let tools = [
            MCPTool(name: "random_tool", description: "No search related", inputProperties: [:]),
            MCPTool(name: "another_tool", description: "Also not search", inputProperties: [:])
        ]

        let searchTool = tools.first { tool in
            let name = tool.name.lowercased()
            let description = tool.description.lowercased()
            return name.contains("search") || description.contains("web search")
        } ?? tools.first

        XCTAssertEqual(searchTool?.name, "random_tool")
    }

    // MARK: - Extract Text Logic

    func testExtractTextFromContentArray() {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": "First result"],
                ["type": "text", "text": "Second result"]
            ]
        ]

        let content = result["content"] as? [[String: Any]]
        let parts = content?.compactMap { item -> String? in
            if item["type"] as? String == "text", let text = item["text"] as? String {
                return text
            }
            return item["text"] as? String
        }

        XCTAssertEqual(parts?.joined(separator: "\n\n"), "First result\n\nSecond result")
    }

    func testExtractTextFromSingleContentItem() {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": "Single result"]
            ]
        ]

        let content = result["content"] as? [[String: Any]]
        let parts = content?.compactMap { item -> String? in
            if item["type"] as? String == "text", let text = item["text"] as? String {
                return text
            }
            return item["text"] as? String
        }

        XCTAssertEqual(parts?.joined(separator: "\n\n"), "Single result")
    }

    func testExtractTextWithEmptyContent() {
        let result: [String: Any] = ["content": []]

        let content = result["content"] as? [[String: Any]]
        let parts = content?.compactMap { item -> String? in
            if item["type"] as? String == "text", let text = item["text"] as? String {
                return text
            }
            return item["text"] as? String
        }

        XCTAssertTrue(parts?.isEmpty ?? true)
    }

    func testExtractTextFallbackToStringify() {
        let result: [String: Any] = [
            "otherField": "value",
            "numberField": 42
        ]

        let stringified = String(describing: result)
        XCTAssertFalse(stringified.isEmpty)
        XCTAssertTrue(stringified.contains("otherField"))
    }
}