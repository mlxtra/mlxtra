import Foundation

enum PromptConfiguration {
    static let systemPromptKey = "MLXtra.systemPrompt"
    static let deepResearchSystemPromptKey = "MLXtra.deepResearchSystemPrompt"
    static let toolDefinitionsKey = "MLXtra.toolDefinitionsJSON"
    static let hasSeenFirstRunGuideKey = "MLXtra.hasSeenFirstRunGuide"

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

    static func imagePromptPreparationSystemPrompt(
        adapter: ImagePromptAdapter,
        modelName: String,
        improvingPrompt: Bool,
        width: Int,
        height: Int
    ) -> String {
        var prompt = "You prepare a prompt for \(modelName). Return only JSON matching the provided response schema. Preserve the user's intent, requested wording, and constraints. If the latest user request is a follow-up, resolve it against the prior conversation, generated assets, and attached images so the returned prompt is standalone."
        if improvingPrompt {
            prompt += " Make the visual description more specific and useful to the image model."
        } else {
            prompt += " Do not add unrequested creative details."
        }

        if adapter == .ideogram4JSON {
            let aspectRatio = reducedAspectRatio(width: width, height: height)
            prompt += """

            Build the structured JSON caption described by the official Ideogram 4 prompting guide. The target image is \(width)x\(height), aspect ratio \(aspectRatio) (width:height). Use the aspect ratio only to plan the composition; do not add an aspect_ratio field to the caption.

            Always include a concrete high_level_description and compositional_deconstruction. Write descriptions as observations of the desired image, never as commands or as a copy of the user's request. The background must describe the actual scene, not a generic placeholder.

            Use one obj element for each explicitly named visual subject. Use one text element for every quoted string or other visible wording the user requests. Copy each text field verbatim, including capitalization, punctuation, line breaks, and non-ASCII characters. Do not hide requested lettering inside an obj description.

            Bounding boxes are optional. Include them only when useful for layout, using integer normalized [0, 1000] coordinates as [y_min, x_min, y_max, x_max] with y_min < y_max and x_min < x_max. If style_description is included, use exactly one of photo or art_style. Use only uppercase #RRGGBB values in color palettes.
            """
        } else {
            prompt += " Return a JSON object with a single non-empty prompt field."
        }
        return prompt
    }

    static func imagePromptPreparationResponseFormat(adapter: ImagePromptAdapter) -> [String: Any] {
        let name: String
        let schema: [String: Any]
        switch adapter {
        case .plainText:
            name = "image_prompt"
            schema = [
                "type": "object",
                "properties": [
                    "prompt": [
                        "type": "string",
                        "minLength": 1
                    ]
                ],
                "required": ["prompt"],
                "additionalProperties": false
            ]
        case .ideogram4JSON:
            name = "ideogram4_caption"
            schema = ideogram4CaptionSchema
        }

        return [
            "type": "json_schema",
            "json_schema": [
                "name": name,
                "strict": true,
                "schema": schema
            ]
        ]
    }

    private static var ideogram4CaptionSchema: [String: Any] {
        let colorPalette: [String: Any] = [
            "type": "array",
            "items": [
                "type": "string",
                "pattern": "^#[0-9A-F]{6}$"
            ]
        ]
        let bbox: [String: Any] = [
            "type": "array",
            "items": ["type": "integer", "minimum": 0, "maximum": 1000],
            "minItems": 4,
            "maxItems": 4
        ]
        let objectElement: [String: Any] = [
            "type": "object",
            "properties": [
                "type": [
                    "type": "string",
                    "enum": ["obj"]
                ],
                "bbox": bbox,
                "desc": ["type": "string", "minLength": 1],
                "color_palette": colorPalette.merging(["maxItems": 5]) { _, new in new }
            ],
            "required": ["type", "desc"],
            "additionalProperties": false
        ]
        let textElement: [String: Any] = [
            "type": "object",
            "properties": [
                "type": [
                    "type": "string",
                    "enum": ["text"]
                ],
                "bbox": bbox,
                "text": ["type": "string"],
                "desc": ["type": "string", "minLength": 1],
                "color_palette": colorPalette.merging(["maxItems": 5]) { _, new in new }
            ],
            "required": ["type", "text", "desc"],
            "additionalProperties": false
        ]
        let photoStyle: [String: Any] = [
            "type": "object",
            "properties": [
                "aesthetics": ["type": "string", "minLength": 1],
                "lighting": ["type": "string", "minLength": 1],
                "photo": ["type": "string", "minLength": 1],
                "medium": ["type": "string", "minLength": 1],
                "color_palette": colorPalette.merging(["maxItems": 16]) { _, new in new }
            ],
            "required": ["aesthetics", "lighting", "photo", "medium"],
            "additionalProperties": false
        ]
        let artStyle: [String: Any] = [
            "type": "object",
            "properties": [
                "aesthetics": ["type": "string", "minLength": 1],
                "lighting": ["type": "string", "minLength": 1],
                "medium": ["type": "string", "minLength": 1],
                "art_style": ["type": "string", "minLength": 1],
                "color_palette": colorPalette.merging(["maxItems": 16]) { _, new in new }
            ],
            "required": ["aesthetics", "lighting", "medium", "art_style"],
            "additionalProperties": false
        ]

        return [
            "type": "object",
            "properties": [
                "high_level_description": [
                    "type": "string",
                    "minLength": 1
                ],
                "style_description": [
                    "anyOf": [photoStyle, artStyle]
                ],
                "compositional_deconstruction": [
                    "type": "object",
                    "properties": [
                        "background": [
                            "type": "string",
                            "minLength": 1
                        ],
                        "elements": [
                            "type": "array",
                            "items": [
                                "anyOf": [
                                    objectElement,
                                    textElement
                                ]
                            ]
                        ]
                    ],
                    "required": ["background", "elements"],
                    "additionalProperties": false
                ]
            ],
            "required": ["compositional_deconstruction"],
            "additionalProperties": false
        ]
    }

    private static func reducedAspectRatio(width: Int, height: Int) -> String {
        let safeWidth = max(width, 1)
        let safeHeight = max(height, 1)
        let divisor = greatestCommonDivisor(safeWidth, safeHeight)
        return "\(safeWidth / divisor):\(safeHeight / divisor)"
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
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
                "description": "Create music. Default to instrumental unless the user explicitly provides or approves lyrics. Do not invent, draft, or write lyrics inside this tool call. If the user asks for vocals/lyrics but has not provided lyrics, ask them to provide lyrics or choose instrumental music before calling this tool.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "caption": [
                            "type": "string",
                            "description": "A concise music prompt describing genre, mood, instruments, tempo, vocals, and use case."
                        ],
                        "lyrics": [
                            "type": "string",
                            "description": "Lyrics with section labels like [verse] and [chorus]. Use only lyrics explicitly provided or approved by the user. Do not write new lyrics here. Omit this field or use [Instrumental] when instrumental is true."
                        ],
                        "duration": [
                            "type": "number",
                            "description": "Optional duration in seconds. Use 30 unless the user asks otherwise."
                        ],
                        "instrumental": [
                            "type": "boolean",
                            "description": "Set true for instrumental, beat, backing track, background music, no-vocal requests, or when the user has not provided/approved lyrics. Set false only when using user-provided or user-approved lyrics."
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
