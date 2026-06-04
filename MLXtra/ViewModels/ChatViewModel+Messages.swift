import Foundation

@MainActor
extension ChatViewModel {
    func messageLocation(for messageId: UUID) -> (chatIndex: Int, messageIndex: Int)? {
        for chatIndex in chats.indices {
            if let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
                return (chatIndex, messageIndex)
            }
        }
        return nil
    }

    func streamingContent(for messageId: UUID) -> StreamingMessageContent? {
        streamingContentStore.content(for: messageId)
    }

    func beginToolCallProgress(
        toolName: String,
        status: String,
        icon: String,
        details: [ToolCallDetail] = [],
        messageId: UUID? = nil,
        generationID: UUID? = nil
    ) {
        guard ownsActiveGeneration(generationID),
              let messageId = messageId ?? streamingMessageId else { return }

        appendToolCall(
            ToolCall(
                toolName: toolName,
                status: status,
                icon: icon,
                details: details
            ),
            toMessage: messageId
        )
        clearMessageContent(messageId)
    }

    func toolCallDetails(_ details: [ToolCallDetail], includingModel modelName: String) -> [ToolCallDetail] {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty,
              !details.contains(where: { $0.label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Model") == .orderedSame }) else {
            return details
        }

        return details + [ToolCallDetail(label: "Model", value: trimmedModelName)]
    }

    func executeMediaToolCall(
        _ toolCall: ExecutionToolCall,
        messages: inout [ExecutionMessage],
        plan: ChatMediaToolExecutionPlan,
        generationID: UUID? = nil
    ) async {
        guard ownsActiveGeneration(generationID) else { return }
        let targetMessageId = streamingMessageId

        loadingMessage = plan.loadingStatus
        setActiveEngineModel(name: plan.model.name, role: localEngineModelRole(for: plan))
        beginToolCallProgress(
            toolName: plan.toolName,
            status: plan.status,
            icon: plan.icon,
            details: toolCallDetails(plan.details, includingModel: plan.model.name),
            messageId: targetMessageId,
            generationID: generationID
        )

        let outcome = await toolExecutor.executeMediaTool(plan: plan) { [weak self] update in
            guard let self, self.ownsActiveGeneration(generationID) else { return }

            switch update {
            case .progress(let message):
                self.loadingMessage = message
            case .modelLoadProgress(let progress):
                self.modelLoadProgress = progress
                self.loadingMessage = progress.detail ?? progress.phase.displayTitle
            case .generationProgress(let progress):
                self.generationProgress = progress
                self.loadingMessage = progress.displayDetail
                if let messageId = targetMessageId {
                    self.updateMessageToolCall(messageId, progress: progress)
                }
            case .generatedAsset(let url, let kind):
                if let messageId = targetMessageId {
                    self.attachGeneratedAsset(url, kind: kind, toMessage: messageId)
                }
            }
        }

        guard ownsActiveGeneration(generationID) else { return }
        switch outcome {
        case .cancelled:
            return
        case .downloadRequired(let model):
            requestDownloadBeforeUse(model: model)
            messages.append(ExecutionMessage(
                role: .tool,
                content: modelDownloadRequiredMessage(for: model, operation: plan.operationName),
                toolCallId: toolCall.id,
                name: plan.functionName
            ))
        case .toolMessage(let content, let metrics):
            if let messageId = targetMessageId, let metrics {
                updateMessagePerformanceMetrics(messageId, metrics: metrics)
            }
            messages.append(ExecutionMessage(
                role: .tool,
                content: content,
                toolCallId: toolCall.id,
                name: plan.functionName
            ))
        case .failedToolMessage(let content, let engineMessage, let metrics):
            localEngineErrorMessage = engineMessage
            if let messageId = targetMessageId, let metrics {
                updateMessagePerformanceMetrics(messageId, metrics: metrics)
            }
            messages.append(ExecutionMessage(
                role: .tool,
                content: content,
                toolCallId: toolCall.id,
                name: plan.functionName
            ))
        }
    }

    func attachGeneratedAsset(_ url: URL, kind: ChatGeneratedAssetKind, toMessage messageId: UUID) {
        switch kind {
        case .image:
            appendGeneratedImage(url, toMessage: messageId)
        case .audio:
            appendGeneratedAudio(url, toMessage: messageId)
        }
    }

    func clearMessageContent(_ messageId: UUID) {
        streamingContentStore.clear(messageId: messageId)
        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            chats[chatIndex].messages[messageIndex].content = ""
        }
    }

    func updateStreamingMessage(_ messageId: UUID, content: String) {
        if streamingContentStore.content(for: messageId) != nil {
            streamingContentStore.update(messageId: messageId, text: content)
            return
        }

        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            var updatedMessages = chats[chatIndex].messages
            updatedMessages[messageIndex].content = content
            chats[chatIndex].messages = updatedMessages
        }
    }

    func appendStreamingMessage(_ messageId: UUID, content: String) {
        guard !content.isEmpty else { return }

        if streamingContentStore.content(for: messageId) != nil {
            streamingContentStore.append(messageId: messageId, text: content)
            return
        }

        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            var updatedMessages = chats[chatIndex].messages
            updatedMessages[messageIndex].content += content
            chats[chatIndex].messages = updatedMessages
        }
    }

    func appendGeneratedImage(_ imageURL: URL, toMessage messageId: UUID) {
        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            var updatedMessages = chats[chatIndex].messages
            if !updatedMessages[messageIndex].imageURLs.contains(imageURL) {
                updatedMessages[messageIndex].imageURLs.append(imageURL)
            }
            chats[chatIndex].messages = updatedMessages
        }
    }

    func appendGeneratedAudio(_ audioURL: URL, toMessage messageId: UUID) {
        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            var updatedMessages = chats[chatIndex].messages
            if !updatedMessages[messageIndex].audioURLs.contains(audioURL) {
                updatedMessages[messageIndex].audioURLs.append(audioURL)
            }
            chats[chatIndex].messages = updatedMessages
        }
    }

    func appendToolCall(_ toolCall: ToolCall, toMessage messageId: UUID) {
        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            var updatedMessages = chats[chatIndex].messages
            updatedMessages[messageIndex].toolCalls.append(toolCall)
            chats[chatIndex].messages = updatedMessages
        }
    }

    func updateMessagePerformanceMetrics(_ messageId: UUID, metrics: GenerationPerformanceMetrics) {
        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            chats[chatIndex].messages[messageIndex].performanceMetrics = metrics
        }
    }

    func finalizeMessage(
        _ messageId: UUID,
        content: String,
        usage: TokenUsage,
        clearToolCall: Bool = false,
        performanceMetrics: GenerationPerformanceMetrics? = nil
    ) {
        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            chats[chatIndex].messages[messageIndex].content = content
            chats[chatIndex].messages[messageIndex].isStreaming = false
            chats[chatIndex].messages[messageIndex].performanceMetrics = performanceMetrics
            if clearToolCall {
                chats[chatIndex].messages[messageIndex].toolCalls = []
            }
            chats[chatIndex].timestamp = Date()
            streamingContentStore.end(messageId: messageId)

            scheduleConversationPersistence()
        }
    }

    func markMessageStopped(_ messageId: UUID) {
        if let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            if let streamingContent = streamingContentStore.content(for: messageId) {
                chats[chatIndex].messages[messageIndex].content = streamingContent.text
                streamingContentStore.end(messageId: messageId)
            }
            chats[chatIndex].messages[messageIndex].isStreaming = false
            scheduleConversationPersistence()
        }
    }

    func removeAssistantMessage(_ messageId: UUID) {
        if let location = messageLocation(for: messageId),
           !chats[location.chatIndex].messages[location.messageIndex].isUser {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            chats[chatIndex].messages.remove(at: messageIndex)
            chats[chatIndex].timestamp = Date()
            streamingContentStore.end(messageId: messageId)
            scheduleConversationPersistence()
        }
    }

    func canRetryPrompt(for messageId: UUID) -> Bool {
        !isInputDisabled && retryPromptContext(for: messageId) != nil
    }

    func retryPrompt(for messageId: UUID) {
        guard !isInputDisabled,
              let context = retryPromptContext(for: messageId) else {
            return
        }

        let chatId = chats[context.chatIndex].id
        selectedChatId = chatId

        if !context.responseRange.isEmpty {
            chats[context.chatIndex].messages.removeSubrange(context.responseRange)
            chats[context.chatIndex].timestamp = Date()
            scheduleConversationPersistence()
        }

        let request = makeGenerationRequest(
            chatId: chatId,
            prompt: context.prompt,
            images: context.images,
            retryTool: context.tool
        )
        startGeneration(request)
    }

    private struct RetryPromptContext {
        let chatIndex: Int
        let responseRange: Range<Int>
        let prompt: String
        let images: [URL]
        let tool: Tool
    }

    private func retryPromptContext(for messageId: UUID) -> RetryPromptContext? {
        guard let location = messageLocation(for: messageId) else { return nil }

        let messages = chats[location.chatIndex].messages
        let message = messages[location.messageIndex]
        let userMessageIndex: Int

        if message.isUser {
            userMessageIndex = location.messageIndex
        } else {
            guard isRetryableAssistantMessage(message) else { return nil }
            guard let previousUserIndex = messages[..<location.messageIndex].lastIndex(where: { $0.isUser }) else {
                return nil
            }
            userMessageIndex = previousUserIndex
        }

        let nextUserIndex = messages[(userMessageIndex + 1)...].firstIndex(where: { $0.isUser }) ?? messages.endIndex
        let responseRange = (userMessageIndex + 1)..<nextUserIndex
        let responseMessages = Array(messages[responseRange])
        guard responseMessages.isEmpty || responseMessages.allSatisfy(isRetryableAssistantMessage) else {
            return nil
        }

        let userMessage = messages[userMessageIndex]
        return RetryPromptContext(
            chatIndex: location.chatIndex,
            responseRange: responseRange,
            prompt: userMessage.content,
            images: userMessage.imageURLs,
            tool: retryTool(from: responseMessages) ?? selectedTool
        )
    }

    private func isRetryableAssistantMessage(_ message: Message) -> Bool {
        guard !message.isUser, !message.isStreaming else { return false }
        guard message.imageURLs.isEmpty, message.audioURLs.isEmpty else { return false }

        let visibleContent = ReasoningContentFilter.visibleText(from: message.content) ?? message.content
        let normalizedContent = ChatDisplayText.singleLine(visibleContent).lowercased()
        guard !normalizedContent.isEmpty else { return true }

        return normalizedContent.hasPrefix("the local engine reported an error")
            || normalizedContent.hasPrefix("the local engine stopped before it could finish")
            || normalizedContent.hasPrefix("the selected model could not be loaded")
            || normalizedContent.hasPrefix("this took longer than expected")
            || normalizedContent.hasPrefix("please send your message again")
            || normalizedContent.hasPrefix("the request could not be completed")
            || normalizedContent.contains(" generation unavailable:")
            || normalizedContent.contains(" generation finished without returning")
    }

    private func retryTool(from messages: [Message]) -> Tool? {
        for message in messages.reversed() {
            for toolCall in message.toolCalls.reversed() {
                let haystack = [
                    toolCall.displayTitle,
                    toolCall.toolName,
                    toolCall.icon
                ]
                .joined(separator: " ")
                .lowercased()

                if haystack.contains("image") || haystack.contains("photo") {
                    return .image
                }
                if haystack.contains("music") {
                    return .music
                }
                if haystack.contains("speech") || haystack.contains("voice") || haystack.contains("waveform") {
                    return .tts
                }
            }
        }

        return nil
    }

    func updateMessageToolCall(_ messageId: UUID, status: String) {
        if let location = messageLocation(for: messageId),
           var toolCall = chats[location.chatIndex].messages[location.messageIndex].toolCalls.last {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            toolCall.status = status
            chats[chatIndex].messages[messageIndex].toolCalls[chats[chatIndex].messages[messageIndex].toolCalls.count - 1] = toolCall
        }
    }

    func updateMessageToolCall(_ messageId: UUID, progress: GenerationProgress) {
        if let location = messageLocation(for: messageId),
           var toolCall = chats[location.chatIndex].messages[location.messageIndex].toolCalls.last {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            toolCall.generationProgress = progress
            chats[chatIndex].messages[messageIndex].toolCalls[chats[chatIndex].messages[messageIndex].toolCalls.count - 1] = toolCall
        }
    }

    func handleGenerationError(
        _ error: Error,
        replacingMessageId messageId: UUID? = nil,
        generationID: UUID? = nil,
        isMusicGeneration: Bool = false
    ) {
        guard ownsActiveGeneration(generationID) else { return }

        if error is CancellationError {
            print("[ChatVM] Ignoring cancellation error: \(error)")
            return
        }

        if isMusicGeneration {
            activeMusicGenerationDraft = nil
        }

        print("Generation error: \(error)")
        localEngineErrorMessage = localEngineStatusMessage(for: error)

        let errorContent = userFacingErrorMessage(for: error)

        if let messageId, let location = messageLocation(for: messageId) {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            chats[chatIndex].messages[messageIndex].content = errorContent
            chats[chatIndex].messages[messageIndex].isStreaming = false
            streamingContentStore.end(messageId: messageId)
            chats[chatIndex].timestamp = Date()
            scheduleConversationPersistence()
        } else if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
            if let messageId,
               let messageIndex = chats[index].messages.firstIndex(where: { $0.id == messageId }) {
                chats[index].messages[messageIndex].content = errorContent
                chats[index].messages[messageIndex].isStreaming = false
                streamingContentStore.end(messageId: messageId)
            } else {
                let errorMessage = Message(
                    content: errorContent,
                    isUser: false,
                    timestamp: Date()
                )
                chats[index].messages.append(errorMessage)
            }
            chats[index].timestamp = Date()
            scheduleConversationPersistence()
        }

        isGenerating = false
        isPythonLoading = false
        isModelLoading = false
        streamingMessageId = nil
        generationTask = nil
        activeGenerationID = nil
        loadingMessage = ""
        modelLoadProgress = nil
        generationProgress = nil
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        guard let execError = error as? ExecutionError else {
            return "The request could not be completed. Please try again."
        }

        switch execError {
        case .pythonError(let message):
            return "The local engine reported an error.\n\n\(Self.readableExecutionErrorDetail(message))"
        case .processStopped(let message):
            return "The local engine stopped before it could finish.\n\n\(Self.readableExecutionErrorDetail(message))"
        case .pipeWriteFailed(let message):
            return "The local engine stopped before it could finish.\n\n\(Self.readableExecutionErrorDetail(message))"
        case .notInitialized,
             .processNotRunning,
             .invalidResponse,
             .processCrashed,
             .encodingFailed,
             .decodingFailed:
            return "The local engine stopped before it could finish. Restart it, then try again."
        case .modelNotLoaded:
            return "The selected model could not be loaded. Open Models to check the download, then try again."
        case .timeout:
            return "This took longer than expected. Please try again."
        case .requiresManualRetry:
            return "Please send your message again."
        }
    }

    private func localEngineStatusMessage(for error: Error) -> String? {
        guard let execError = error as? ExecutionError else {
            return nil
        }

        switch execError {
        case .notInitialized,
             .processNotRunning,
             .modelNotLoaded,
             .timeout,
             .processStopped,
             .pipeWriteFailed,
             .invalidResponse,
             .processCrashed,
             .encodingFailed,
             .decodingFailed,
             .requiresManualRetry,
             .pythonError:
            if case .pythonError(let message) = execError {
                return "Local engine error: \(Self.readableExecutionErrorDetail(message, maxLength: 180))"
            }
            if case .processStopped(let message) = execError {
                return "Local engine stopped: \(Self.readableExecutionErrorDetail(message, maxLength: 180))"
            }
            if case .pipeWriteFailed(let message) = execError {
                return "Local engine stopped: \(Self.readableExecutionErrorDetail(message, maxLength: 180))"
            }
            return "The local engine stopped. Restart to continue."
        }
    }

    static func readableExecutionErrorDetail(_ message: String, maxLength: Int = 420) -> String {
        let normalizedLines = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let normalized = normalizedLines.joined(separator: "\n")
        let detail = normalized.isEmpty ? "No additional detail was provided." : normalized

        guard detail.count > maxLength else { return detail }
        let endIndex = detail.index(detail.startIndex, offsetBy: maxLength)
        return String(detail[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

extension ChatViewModel: VLMExecutionDelegate {
    func modelLoadingStarted(modelId: String) {
        guard acceptsModelLoadStart(modelId: modelId) else { return }
        if modelLoadProgress == nil {
            modelLoadProgress = ModelLoadProgress(
                modelId: modelId,
                backend: activeModelProfile.backend,
                phase: .preparing,
                detail: "Preparing \(activeModelProfile.name)"
            )
        }
    }

    func modelLoadingProgress(_ progress: ModelLoadProgress) {
        guard acceptsModelLoadProgress(progress) else { return }
        modelLoadProgress = progress
        loadingMessage = progress.detail ?? progress.phase.displayTitle
    }

    func modelLoadingCompleted(modelId: String) {
        guard acceptsModelLoadEvent(modelId: modelId) else { return }
        isModelLoading = false
        loadingMessage = ""
        modelLoadProgress = nil
        generationProgress = nil
    }

    func modelLoadingFailed(modelId: String, error: Error) {
        guard acceptsModelLoadEvent(modelId: modelId) else { return }
        isModelLoading = false
        loadingMessage = ""
        modelLoadProgress = nil
        generationProgress = nil
    }

    private func acceptsModelLoadProgress(_ progress: ModelLoadProgress) -> Bool {
        guard let currentProgress = modelLoadProgress else {
            return isModelLoading || isPreloadingLocalModel || isPythonLoading
        }
        return currentProgress.modelId == progress.modelId
    }

    private func acceptsModelLoadStart(modelId: String) -> Bool {
        guard let currentProgress = modelLoadProgress else { return true }
        return currentProgress.modelId == modelId
    }

    private func acceptsModelLoadEvent(modelId: String) -> Bool {
        guard let currentProgress = modelLoadProgress else { return false }
        return currentProgress.modelId == modelId
    }

    func executionWillRetry(attempt: Int) {
        loadingMessage = "Retrying (attempt \(attempt))..."
    }

    func executionDidFail(error: Error) {
    }
}
