import XCTest
@testable import MLXtra

@MainActor
final class MCPWebSearchServiceTests: XCTestCase {
    func testMCPServerConfigInit() {
        let url = URL(string: "https://example.com/mcp")!
        let config = MCPServerConfig(url: url)

        XCTAssertEqual(config.url, url)
    }

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

    func testMCPErrorLocalizedDescription() {
        XCTAssertEqual(MCPError.invalidResponse.localizedDescription, "Invalid MCP response")
        XCTAssertEqual(MCPError.missingTool.localizedDescription, "No MCP search tool found")
        XCTAssertEqual(MCPError.serverError("Server error message").localizedDescription, "Server error message")
    }

    func testSearchArgumentsUseQueryKey() {
        let service = MCPWebSearchService()
        let tool = MCPTool(
            name: "search",
            description: "Search",
            inputProperties: ["query": ["type": "string"]]
        )

        let arguments = service.searchArguments(for: tool, query: "test query")

        XCTAssertEqual(arguments["query"] as? String, "test query")
    }

    func testSearchArgumentsUseQKeyWhenPresent() {
        let service = MCPWebSearchService()
        let tool = MCPTool(
            name: "search",
            description: "Search",
            inputProperties: ["q": ["type": "string"]]
        )

        let arguments = service.searchArguments(for: tool, query: "test")

        XCTAssertEqual(arguments["q"] as? String, "test")
        XCTAssertNil(arguments["query"])
    }

    func testSearchArgumentsIncludeFirstSupportedResultLimitKey() {
        let service = MCPWebSearchService()
        let tool = MCPTool(
            name: "search",
            description: "Search",
            inputProperties: [
                "query": ["type": "string"],
                "numResults": ["type": "integer"]
            ]
        )

        let arguments = service.searchArguments(for: tool, query: "test")

        XCTAssertEqual(arguments["query"] as? String, "test")
        XCTAssertEqual(arguments["numResults"] as? Int, 5)
    }

    func testSearchArgumentsDefaultToQueryWhenSchemaHasNoKnownQueryKey() {
        let service = MCPWebSearchService()
        let tool = MCPTool(
            name: "search",
            description: "Search",
            inputProperties: ["other": ["type": "string"]]
        )

        let arguments = service.searchArguments(for: tool, query: "test")

        XCTAssertEqual(arguments["query"] as? String, "test")
    }

    func testChooseSearchToolByName() {
        let service = MCPWebSearchService()
        let tools = [
            MCPTool(name: "web_search", description: "Search the web", inputProperties: [:]),
            MCPTool(name: "other_tool", description: "Something else", inputProperties: [:])
        ]

        let searchTool = service.chooseSearchTool(from: tools)

        XCTAssertEqual(searchTool?.name, "web_search")
    }

    func testChooseSearchToolByDescription() {
        let service = MCPWebSearchService()
        let tools = [
            MCPTool(name: "find", description: "Web search for queries", inputProperties: [:]),
            MCPTool(name: "other", description: "Not a search", inputProperties: [:])
        ]

        let searchTool = service.chooseSearchTool(from: tools)

        XCTAssertEqual(searchTool?.name, "find")
    }

    func testChooseSearchToolReturnsNilWhenNoSearchToolExists() {
        let service = MCPWebSearchService()
        let tools = [
            MCPTool(name: "random_tool", description: "No related capability", inputProperties: [:]),
            MCPTool(name: "another_tool", description: "Also unrelated", inputProperties: [:])
        ]

        let searchTool = service.chooseSearchTool(from: tools)

        XCTAssertNil(searchTool)
    }

    func testExtractTextFromContentArray() {
        let service = MCPWebSearchService()
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": "First result"],
                ["type": "text", "text": "Second result"]
            ]
        ]

        let text = service.extractText(fromToolResult: result)

        XCTAssertEqual(text, "First result\n\nSecond result")
    }

    func testExtractTextWithEmptyContentFallsBackToStringifiedResult() {
        let service = MCPWebSearchService()
        let result: [String: Any] = ["content": []]

        let text = service.extractText(fromToolResult: result)

        XCTAssertTrue(text.contains("content"))
    }

    func testExtractTextFallbackToStringify() {
        let service = MCPWebSearchService()
        let result: [String: Any] = [
            "otherField": "value",
            "numberField": 42
        ]

        let text = service.extractText(fromToolResult: result)

        XCTAssertTrue(text.contains("otherField"))
        XCTAssertTrue(text.contains("numberField"))
    }
}
