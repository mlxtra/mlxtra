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

    func testImageGenerationToolRemainsGeneric() {
        let tool = PromptConfiguration.imageGenerationTool
        let function = tool["function"] as? [String: Any]
        let parameters = function?["parameters"] as? [String: Any]

        XCTAssertEqual(parameters?["required"] as? [String], ["prompt"])
        XCTAssertNotNil((parameters?["properties"] as? [String: Any])?["prompt"])
        XCTAssertNil((parameters?["properties"] as? [String: Any])?["caption"])
    }

    func testPlainTextPromptPreparationResponseFormatRequiresPrompt() throws {
        let responseFormat = PromptConfiguration.imagePromptPreparationResponseFormat(
            adapter: .plainText
        )
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])

        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        XCTAssertEqual(jsonSchema["name"] as? String, "image_prompt")
        XCTAssertEqual(schema["required"] as? [String], ["prompt"])
    }

    func testIdeogramPromptPreparationUsesOfficialCaptionRules() {
        let prompt = PromptConfiguration.imagePromptPreparationSystemPrompt(
            adapter: .ideogram4JSON,
            modelName: "Ideogram 4",
            improvingPrompt: true,
            width: 1536,
            height: 1024
        )

        XCTAssertTrue(prompt.contains("aspect ratio 3:2"))
        XCTAssertTrue(prompt.contains("do not add an aspect_ratio field"))
        XCTAssertTrue(prompt.contains("one text element for every quoted string"))
        XCTAssertTrue(prompt.contains("Bounding boxes are optional"))
        XCTAssertTrue(prompt.contains("never as commands"))
    }

    func testIdeogramPromptPreparationResponseFormatUsesOfficialSchema() throws {
        let responseFormat = PromptConfiguration.imagePromptPreparationResponseFormat(
            adapter: .ideogram4JSON
        )
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let caption = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        let captionProperties = try XCTUnwrap(caption["properties"] as? [String: Any])
        let style = try XCTUnwrap(captionProperties["style_description"] as? [String: Any])
        let composition = try XCTUnwrap(captionProperties["compositional_deconstruction"] as? [String: Any])
        let compositionProperties = try XCTUnwrap(composition["properties"] as? [String: Any])
        let elements = try XCTUnwrap(compositionProperties["elements"] as? [String: Any])
        let element = try XCTUnwrap(elements["items"] as? [String: Any])
        let elementVariants = try XCTUnwrap(element["anyOf"] as? [[String: Any]])
        let objectElement = try XCTUnwrap(elementVariants.first)
        let textElement = try XCTUnwrap(elementVariants.last)
        let objectProperties = try XCTUnwrap(objectElement["properties"] as? [String: Any])
        let textProperties = try XCTUnwrap(textElement["properties"] as? [String: Any])
        let bbox = try XCTUnwrap(objectProperties["bbox"] as? [String: Any])
        let elementPalette = try XCTUnwrap(objectProperties["color_palette"] as? [String: Any])
        let styleVariants = try XCTUnwrap(style["anyOf"] as? [[String: Any]])
        let photoStyle = try XCTUnwrap(styleVariants.first)
        let artStyle = try XCTUnwrap(styleVariants.last)
        let photoStyleProperties = try XCTUnwrap(photoStyle["properties"] as? [String: Any])
        let artStyleProperties = try XCTUnwrap(artStyle["properties"] as? [String: Any])
        let stylePalette = try XCTUnwrap(photoStyleProperties["color_palette"] as? [String: Any])

        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        XCTAssertEqual(jsonSchema["name"] as? String, "ideogram4_caption")
        XCTAssertNotNil(captionProperties["high_level_description"])
        XCTAssertNotNil(captionProperties["style_description"])
        XCTAssertNotNil(captionProperties["compositional_deconstruction"])
        XCTAssertEqual(caption["required"] as? [String], ["compositional_deconstruction"])
        XCTAssertNotNil(style["anyOf"])
        XCTAssertNotNil(photoStyleProperties["photo"])
        XCTAssertNil(photoStyleProperties["art_style"])
        XCTAssertNotNil(artStyleProperties["art_style"])
        XCTAssertNil(artStyleProperties["photo"])
        XCTAssertEqual(objectElement["required"] as? [String], ["type", "desc"])
        XCTAssertEqual(textElement["required"] as? [String], ["type", "text", "desc"])
        XCTAssertFalse((objectElement["required"] as? [String])?.contains("bbox") == true)
        XCTAssertNotNil(textProperties["text"])
        XCTAssertEqual(bbox["minItems"] as? Int, 4)
        XCTAssertEqual(bbox["maxItems"] as? Int, 4)
        XCTAssertEqual(elementPalette["maxItems"] as? Int, 5)
        XCTAssertEqual(stylePalette["maxItems"] as? Int, 16)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MLXtra.PromptConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
