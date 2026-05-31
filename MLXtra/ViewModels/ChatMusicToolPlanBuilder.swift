import Foundation

struct ChatMusicComposerSelection {
    let mode: MusicVocalMode
    let approvedLyrics: String?
}

enum ChatMusicToolPlanBuilder {
    static func makeParameters(
        prompt: String,
        decodedArguments: [String: Any]?,
        executionParameters: [String: Any],
        composerSelection: ChatMusicComposerSelection,
        applyAutomaticInstrumentalFallback: Bool,
        promptSoundsVocal: (String) -> Bool
    ) -> [String: Any] {
        var parameters = defaultParameters(caption: prompt, executionParameters: executionParameters)
        applyDecodedArguments(decodedArguments, to: &parameters)
        applyComposerOverrides(to: &parameters, selection: composerSelection)

        if applyAutomaticInstrumentalFallback {
            applyInstrumentalFallback(to: &parameters, prompt: prompt, promptSoundsVocal: promptSoundsVocal)
        }

        return parameters
    }

    static func makePlan(
        parameters: [String: Any],
        fallbackPrompt: String,
        musicProfile: ModelCapabilityProfile,
        outputDirectory: URL
    ) -> ChatMediaToolExecutionPlan {
        let musicPrompt = (parameters["caption"] as? String) ?? fallbackPrompt
        let model = musicProfile.downloadableModel

        return ChatMediaToolExecutionPlan(
            functionName: "generate_music",
            toolName: "Music generation",
            status: musicPrompt,
            icon: "music.note",
            details: toolCallDetails(parameters),
            model: model,
            request: ExecutionRequest(
                backend: .music,
                modelId: musicProfile.modelId,
                messages: [ExecutionMessage(role: .user, content: musicPrompt)],
                outputDirectory: outputDirectory,
                maxTokens: 0,
                temperature: 1.0,
                parameters: parameters
            ),
            loadingStatus: "Generating music...",
            operationName: "Music generation",
            unavailablePrefix: "Music generation unavailable",
            noOutputMessage: "Music generation finished without returning audio.",
            completionHint: "The generated music is already displayed in the app UI. In your final response, use text only. Do not include local file paths.",
            attachmentKind: .audio
        )
    }

    private static func defaultParameters(caption: String, executionParameters: [String: Any]) -> [String: Any] {
        var parameters = executionParameters
        parameters.merge([
            "caption": caption,
            "instrumental": caption.localizedCaseInsensitiveContains("instrumental")
                || caption.localizedCaseInsensitiveContains("beat")
                || caption.localizedCaseInsensitiveContains("background music")
        ]) { _, newValue in newValue }
        return parameters
    }

    private static func applyDecodedArguments(_ decodedArguments: [String: Any]?, to parameters: inout [String: Any]) {
        guard let decodedArguments else { return }

        if let caption = decodedArguments["caption"] as? String,
           !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parameters["caption"] = caption
        }
        if let lyrics = decodedArguments["lyrics"] as? String {
            parameters["lyrics"] = lyrics
        }
        if let duration = decodedArguments["duration"] {
            parameters["duration"] = normalizedNumber(duration)
        }
        if let instrumental = decodedArguments["instrumental"] {
            parameters["instrumental"] = normalizedBool(instrumental) ?? instrumental
        }
        if let bpm = decodedArguments["bpm"] {
            parameters["bpm"] = normalizedNumber(bpm)
        }
        if let keyscale = decodedArguments["keyscale"] as? String {
            parameters["keyscale"] = keyscale
        }
        if let timesignature = decodedArguments["timesignature"] as? String {
            parameters["timesignature"] = timesignature
        }
        if let vocalLanguage = decodedArguments["vocal_language"] as? String {
            parameters["vocal_language"] = vocalLanguage
        }
    }

    private static func applyComposerOverrides(to parameters: inout [String: Any], selection: ChatMusicComposerSelection) {
        switch selection.mode {
        case .instrumental:
            parameters["instrumental"] = true
            parameters["lyrics"] = "[Instrumental]"
        case .vocals:
            if let approvedLyrics = selection.approvedLyrics,
               !approvedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parameters["instrumental"] = false
                parameters["lyrics"] = approvedLyrics
            }
        case .auto:
            break
        }
    }

    private static func applyInstrumentalFallback(
        to parameters: inout [String: Any],
        prompt: String,
        promptSoundsVocal: (String) -> Bool
    ) {
        let lyrics = (parameters["lyrics"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard lyrics.isEmpty else { return }

        let caption = (parameters["caption"] as? String) ?? prompt
        guard !promptSoundsVocal("\(prompt) \(caption)") else { return }

        parameters["instrumental"] = true
        parameters["lyrics"] = "[Instrumental]"
    }

    private static func normalizedNumber(_ value: Any) -> Any {
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

    private static func normalizedBool(_ value: Any) -> Bool? {
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

    private static func toolCallDetails(_ parameters: [String: Any]) -> [ToolCallDetail] {
        let userFacingKeys = [
            "caption",
            "lyrics",
            "duration",
            "instrumental"
        ]

        var details: [ToolCallDetail] = []
        for key in userFacingKeys {
            if let value = parameters[key],
               let displayValue = parameterDisplayValue(value) {
                details.append(ToolCallDetail(label: parameterLabel(key), value: displayValue))
            }
        }

        return details
    }

    private static func parameterDisplayValue(_ value: Any) -> String? {
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

    private static func parameterLabel(_ key: String) -> String {
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
}
