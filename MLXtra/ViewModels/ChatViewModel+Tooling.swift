import Foundation

@MainActor
extension ChatViewModel {
    var webSearchTool: [String: Any] {
        PromptConfiguration.toolDefinition(named: "web_search") ?? PromptConfiguration.webSearchTool
    }

    var imageGenerationTool: [String: Any] {
        PromptConfiguration.toolDefinition(named: "generate_image") ?? PromptConfiguration.imageGenerationTool
    }

    var speechGenerationTool: [String: Any] {
        PromptConfiguration.toolDefinition(named: "create_speech") ?? PromptConfiguration.speechGenerationTool
    }

    var musicGenerationTool: [String: Any] {
        PromptConfiguration.toolDefinition(named: "generate_music") ?? PromptConfiguration.musicGenerationTool
    }

    var systemPrompt: String {
        PromptConfiguration.systemPrompt()
    }

    var deepResearchSystemPrompt: String {
        PromptConfiguration.deepResearchSystemPrompt()
    }

    var autoTools: [[String: Any]] {
        PromptConfiguration.toolDefinitions()
    }

    var deepResearchTools: [[String: Any]] {
        [webSearchTool]
    }

    func availableTools(toolDepth: Int, for tool: Tool) -> [[String: Any]]? {
        guard toolDepth < maxAutoToolDepth else { return nil }

        if tool == .research {
            return deepResearchTools
        }

        guard tool == .auto else { return nil }
        return autoTools
    }

    func canonicalToolName(_ name: String) -> String {
        switch name {
        case "create_image":
            return "generate_image"
        case "generate_speech":
            return "create_speech"
        case "create_music":
            return "generate_music"
        default:
            return name
        }
    }

    func isToolAllowed(_ name: String, allowedToolNames: Set<String>) -> Bool {
        allowedToolNames.contains(canonicalToolName(name))
    }

    func canonicalToolCall(_ toolCall: ExecutionToolCall) -> ExecutionToolCall {
        let name = canonicalToolName(toolCall.function.name)
        guard name != toolCall.function.name else { return toolCall }

        return ExecutionToolCall(
            id: toolCall.id,
            function: ExecutionToolCallFunction(
                name: name,
                arguments: toolCall.function.arguments
            )
        )
    }

    func seedDeepResearchContext(prompt: String, generationID: UUID? = nil) async -> [ExecutionMessage] {
        guard ownsActiveGeneration(generationID) else { return [] }
        let toolCall = ExecutionToolCall(
            id: "deep-research-initial-search",
            function: ExecutionToolCallFunction(
                name: "web_search",
                arguments: jsonArguments(["query": prompt])
            )
        )

        loadingMessage = "Researching..."
        beginToolCallProgress(
            toolName: "Web search",
            status: prompt,
            icon: "magnifyingglass",
            generationID: generationID
        )

        let result = await toolExecutor.executeWebSearch(query: prompt)
        guard ownsActiveGeneration(generationID) else { return [] }
        return [
            ExecutionMessage(role: .assistant, toolCalls: [toolCall]),
            ExecutionMessage(
                role: .tool,
                content: result,
                toolCallId: toolCall.id,
                name: "web_search"
            )
        ]
    }

    func jsonArguments(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    func musicIntentStateForCurrentComposer(prompt: String, parameters: [String: Any]? = nil) -> MusicIntentState {
        let mode = activeMusicGenerationDraft?.vocalMode ?? resolvedMusicVocalMode(for: prompt)
        switch mode {
        case .instrumental:
            return .readyToGenerate
        case .vocals:
            let approvedLyrics = activeMusicGenerationDraft?.lyrics
                ?? musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !approvedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || promptContainsLyrics(prompt) {
                return .readyToGenerate
            }
            return .needsLyrics
        case .auto:
            if let parameters {
                return MusicIntentState.forToolCall(prompt: prompt, parameters: parameters)
            }
            return MusicIntentState.forPrompt(prompt)
        }
    }

    func musicComposerInstruction(prompt: String) -> String? {
        let mode = activeMusicGenerationDraft?.vocalMode ?? resolvedMusicVocalMode(for: prompt)
        switch mode {
        case .instrumental:
            return "The user selected instrumental music. If calling generate_music, set instrumental to true and lyrics to \"[Instrumental]\"."
        case .vocals:
            let approvedLyrics = activeMusicGenerationDraft?.lyrics
                ?? musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !approvedLyrics.isEmpty else {
                return "The user selected vocals, but lyrics are not approved yet. Ask for lyrics before calling generate_music."
            }
            return """
            The user selected vocals and approved these lyrics. If calling generate_music, set instrumental to false and use these lyrics exactly:
            \(approvedLyrics)
            """
        case .auto:
            return nil
        }
    }

    func isModelDownloadRequiredMessage(_ content: String) -> Bool {
        content.hasPrefix("Model download required:")
    }

    func shouldBufferToolEnabledOutput(_ output: String) -> Bool {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return true }

        let toolPrefixes = ["<tool_call>", "<function=", "<|tool_call|>", "<|tool_call>"]
        let maxPrefixLength = 14

        if trimmedOutput.count > maxPrefixLength {
            return toolPrefixes.contains { trimmedOutput.hasPrefix($0) }
        }

        return toolPrefixes.contains { prefix in
            prefix.hasPrefix(trimmedOutput) || trimmedOutput.hasPrefix(prefix)
        }
    }

    func isTerminalMediaTool(_ name: String) -> Bool {
        let canonicalName = canonicalToolName(name)
        return canonicalName == "generate_image" || canonicalName == "create_speech" || canonicalName == "generate_music"
    }

    func decodeToolArguments(_ toolCall: ExecutionToolCall) -> [String: Any]? {
        guard let data = toolCall.function.arguments.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func plainTextToolCall(from response: String, prompt: String?) -> ExecutionToolCall? {
        let parser = PlainTextToolCallParser(supportedNames: [
            "web_search",
            "generate_image",
            "create_image",
            "create_speech",
            "generate_speech",
            "generate_music",
            "create_music"
        ])
        guard var parsedCall = parser.parse(response: response) else {
            return nil
        }

        let normalizedName = canonicalToolName(parsedCall.name)
        if normalizedName == "generate_music",
           (parsedCall.arguments["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            parsedCall.arguments["caption"] = musicCaptionFallback(currentPrompt: prompt ?? "")
        }

        return ExecutionToolCall(
            id: "plain-text-\(normalizedName)-\(UUID().uuidString)",
            function: ExecutionToolCallFunction(
                name: normalizedName,
                arguments: jsonArguments(parsedCall.arguments)
            )
        )
    }

    private func musicCaptionFallback(currentPrompt: String) -> String {
        let trimmedCurrentPrompt = currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isMusicApprovalOnly(trimmedCurrentPrompt), !trimmedCurrentPrompt.isEmpty {
            return trimmedCurrentPrompt
        }

        if let chat = selectedChat {
            for message in chat.messages.reversed() where message.isUser {
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty,
                      content != trimmedCurrentPrompt,
                      !isMusicApprovalOnly(content),
                      containsMusicIntentLanguage(content) else {
                    continue
                }
                return content
            }
        }

        return trimmedCurrentPrompt.isEmpty ? "Create a song with the approved lyrics." : trimmedCurrentPrompt
    }

    private func isMusicApprovalOnly(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let approvalWords = ["yes", "yep", "yeah", "ok", "okay", "approved", "go ahead", "generate", "create it", "looks good"]
        return normalized.count <= 40 && approvalWords.contains { normalized == $0 || normalized.contains($0) }
    }

    private func containsMusicIntentLanguage(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return [
            "music",
            "song",
            "track",
            "beat",
            "loop",
            "soundtrack",
            "instrumental",
            "vocals",
            "lyrics"
        ].contains { normalized.contains($0) }
    }

}
