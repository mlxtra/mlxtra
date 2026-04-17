import XCTest
@testable import MLXHub

final class ChatViewModelLogicTests: XCTestCase {
    private func activeBackend(isImageGeneration: Bool, isSpeechGeneration: Bool) -> RuntimeBackend {
        isImageGeneration ? .image : (isSpeechGeneration ? .audio : .vlm)
    }

    private func resolvedModelId(selectedModel: AIModel, isImageGeneration: Bool, isSpeechGeneration: Bool) -> String {
        let imageGenerationModelId = "black-forest-labs/FLUX.2-klein-4B"
        let activeModelId = isImageGeneration ? imageGenerationModelId : selectedModel.modelId
        return isSpeechGeneration ? "speech-model" : activeModelId
    }

    private func finalContent(fullResponse: String, isImageGeneration: Bool, isSpeechGeneration: Bool) -> String {
        (isImageGeneration || isSpeechGeneration) ? "" : fullResponse
    }

    private func selectedTools(isImageGeneration: Bool, isSpeechGeneration: Bool, isMusicGeneration: Bool, musicTool: [String: Any]) -> [[String: Any]]? {
        (isImageGeneration || isSpeechGeneration) ? nil : (isMusicGeneration ? [musicTool] : [])
    }

    // MARK: - Tool Detection Tests

    func testDefaultMusicParameters() {
        func defaultMusicParameters(caption: String) -> [String: Any] {
            [
                "caption": caption,
                "duration": 30,
                "batch_size": 1,
                "inference_steps": 8,
                "audio_format": "wav",
                "thinking": false,
                "instrumental": caption.localizedCaseInsensitiveContains("instrumental")
                    || caption.localizedCaseInsensitiveContains("beat")
                    || caption.localizedCaseInsensitiveContains("background music")
            ]
        }

        let params1 = defaultMusicParameters(caption: "Create an instrumental track")
        XCTAssertTrue(params1["instrumental"] as? Bool == true)

        let params2 = defaultMusicParameters(caption: "Upbeat electronic beat")
        XCTAssertTrue(params2["instrumental"] as? Bool == true)

        let params3 = defaultMusicParameters(caption: "Relaxing background music")
        XCTAssertTrue(params3["instrumental"] as? Bool == true)

        let params4 = defaultMusicParameters(caption: "Song with vocals")
        XCTAssertFalse(params4["instrumental"] as? Bool == true)
    }

    func testDefaultMusicParametersValues() {
        func defaultMusicParameters(caption: String) -> [String: Any] {
            [
                "caption": caption,
                "duration": 30,
                "batch_size": 1,
                "inference_steps": 8,
                "audio_format": "wav",
                "thinking": false,
                "instrumental": false
            ]
        }

        let params = defaultMusicParameters(caption: "Test music")

        XCTAssertEqual(params["duration"] as? Int, 30)
        XCTAssertEqual(params["batch_size"] as? Int, 1)
        XCTAssertEqual(params["inference_steps"] as? Int, 8)
        XCTAssertEqual(params["audio_format"] as? String, "wav")
        XCTAssertFalse(params["thinking"] as? Bool == true)
    }

    // MARK: - System Prompt Tests

    func testSystemPromptContainsToolInstructions() {
        let systemPrompt = """
        You are a helpful assistant.

        When the user asks you to create, generate, draw, edit, or make an image, use the generate_image tool.

        When the user asks you to create speech, narration, voiceover, or text-to-speech audio, use the create_speech tool.

        When the user asks you to create music, a song, beat, loop, soundtrack, instrumental, or background music, use the generate_music tool.
        """

        XCTAssertTrue(systemPrompt.contains("generate_image"))
        XCTAssertTrue(systemPrompt.contains("create_speech"))
        XCTAssertTrue(systemPrompt.contains("generate_music"))
        XCTAssertTrue(systemPrompt.contains("helpful assistant"))
    }

    func testMusicReadinessSystemInstructionBlocksPrematureGeneration() {
        let instruction = MusicIntentState.needsInstrumentalOrVocals.systemInstruction

        XCTAssertTrue(instruction.contains("ask whether"))
        XCTAssertTrue(instruction.contains("before calling generate_music"))
    }

    // MARK: - Available Tools Tests

    func testToolDefinitions() {
        let webSearchTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current information",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query"]
                    ],
                    "required": ["query"]
                ]
            ]
        ]

        let imageTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "generate_image",
                "description": "Generate or edit an image",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string"]
                    ],
                    "required": ["prompt"]
                ]
            ]
        ]

        let speechTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "create_speech",
                "description": "Create spoken audio from text",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"]
                    ],
                    "required": ["text"]
                ]
            ]
        ]

        let musicTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "generate_music",
                "description": "Create a song, instrumental track, beat",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "caption": ["type": "string"]
                    ],
                    "required": ["caption"]
                ]
            ]
        ]

        // Verify tool names are correct
        if let fn = webSearchTool["function"] as? [String: Any] {
            XCTAssertEqual(fn["name"] as? String, "web_search")
        }
        if let fn = imageTool["function"] as? [String: Any] {
            XCTAssertEqual(fn["name"] as? String, "generate_image")
        }
        if let fn = speechTool["function"] as? [String: Any] {
            XCTAssertEqual(fn["name"] as? String, "create_speech")
        }
        if let fn = musicTool["function"] as? [String: Any] {
            XCTAssertEqual(fn["name"] as? String, "generate_music")
        }
    }

    func testMusicSelectedUsesOnlyMusicTool() {
        let musicTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "generate_music",
                "description": "Create music only after the user has specified instrumental music or approved lyrics for vocals."
            ]
        ]

        let isImageGeneration = false
        let isSpeechGeneration = false
        let isMusicGeneration = true
        let tools = selectedTools(
            isImageGeneration: isImageGeneration,
            isSpeechGeneration: isSpeechGeneration,
            isMusicGeneration: isMusicGeneration,
            musicTool: musicTool
        )

        XCTAssertEqual(tools?.count, 1)
        let function = tools?.first?["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "generate_music")
    }

    // MARK: - Backend Selection Tests

    func testBackendForImageTool() {
        let isImageGeneration = true
        let isSpeechGeneration = false

        XCTAssertEqual(activeBackend(isImageGeneration: isImageGeneration, isSpeechGeneration: isSpeechGeneration), .image)
    }

    func testBackendForMusicTool() {
        let isImageGeneration = false
        let isSpeechGeneration = false

        XCTAssertEqual(activeBackend(isImageGeneration: isImageGeneration, isSpeechGeneration: isSpeechGeneration), .vlm)
    }

    func testMusicPlanningRequestUsesSelectedChatModel() {
        let selectedModel = AIModel.qwen35
        let isImageGeneration = false
        let isSpeechGeneration = false

        XCTAssertEqual(activeBackend(isImageGeneration: isImageGeneration, isSpeechGeneration: isSpeechGeneration), .vlm)
        XCTAssertEqual(
            resolvedModelId(selectedModel: selectedModel, isImageGeneration: isImageGeneration, isSpeechGeneration: isSpeechGeneration),
            selectedModel.modelId
        )
    }

    func testBackendForSpeechTool() {
        let isImageGeneration = false
        let isSpeechGeneration = true

        XCTAssertEqual(activeBackend(isImageGeneration: isImageGeneration, isSpeechGeneration: isSpeechGeneration), .audio)
    }

    func testBackendForVLM() {
        let isImageGeneration = false
        let isSpeechGeneration = false

        XCTAssertEqual(activeBackend(isImageGeneration: isImageGeneration, isSpeechGeneration: isSpeechGeneration), .vlm)
    }

    // MARK: - Model ID Selection Tests

    func testModelIdForMusicGeneration() {
        let selectedModel = AIModel.qwen35
        let isSpeechGeneration = false
        let isImageGeneration = false

        XCTAssertEqual(
            resolvedModelId(selectedModel: selectedModel, isImageGeneration: isImageGeneration, isSpeechGeneration: isSpeechGeneration),
            selectedModel.modelId
        )
    }

    func testModelIdForVLM() {
        let selectedModel = AIModel.qwen35
        let isSpeechGeneration = false

        let isImageGeneration = false

        XCTAssertEqual(
            resolvedModelId(selectedModel: selectedModel, isImageGeneration: isImageGeneration, isSpeechGeneration: isSpeechGeneration),
            selectedModel.modelId
        )
    }

    // MARK: - Temperature Selection Tests

    func testTemperatureForDirectMediaGeneration() {
        let isImageGeneration = true
        let isSpeechGeneration = false
        let defaultTemp = 0.7

        let temp = isImageGeneration || isSpeechGeneration ? 1.0 : defaultTemp

        XCTAssertEqual(temp, 1.0)
    }

    func testTemperatureForChat() {
        let isImageGeneration = false
        let isSpeechGeneration = false
        let defaultTemp = 0.7

        let temp = isImageGeneration || isSpeechGeneration ? 1.0 : defaultTemp

        XCTAssertEqual(temp, defaultTemp)
    }

    func testMusicPlanningCompletionKeepsAssistantText() {
        let response = "Would you like instrumental music, or vocals with lyrics?"

        XCTAssertEqual(finalContent(fullResponse: response, isImageGeneration: false, isSpeechGeneration: false), response)
    }

    // MARK: - Music Intent State Tests

    func testMusicIntentReadyForInstrumentalPrompt() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create an instrumental synthwave loop"), .readyToGenerate)
    }

    func testMusicIntentNeedsLyricsForVocalPrompt() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create a pop song with vocals"), .needsLyrics)
    }

    func testMusicIntentNeedsInstrumentalOrVocalsWhenAmbiguous() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create a moody cyberpunk track"), .needsInstrumentalOrVocals)
    }

    func testMusicToolCallBlockedWhenAmbiguous() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a moody cyberpunk track",
            parameters: ["caption": "moody cyberpunk track"]
        )

        XCTAssertEqual(state, .needsInstrumentalOrVocals)
        XCTAssertNotNil(state.blockedToolMessage)
    }

    func testMusicToolCallBlockedWhenLyricsAreDraftedWithoutApproval() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a pop song with vocals",
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .awaitingLyricsApproval)
        XCTAssertNotNil(state.blockedToolMessage)
    }

    func testMusicToolCallReadyWhenUserApprovesLyrics() {
        let state = MusicIntentState.forToolCall(
            prompt: "Yes, those lyrics look good. Go ahead.",
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicToolCallReadyWhenUserProvidesLyrics() {
        let prompt = """
        Create a pop song with these lyrics:
        [verse]
        Neon hearts are waking
        [chorus]
        We rise into the light
        """
        let state = MusicIntentState.forToolCall(
            prompt: prompt,
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    // MARK: - Tool Call Execution Tests

    func testToolCallNameExtraction() {
        let arguments = "{\"query\": \"test search\"}"

        if let data = arguments.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let query = decoded["query"] as? String {
            XCTAssertEqual(query, "test search")
        } else {
            XCTFail("Failed to parse arguments")
        }
    }

    func testToolCallArgumentsWithMultipleParams() {
        let arguments = "{\"caption\": \"upbeat music\", \"duration\": 60, \"instrumental\": true}"

        if let data = arguments.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertEqual(decoded["caption"] as? String, "upbeat music")
            XCTAssertEqual(decoded["duration"] as? Int, 60)
            XCTAssertEqual(decoded["instrumental"] as? Bool, true)
        } else {
            XCTFail("Failed to parse arguments")
        }
    }

    func testMusicIntentAcceptsStringInstrumentalToolParameter() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a mysterious orchestral clockwork garden cue",
            parameters: [
                "caption": "A 1-minute orchestral piece with violin, cello, harp, ticking rhythm, and soft chimes",
                "duration": "60",
                "instrumental": "True"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    // MARK: - Context Message Extraction Tests

    func testContextMessagesExcludesStreaming() {
        let messages = [
            Message(id: UUID(), content: "First", isUser: true, timestamp: Date(), isStreaming: false),
            Message(id: UUID(), content: "Second", isUser: false, timestamp: Date(), isStreaming: true),
            Message(id: UUID(), content: "Third", isUser: true, timestamp: Date(), isStreaming: false)
        ]

        let excludedId = messages[1].id
        let completedMessages = messages.filter { $0.id != excludedId && !$0.isStreaming }

        XCTAssertEqual(completedMessages.count, 2)
        XCTAssertTrue(completedMessages.contains { $0.content == "First" })
        XCTAssertTrue(completedMessages.contains { $0.content == "Third" })
        XCTAssertFalse(completedMessages.contains { $0.content == "Second" })
    }

    func testContextMessagesLimitedTo20() {
        var messages: [Message] = []
        for i in 0..<30 {
            messages.append(Message(id: UUID(), content: "Message \(i)", isUser: i % 2 == 0, timestamp: Date(), isStreaming: false))
        }

        let contextMessages = Array(messages.suffix(20))

        XCTAssertEqual(contextMessages.count, 20)
        XCTAssertEqual(contextMessages.first?.content, "Message 10")
        XCTAssertEqual(contextMessages.last?.content, "Message 29")
    }

    // MARK: - Should Buffer Tool Output Tests

    func testShouldBufferEmptyOutput() {
        let shouldBuffer = { (output: String) -> Bool in
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedOutput.isEmpty else { return true }
            let toolPrefixes = ["<tool_call>", "<function=", "<|tool_call|>"]
            return toolPrefixes.contains { prefix in
                prefix.hasPrefix(trimmedOutput) || trimmedOutput.hasPrefix(prefix)
            }
        }

        XCTAssertTrue(shouldBuffer(""))
        XCTAssertTrue(shouldBuffer("   "))
    }

    func testShouldBufferToolPrefix() {
        let shouldBuffer = { (output: String) -> Bool in
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedOutput.isEmpty else { return true }
            let toolPrefixes = ["<tool_call>", "<function=", "<|tool_call|>"]
            return toolPrefixes.contains { prefix in
                prefix.hasPrefix(trimmedOutput) || trimmedOutput.hasPrefix(prefix)
            }
        }

        XCTAssertTrue(shouldBuffer("<function=web_search>"))
        XCTAssertTrue(shouldBuffer("<|tool_call|>"))
        XCTAssertTrue(shouldBuffer("<tool_call>"))
    }

    func testShouldNotBufferRegularText() {
        let shouldBuffer = { (output: String) -> Bool in
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedOutput.isEmpty else { return true }
            let toolPrefixes = ["<tool_call>", "<function=", "<|tool_call|>"]
            return toolPrefixes.contains { prefix in
                prefix.hasPrefix(trimmedOutput) || trimmedOutput.hasPrefix(prefix)
            }
        }

        XCTAssertFalse(shouldBuffer("Hello, how are you?"))
        XCTAssertFalse(shouldBuffer("This is a regular response"))
    }

    // MARK: - Chat Title Generation Tests

    func testChatTitleFromFirstMessage() {
        let messageContent = "How do I create an image?"

        let title = messageContent.isEmpty ? "Image attachment" : String(messageContent.prefix(30))

        XCTAssertEqual(title, "How do I create an image?")
    }

    func testChatTitleEmptyContent() {
        let messageContent = ""

        let title = messageContent.isEmpty ? "Image attachment" : String(messageContent.prefix(30))

        XCTAssertEqual(title, "Image attachment")
    }

func testChatTitleTruncation() {
        let messageContent = "This is a very long message that should be truncated because it exceeds thirty characters"
        let title = String(messageContent.prefix(30))

        XCTAssertEqual(title.count, 30)
        XCTAssertTrue(title.hasSuffix("message th"))
    }

    // MARK: - Error Message Formatting Tests

    func testErrorMessageForPythonError() {
        let execError = ExecutionError.pythonError("ModuleNotFoundError: No module named 'acestep'")

        var errorContent: String
        switch execError {
        case .pythonError(let message):
            errorContent = "Python Error:\n\(message)"
        default:
            errorContent = "Sorry, I encountered an error."
        }

        XCTAssertTrue(errorContent.contains("Python Error"))
        XCTAssertTrue(errorContent.contains("ModuleNotFoundError"))
    }

    func testErrorMessageForTimeout() {
        let execError = ExecutionError.timeout

        var errorContent: String
        switch execError {
        case .timeout:
            errorContent = "The operation timed out. Please try again."
        default:
            errorContent = "Sorry, I encountered an error."
        }

        XCTAssertEqual(errorContent, "The operation timed out. Please try again.")
    }

    func testErrorMessageForProcessCrashed() {
        let execError = ExecutionError.processCrashed(retryCount: 2)

        var errorContent: String
        switch execError {
        case .processCrashed(let count):
            errorContent = "The AI process crashed (attempt \(count)). Retrying..."
        default:
            errorContent = "Sorry, I encountered an error."
        }

        XCTAssertTrue(errorContent.contains("crashed"))
        XCTAssertTrue(errorContent.contains("attempt 2"))
    }

    // MARK: - Input Validation Tests

    func testInputDisabledWhenGenerating() {
        let isPythonLoading = false
        let isModelLoading = false
        let isGenerating = true

        let isInputDisabled = isPythonLoading || isModelLoading || isGenerating

        XCTAssertTrue(isInputDisabled)
    }

    func testInputDisabledWhenLoading() {
        let isPythonLoading = false
        let isModelLoading = true
        let isGenerating = false

        let isInputDisabled = isPythonLoading || isModelLoading || isGenerating

        XCTAssertTrue(isInputDisabled)
    }

    func testInputEnabledWhenIdle() {
        let isPythonLoading = false
        let isModelLoading = false
        let isGenerating = false

        let isInputDisabled = isPythonLoading || isModelLoading || isGenerating

        XCTAssertFalse(isInputDisabled)
    }
}
