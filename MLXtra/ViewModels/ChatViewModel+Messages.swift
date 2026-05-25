import Foundation

@MainActor
extension ChatViewModel {
    private func messageLocation(for messageId: UUID) -> (chatIndex: Int, messageIndex: Int)? {
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

    func beginToolCallProgress(toolName: String, status: String, icon: String, details: [ToolCallDetail] = []) {
        guard let messageId = streamingMessageId else { return }

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

    func executeMediaToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], plan: ChatMediaToolExecutionPlan) async {
        loadingMessage = plan.loadingStatus
        setActiveEngineModel(name: plan.model.name, role: localEngineModelRole(for: plan))
        beginToolCallProgress(
            toolName: plan.toolName,
            status: plan.status,
            icon: plan.icon,
            details: toolCallDetails(plan.details, includingModel: plan.model.name)
        )

        let outcome = await toolExecutor.executeMediaTool(plan: plan) { [weak self] update in
            guard let self else { return }

            switch update {
            case .progress(let message):
                self.loadingMessage = message
            case .modelLoadProgress(let progress):
                self.modelLoadProgress = progress
                self.loadingMessage = progress.detail ?? progress.phase.displayTitle
            case .generatedAsset(let url, let kind):
                if let messageId = self.streamingMessageId {
                    self.attachGeneratedAsset(url, kind: kind, toMessage: messageId)
                }
            }
        }

        switch outcome {
        case .downloadRequired(let model):
            requestDownloadBeforeUse(model: model)
            messages.append(ExecutionMessage(
                role: .tool,
                content: modelDownloadRequiredMessage(for: model, operation: plan.operationName),
                toolCallId: toolCall.id,
                name: plan.functionName
            ))
        case .toolMessage(let content, let metrics):
            if let messageId = streamingMessageId, let metrics {
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

            if !AIContentRenderingPolicy.shouldUseFastPlainText(for: content) {
                _ = MarkdownAttributedRenderer.finalRender(
                    markdown: content,
                    style: .default
                )
            }

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

    func updateMessageToolCall(_ messageId: UUID, status: String) {
        if let location = messageLocation(for: messageId),
           var toolCall = chats[location.chatIndex].messages[location.messageIndex].toolCalls.last {
            let chatIndex = location.chatIndex
            let messageIndex = location.messageIndex
            toolCall.status = status
            chats[chatIndex].messages[messageIndex].toolCalls[chats[chatIndex].messages[messageIndex].toolCalls.count - 1] = toolCall
        }
    }

    func contextMessages(from chat: Chat, excluding excludedMessageId: UUID) -> [Message] {
        let completedMessages = chat.messages.filter { message in
            message.id != excludedMessageId && !message.isStreaming
        }

        return Array(completedMessages.suffix(20))
    }

    func handleGenerationError(_ error: Error, replacingMessageId messageId: UUID? = nil) {
        if error is CancellationError {
            print("[ChatVM] Ignoring cancellation error: \(error)")
            return
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
        isModelLoading = false
        streamingMessageId = nil
        generationTask = nil
        loadingMessage = ""
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        guard let execError = error as? ExecutionError else {
            return "The request could not be completed. Please try again."
        }

        switch execError {
        case .pythonError,
             .notInitialized,
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
             .invalidResponse,
             .processCrashed,
             .encodingFailed,
             .decodingFailed,
             .requiresManualRetry,
             .pythonError:
            return "The local engine stopped. Restart to continue."
        }
    }
}

extension ChatViewModel: VLMExecutionDelegate {
    func modelLoadingStarted(modelId: String) {
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
        modelLoadProgress = progress
        loadingMessage = progress.detail ?? progress.phase.displayTitle
    }

    func modelLoadingCompleted(modelId: String) {
        isModelLoading = false
        loadingMessage = ""
        modelLoadProgress = nil
    }

    func modelLoadingFailed(modelId: String, error: Error) {
        isModelLoading = false
        loadingMessage = ""
        modelLoadProgress = nil
    }

    func executionWillRetry(attempt: Int) {
        loadingMessage = "Retrying (attempt \(attempt))..."
    }

    func executionDidFail(error: Error) {
    }
}
