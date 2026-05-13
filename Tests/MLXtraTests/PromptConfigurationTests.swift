import XCTest
@testable import MLXtra

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

    func testCustomToolDefinitionsRejectUnsupportedToolNames() {
        let text = """
        [
          {
            "type": "function",
            "function": {
              "name": "delete_file",
              "parameters": {
                "type": "object",
                "properties": {
                  "path": { "type": "string" }
                }
              }
            }
          }
        ]
        """

        XCTAssertNotNil(PromptConfiguration.toolDefinitionsValidationMessage(text))
    }

    func testCustomToolDefinitionsRequireObjectParameters() {
        let text = """
        [
          {
            "type": "function",
            "function": {
              "name": "web_search",
              "parameters": {
                "type": "string"
              }
            }
          }
        ]
        """

        XCTAssertNotNil(PromptConfiguration.toolDefinitionsValidationMessage(text))
    }

    func testCustomToolDefinitionsRejectMalformedRequiredList() {
        let text = """
        [
          {
            "type": "function",
            "function": {
              "name": "web_search",
              "parameters": {
                "type": "object",
                "properties": {
                  "query": { "type": "string" }
                },
                "required": "query"
              }
            }
          }
        ]
        """

        XCTAssertNotNil(PromptConfiguration.toolDefinitionsValidationMessage(text))
    }

    func testCustomToolDefinitionsRejectRequiredKeysMissingFromProperties() {
        let text = """
        [
          {
            "type": "function",
            "function": {
              "name": "web_search",
              "parameters": {
                "type": "object",
                "properties": {
                  "query": { "type": "string" }
                },
                "required": ["query", "extra"]
              }
            }
          }
        ]
        """

        XCTAssertNotNil(PromptConfiguration.toolDefinitionsValidationMessage(text))
    }

    func testRestoreToolsDefaultContainsAllBuiltInToolNames() {
        let text = PromptConfiguration.defaultToolDefinitionsJSON
        XCTAssertNil(PromptConfiguration.toolDefinitionsValidationMessage(text))

        let tools = PromptConfiguration.toolDefinitions(userDefaults: makeDefaults())
        let names = tools.compactMap { tool -> String? in
            (tool["function"] as? [String: Any])?["name"] as? String
        }

        XCTAssertEqual(Set(names), ["web_search", "generate_image", "create_speech", "generate_music"])
    }

    func testToolDefinitionFallsBackToBuiltInWhenCustomListOmitsTool() {
        let defaults = makeDefaults()
        defaults.set(
            """
            [
              {
                "type": "function",
                "function": {
                  "name": "web_search",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "query": { "type": "string" }
                    }
                  }
                }
              }
            ]
            """,
            forKey: PromptConfiguration.toolDefinitionsKey
        )

        let imageTool = PromptConfiguration.toolDefinition(named: "generate_image", userDefaults: defaults)
        let function = imageTool?["function"] as? [String: Any]

        XCTAssertEqual(function?["name"] as? String, "generate_image")
    }

    func testMusicToolRequiresExplicitInstrumentalFlag() {
        let function = PromptConfiguration.musicGenerationTool["function"] as? [String: Any]
        let parameters = function?["parameters"] as? [String: Any]
        let required = parameters?["required"] as? [String]

        XCTAssertEqual(required, ["caption", "instrumental"])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MLXtra.PromptConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
