import XCTest
@testable import MLXHub

final class PromptConfigurationTests: XCTestCase {
    func testBlankPromptFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("   \n", forKey: PromptConfiguration.systemPromptKey)

        XCTAssertEqual(
            PromptConfiguration.systemPrompt(userDefaults: defaults),
            PromptConfiguration.defaultSystemPrompt
        )
    }

    func testCustomDeepResearchPromptIsUsed() {
        let defaults = makeDefaults()
        defaults.set("Custom research prompt", forKey: PromptConfiguration.deepResearchSystemPromptKey)

        XCTAssertEqual(
            PromptConfiguration.deepResearchSystemPrompt(userDefaults: defaults),
            "Custom research prompt"
        )
    }

    func testCustomToolDefinitionsAreParsed() {
        let defaults = makeDefaults()
        defaults.set(
            """
            [
              {
                "type": "function",
                "function": {
                  "name": "web_search",
                  "description": "Custom search",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "query": { "type": "string" }
                    },
                    "required": ["query"]
                  }
                }
              }
            ]
            """,
            forKey: PromptConfiguration.toolDefinitionsKey
        )

        let tools = PromptConfiguration.toolDefinitions(userDefaults: defaults)

        XCTAssertEqual(tools.count, 1)
        let function = tools[0]["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "web_search")
        XCTAssertEqual(function?["description"] as? String, "Custom search")
        XCTAssertNil(PromptConfiguration.toolDefinitionsValidationMessage(defaults.string(forKey: PromptConfiguration.toolDefinitionsKey) ?? ""))
    }

    func testInvalidToolDefinitionsFallBackToBuiltInsAndReportValidationMessage() {
        let defaults = makeDefaults()
        defaults.set("{ invalid json", forKey: PromptConfiguration.toolDefinitionsKey)

        XCTAssertEqual(
            PromptConfiguration.toolDefinitions(userDefaults: defaults).count,
            PromptConfiguration.builtInToolDefinitions.count
        )
        XCTAssertNotNil(PromptConfiguration.toolDefinitionsValidationMessage("{ invalid json"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MLXHub.PromptConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
