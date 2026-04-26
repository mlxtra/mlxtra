import Foundation

enum PromptConfiguration {
    static let systemPromptKey = "MLXHub.systemPrompt"
    static let deepResearchSystemPromptKey = "MLXHub.deepResearchSystemPrompt"
    static let toolDefinitionsKey = "MLXHub.toolDefinitionsJSON"
    static let hasSeenFirstRunGuideKey = "MLXHub.hasSeenFirstRunGuide"

    static let defaultSystemPrompt = """
    You are a helpful assistant.

    When the user asks you to create, generate, draw, edit, or make an image, use the generate_image tool. If the image needs current information, use web_search first, then use generate_image with the current information from the search result. Do not generate markdown image tags, image URLs, data URLs, or links to external image services. After the generate_image tool runs, the app displays the image automatically; respond with concise text only.

    When the user asks you to create speech, narration, voiceover, or text-to-speech audio, use the create_speech tool with the exact text that should be spoken. After the create_speech tool runs, the app displays the audio automatically; respond with concise text only and do not include local file paths.

    When the user asks you to create music, a song, beat, loop, soundtrack, instrumental, or background music, do not call generate_music until the request is ready.

    Music readiness rules:
    - If the user clearly asks for instrumental music, a beat, background music, a backing track, or no vocals, call generate_music with instrumental=true.
    - If the user does not say whether they want instrumental music or vocals, ask: "Would you like instrumental music, or should I include vocals with lyrics? If you'd like lyrics, you can provide your own or I can write them for you."
    - If the user wants vocals and provides lyrics, call generate_music with those lyrics.
    - If the user wants vocals but does not provide lyrics, write lyrics with section labels like [verse], [chorus], and [bridge], then ask: "Here are the lyrics I wrote for your song:\\n\\n<lyrics>\\n\\nDo these look good, or would you like me to change anything before I generate the music?"
    - If you wrote or revised lyrics, wait for explicit user approval before calling generate_music.
    - After generate_music runs, the app displays the audio automatically; respond with concise text only and do not include local file paths.
    """

    static let defaultDeepResearchSystemPrompt = """
    You are running Deep Research mode.

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
                "description": "Create a song, instrumental track, beat, loop, background music, or music sample only after the user has specified instrumental music or approved lyrics for vocals.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "caption": [
                            "type": "string",
                            "description": "A concise music prompt describing genre, mood, instruments, tempo, vocals, and use case."
                        ],
                        "lyrics": [
                            "type": "string",
                            "description": "Optional lyrics with section labels like [verse] and [chorus]."
                        ],
                        "duration": [
                            "type": "number",
                            "description": "Optional duration in seconds. Use 30 unless the user asks otherwise."
                        ],
                        "instrumental": [
                            "type": "boolean",
                            "description": "True when the user asks for instrumental, beat, backing track, or no vocals."
                        ]
                    ],
                    "required": ["caption"]
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
            ? "Tool definitions must be a JSON array of function tools with names."
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

        let validTools = tools.filter { toolName(in: $0) != nil }
        return validTools.isEmpty ? nil : validTools
    }

    private static func toolName(in tool: [String: Any]) -> String? {
        guard let function = tool["function"] as? [String: Any],
              let name = function["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return name
    }

    private static func prettyPrintedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return string
    }
}
