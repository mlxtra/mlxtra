import Foundation

enum PromptConfiguration {
    static let systemPromptKey = "MLXHub.systemPrompt"
    static let deepResearchSystemPromptKey = "MLXHub.deepResearchSystemPrompt"
    static let toolDefinitionsKey = "MLXHub.toolDefinitionsJSON"
    static let hasSeenFirstRunGuideKey = "MLXHub.hasSeenFirstRunGuide"

    static let defaultSystemPrompt = """
    You are a helpful assistant.

    Use only tools that are explicitly available in the current mode. If no tool is available, answer normally or ask the user to switch modes. Never write, simulate, or mention a tool call for an unavailable tool.
    """

    static let defaultDeepResearchSystemPrompt = """
    You are running Research mode.

    Research expectations:
    - Use web_search for the user's main question before answering.
    - Search again when the first result is thin, contradictory, missing dates, or does not answer the question directly.
    - Prefer primary sources, official documentation, papers, standards, company pages, and reputable reporting.
    - Make dates explicit when recency matters.
    - Separate what the sources say from your own synthesis when the distinction matters.
    - Call out uncertainty, conflicts, and gaps instead of overstating weak evidence.
    - End with a concise answer that is useful without exposing internal tool mechanics.
    """

    static var defaultToolDefinitionsJSON: String {
        prettyPrintedJSON(builtInToolDefinitions)
    }

    static var builtInToolDefinitions: [[String: Any]] {
        [webSearchTool, imageGenerationTool, speechGenerationTool, musicGenerationTool]
    }

    static var webSearchTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current information, news, facts, or any topic that requires up-to-date data.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query"]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    static var imageGenerationTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "generate_image",
                "description": "Generate or edit an image when the user explicitly asks for a new visual, image, illustration, photo, mockup, sprite, texture, or image edit. Do not use this tool for describing or analyzing attached images.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prompt": [
                            "type": "string",
                            "description": "A detailed image generation or image editing prompt."
                        ]
                    ],
                    "required": ["prompt"]
                ]
            ]
        ]
    }

    static var speechGenerationTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "create_speech",
                "description": "Create spoken audio from text when the user asks for text-to-speech, narration, voiceover, or speech audio.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "The exact text to turn into spoken audio."
                        ]
                    ],
                    "required": ["text"]
                ]
            ]
        ]
    }

    static var musicGenerationTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "generate_music",
                "description": "Create music only when the user has either requested instrumental/no-vocal music or approved/provided lyrics for vocals. Ask a follow-up instead of calling this tool when that choice is unclear.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "caption": [
                            "type": "string",
                            "description": "A concise music prompt describing genre, mood, instruments, tempo, vocals, and use case."
                        ],
                        "lyrics": [
                            "type": "string",
                            "description": "Lyrics with section labels like [verse] and [chorus]. Required when instrumental is false."
                        ],
                        "duration": [
                            "type": "number",
                            "description": "Optional duration in seconds. Use 30 unless the user asks otherwise."
                        ],
                        "instrumental": [
                            "type": "boolean",
                            "description": "True only for instrumental, beat, backing track, background music, or no-vocal requests. False only when lyrics are provided or approved."
                        ]
                    ],
                    "required": ["caption", "instrumental"]
                ]
            ]
        ]
    }

    static func systemPrompt(userDefaults: UserDefaults = .standard) -> String {
        resolvedText(forKey: systemPromptKey, defaultValue: defaultSystemPrompt, userDefaults: userDefaults)
    }

    static func deepResearchSystemPrompt(userDefaults: UserDefaults = .standard) -> String {
        resolvedText(forKey: deepResearchSystemPromptKey, defaultValue: defaultDeepResearchSystemPrompt, userDefaults: userDefaults)
    }

    static func toolDefinitions(userDefaults: UserDefaults = .standard) -> [[String: Any]] {
        let storedText = userDefaults.string(forKey: toolDefinitionsKey) ?? defaultToolDefinitionsJSON
        return parsedToolDefinitions(from: storedText) ?? builtInToolDefinitions
    }

    static func toolDefinition(named name: String, userDefaults: UserDefaults = .standard) -> [String: Any]? {
        toolDefinitions(userDefaults: userDefaults).first { toolName(in: $0) == name }
            ?? builtInToolDefinitions.first { toolName(in: $0) == name }
    }

    static func toolDefinitionsValidationMessage(_ text: String) -> String? {
        parsedToolDefinitions(from: text) == nil
            ? "Tool definitions must be a JSON array of supported function tools with object parameters."
            : nil
    }

    private static func resolvedText(forKey key: String, defaultValue: String, userDefaults: UserDefaults) -> String {
        let value = userDefaults.string(forKey: key) ?? defaultValue
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : value
    }

    private static func parsedToolDefinitions(from text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let tools = value as? [[String: Any]] else {
            return nil
        }

        let validTools = tools.compactMap { validToolDefinition($0) }
        guard !validTools.isEmpty, validTools.count == tools.count else {
            return nil
        }

        return validTools
    }

    private static func toolName(in tool: [String: Any]) -> String? {
        guard let function = tool["function"] as? [String: Any],
              let name = function["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return name
    }

    private static func validToolDefinition(_ tool: [String: Any]) -> [String: Any]? {
        guard tool["type"] as? String == "function",
              let function = tool["function"] as? [String: Any],
              let name = toolName(in: tool),
              supportedToolNames.contains(name),
              let parameters = function["parameters"] as? [String: Any],
              parameters["type"] as? String == "object",
              let properties = parameters["properties"] as? [String: Any],
              !properties.isEmpty else {
            return nil
        }

        if parameters["required"] != nil {
            guard let required = parameters["required"] as? [String] else {
                return nil
            }
            guard required.allSatisfy({ properties[$0] != nil }) else {
                return nil
            }
        }

        return tool
    }

    private static let supportedToolNames: Set<String> = [
        "web_search",
        "generate_image",
        "create_speech",
        "generate_music"
    ]

    private static func prettyPrintedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return string
    }
}
