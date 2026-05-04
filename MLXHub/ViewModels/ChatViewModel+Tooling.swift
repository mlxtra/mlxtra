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

    var shouldIncludeAutoTools: Bool {
        selectedTool == .auto
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

    func availableTools(toolDepth: Int) -> [[String: Any]]? {
        guard toolDepth < maxAutoToolDepth else { return nil }

        if selectedTool == .research {
            return deepResearchTools
        }

        guard shouldIncludeAutoTools else { return nil }
        return autoTools
    }

    func toolNames(from tools: [[String: Any]]?) -> Set<String> {
        guard let tools else { return [] }
        return Set(tools.compactMap { tool in
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return name
        })
    }

    func toolAvailabilityInstruction(allowedToolNames: Set<String>) -> String {
        guard !allowedToolNames.isEmpty else {
            return "Available tools in this mode: none. Do not write, simulate, or mention tool calls."
        }

        let names = allowedToolNames.sorted().joined(separator: ", ")
        return "Available tools in this mode: \(names). Use only these tools. Do not call any other tool."
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

    func seedDeepResearchContext(prompt: String) async -> [ExecutionMessage] {
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
            icon: "magnifyingglass"
        )

        let result = await toolExecutor.executeWebSearch(query: prompt)
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

    func defaultMusicParameters(caption: String) -> [String: Any] {
        var parameters = modelParameterStore.executionParameters(for: profile(for: .music))
        parameters.merge([
            "caption": caption,
            "batch_size": 1,
            "audio_format": "wav",
            "thinking": false,
            "bpm": 0,
            "keyscale": "",
            "timesignature": "",
            "vocal_language": "unknown",
            "instrumental": caption.localizedCaseInsensitiveContains("instrumental")
                || caption.localizedCaseInsensitiveContains("beat")
                || caption.localizedCaseInsensitiveContains("background music")
        ]) { _, newValue in newValue }

        return parameters
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

    func applyMusicComposerOverrides(to parameters: inout [String: Any], prompt: String) {
        let mode = activeMusicGenerationDraft?.vocalMode ?? resolvedMusicVocalMode(for: prompt)
        switch mode {
        case .instrumental:
            parameters["instrumental"] = true
            parameters["lyrics"] = "[Instrumental]"
        case .vocals:
            let approvedLyrics = activeMusicGenerationDraft?.lyrics
                ?? musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !approvedLyrics.isEmpty {
                parameters["instrumental"] = false
                parameters["lyrics"] = approvedLyrics
            }
        case .auto:
            break
        }
    }

    func normalizedMusicNumber(_ value: Any) -> Any {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                return doubleValue
            }
        }
        return value
    }

    func normalizedMusicBool(_ value: Any) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func applyAutomaticInstrumentalFallback(to parameters: inout [String: Any], prompt: String) {
        let lyrics = (parameters["lyrics"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard lyrics.isEmpty else { return }

        let caption = (parameters["caption"] as? String) ?? prompt
        guard !promptSoundsVocal("\(prompt) \(caption)") else { return }

        parameters["instrumental"] = true
        parameters["lyrics"] = "[Instrumental]"
    }

    func musicToolCallDetails(_ parameters: [String: Any]) -> [ToolCallDetail] {
        let userFacingKeys = [
            "caption",
            "lyrics",
            "duration",
            "instrumental"
        ]

        var details: [ToolCallDetail] = []

        for key in userFacingKeys {
            if let value = parameters[key],
               let displayValue = musicParameterDisplayValue(value) {
                details.append(ToolCallDetail(label: musicParameterLabel(key), value: displayValue))
            }
        }

        return details
    }

    private func musicParameterDisplayValue(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private func musicParameterLabel(_ key: String) -> String {
        switch key {
        case "caption": return "Caption"
        case "lyrics": return "Lyrics"
        case "duration": return "Duration"
        case "instrumental": return "Instrumental"
        case "inference_steps": return "Inference steps"
        case "batch_size": return "Batch size"
        case "audio_format": return "Audio format"
        case "thinking": return "Thinking"
        case "seed": return "Seed"
        case "bpm": return "BPM"
        case "keyscale": return "Key"
        case "vocal_language": return "Vocal language"
        default:
            return key
                .split(separator: "_")
                .map { part in
                    part.prefix(1).uppercased() + part.dropFirst()
                }
                .joined(separator: " ")
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
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedNames = [
            "web_search",
            "generate_image",
            "create_image",
            "create_speech",
            "generate_speech",
            "generate_music",
            "create_music"
        ]

        for name in supportedNames where trimmed.hasPrefix("\(name)(") && trimmed.hasSuffix(")") {
            let openParenIndex = trimmed.index(trimmed.startIndex, offsetBy: name.count)
            let argumentsStart = trimmed.index(after: openParenIndex)
            let argumentsEnd = trimmed.index(before: trimmed.endIndex)
            let rawArguments = String(trimmed[argumentsStart..<argumentsEnd])
            guard var arguments = parsePlainTextToolArguments(rawArguments) else {
                return nil
            }

            let normalizedName = canonicalToolName(name)
            if normalizedName == "generate_music",
               (arguments["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                arguments["caption"] = musicCaptionFallback(currentPrompt: prompt ?? "")
            }
            return ExecutionToolCall(
                id: "plain-text-\(normalizedName)-\(UUID().uuidString)",
                function: ExecutionToolCallFunction(
                    name: normalizedName,
                    arguments: jsonArguments(arguments)
                )
            )
        }

        return nil
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

    private func parsePlainTextToolArguments(_ rawArguments: String) -> [String: Any]? {
        var result: [String: Any] = [:]
        var index = rawArguments.startIndex

        func skipWhitespaceAndCommas() {
            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                if character.isWhitespace || character == "," {
                    index = rawArguments.index(after: index)
                } else {
                    break
                }
            }
        }

        func parseKey() -> String? {
            let start = index
            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                if character.isLetter || character.isNumber || character == "_" {
                    index = rawArguments.index(after: index)
                } else {
                    break
                }
            }
            guard start < index else { return nil }
            return String(rawArguments[start..<index])
        }

        func parseQuotedString(quote: Character) -> String? {
            index = rawArguments.index(after: index)
            var value = ""
            var isEscaping = false

            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                index = rawArguments.index(after: index)

                if isEscaping {
                    switch character {
                    case "n":
                        value.append("\n")
                    case "t":
                        value.append("\t")
                    case "r":
                        value.append("\r")
                    case "\\", "\"", "'":
                        value.append(character)
                    default:
                        value.append(character)
                    }
                    isEscaping = false
                    continue
                }

                if character == "\\" {
                    isEscaping = true
                    continue
                }

                if character == quote {
                    return value
                }

                value.append(character)
            }

            return nil
        }

        func parseBareValue() -> Any {
            let start = index
            while index < rawArguments.endIndex, rawArguments[index] != "," {
                index = rawArguments.index(after: index)
            }
            let value = String(rawArguments[start..<index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch value.lowercased() {
            case "true":
                return true
            case "false":
                return false
            case "none", "null":
                return NSNull()
            default:
                if let intValue = Int(value) {
                    return intValue
                }
                if let doubleValue = Double(value) {
                    return doubleValue
                }
                return value
            }
        }

        while index < rawArguments.endIndex {
            skipWhitespaceAndCommas()
            guard index < rawArguments.endIndex else { break }
            guard let key = parseKey() else { return nil }

            while index < rawArguments.endIndex, rawArguments[index].isWhitespace {
                index = rawArguments.index(after: index)
            }
            guard index < rawArguments.endIndex, rawArguments[index] == "=" else {
                return nil
            }
            index = rawArguments.index(after: index)

            while index < rawArguments.endIndex, rawArguments[index].isWhitespace {
                index = rawArguments.index(after: index)
            }
            guard index < rawArguments.endIndex else { return nil }

            let value: Any
            if rawArguments[index] == "\"" || rawArguments[index] == "'" {
                guard let stringValue = parseQuotedString(quote: rawArguments[index]) else {
                    return nil
                }
                value = stringValue
            } else {
                value = parseBareValue()
            }

            result[key] = value
        }

        return result.isEmpty ? nil : result
    }
}

