import Foundation

@MainActor
extension ChatViewModel {
    func loadModel(_ modelId: String, backend: RuntimeBackend, parameters: [String: Any]? = nil) async throws {
        try await vlmExecutor.preload(modelId: modelId, backend: backend, parameters: parameters)
    }

    func ownsActiveGeneration(_ generationID: UUID?) -> Bool {
        guard let generationID else { return true }
        return activeGenerationID == generationID
    }

    func finishActiveGeneration(isMusicGeneration: Bool, generationID: UUID? = nil) {
        guard ownsActiveGeneration(generationID) else { return }
        if isMusicGeneration {
            activeMusicGenerationDraft = nil
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

    func finishCancelledGeneration(isMusicGeneration: Bool, generationID: UUID? = nil) {
        guard ownsActiveGeneration(generationID) else { return }
        if let streamingMessageId {
            markMessageStopped(streamingMessageId)
        }
        finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
        chatPersistence.flushPendingSave()
    }

    func finishTerminalMediaToolResult(
        messages: [ExecutionMessage],
        messageId: UUID,
        isMusicGeneration: Bool,
        generationID: UUID? = nil
    ) {
        guard ownsActiveGeneration(generationID) else { return }
        if let toolContent = messages.last(where: { $0.role == .tool })?.content,
           !isModelDownloadRequiredMessage(toolContent),
           !toolContent.contains("already displayed") {
            updateStreamingMessage(messageId, content: toolContent)
        }

        if let toolContent = messages.last(where: { $0.role == .tool })?.content,
           isModelDownloadRequiredMessage(toolContent) {
            removeAssistantMessage(messageId)
        } else {
            markMessageStopped(messageId)
        }

        finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
    }

    private func finishStreamWithMessage(
        _ messageId: UUID,
        content: String,
        usage: TokenUsage,
        performanceMetrics: GenerationPerformanceMetrics,
        isMusicGeneration: Bool,
        generationID: UUID? = nil
    ) {
        guard ownsActiveGeneration(generationID) else { return }
        finalizeMessage(
            messageId,
            content: content,
            usage: usage,
            clearToolCall: false,
            performanceMetrics: performanceMetrics
        )
        finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
    }

    private func handleCompletedStream(
        response: String,
        usage: TokenUsage,
        messageId: UUID,
        messages: [ExecutionMessage]?,
        request: ChatGenerationRequest,
        toolDepth: Int,
        allowedToolNames: Set<String>,
        isImageGeneration: Bool,
        isSpeechGeneration: Bool,
        isMusicGeneration: Bool,
        performanceMetrics: GenerationPerformanceMetrics,
        generationID: UUID? = nil
    ) async {
        guard ownsActiveGeneration(generationID) else { return }
        if !request.shouldPrepareDirectImagePrompt,
           let plainTextToolCall = plainTextToolCall(from: response, prompt: request.prompt),
           var currentMessages = messages {
            guard isToolAllowed(plainTextToolCall.function.name, allowedToolNames: allowedToolNames) else {
                finishStreamWithMessage(
                    messageId,
                    content: "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it.",
                    usage: usage,
                    performanceMetrics: performanceMetrics,
                    isMusicGeneration: isMusicGeneration,
                    generationID: generationID
                )
                return
            }

            guard isTerminalMediaTool(plainTextToolCall.function.name) || toolDepth < maxAutoToolDepth else {
                finishStreamWithMessage(
                    messageId,
                    content: "Maximum tool call depth reached. Cannot execute more tool calls.",
                    usage: usage,
                    performanceMetrics: performanceMetrics,
                    isMusicGeneration: isMusicGeneration,
                    generationID: generationID
                )
                return
            }

            updateStreamingMessage(messageId, content: "")
            currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [plainTextToolCall]))
            let executionResult = await executeToolCall(
                plainTextToolCall,
                messages: &currentMessages,
                images: request.images,
                prompt: request.prompt,
                generation: request,
                generationID: generationID
            )

            if executionResult == .terminalMedia {
                finishTerminalMediaToolResult(
                    messages: currentMessages,
                    messageId: messageId,
                    isMusicGeneration: isMusicGeneration,
                    generationID: generationID
                )
                return
            }

            if executionResult == .blockedTerminalMedia {
                await generateResponse(for: request, toolMessages: currentMessages, toolDepth: toolDepth + 1, generationID: generationID)
                return
            }

            await generateResponse(for: request, toolMessages: currentMessages, toolDepth: toolDepth + 1, generationID: generationID)
            return
        }

        if isImageGeneration,
           request.shouldPrepareDirectImagePrompt,
           var currentMessages = messages {
            let preparedToolCall: ExecutionToolCall
            do {
                preparedToolCall = try preparedImageGenerationToolCall(
                    from: response,
                    generation: request
                )
            } catch {
                finishStreamWithMessage(
                    messageId,
                    content: "Image generation unavailable: Image prompt preparation failed: \(error.localizedDescription)",
                    usage: usage,
                    performanceMetrics: performanceMetrics,
                    isMusicGeneration: false,
                    generationID: generationID
                )
                return
            }
            updateStreamingMessage(messageId, content: "")
            currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [preparedToolCall]))
            await executeImageGenerationToolCall(
                preparedToolCall,
                messages: &currentMessages,
                images: request.images,
                prompt: request.prompt,
                generation: request,
                promptIsPrepared: true,
                generationID: generationID
            )
            finishTerminalMediaToolResult(
                messages: currentMessages,
                messageId: messageId,
                isMusicGeneration: false,
                generationID: generationID
            )
            return
        }

        guard ownsActiveGeneration(generationID) else { return }
        finalizeMessage(
            messageId,
            content: (isImageGeneration || isSpeechGeneration) ? "" : response,
            usage: usage,
            clearToolCall: isImageGeneration || isSpeechGeneration,
            performanceMetrics: performanceMetrics
        )
        finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
    }

    private func handleToolCallStreamEvent(
        _ toolCalls: [ExecutionToolCall],
        messageId: UUID,
        messages: [ExecutionMessage]?,
        request: ChatGenerationRequest,
        toolDepth: Int,
        allowedToolNames: Set<String>,
        isMusicGeneration: Bool,
        fallbackMetrics: GenerationPerformanceMetrics,
        generationID: UUID? = nil
    ) async -> Bool {
        guard ownsActiveGeneration(generationID) else { return true }
        guard var currentMessages = messages else { return false }
        let executableToolCalls = toolCalls
            .filter { isToolAllowed($0.function.name, allowedToolNames: allowedToolNames) }
            .map(canonicalToolCall)

        guard !executableToolCalls.isEmpty else {
            finishStreamWithMessage(
                messageId,
                content: "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it.",
                usage: TokenUsage(promptTokens: 0, completionTokens: 0),
                performanceMetrics: fallbackMetrics,
                isMusicGeneration: isMusicGeneration,
                generationID: generationID
            )
            return true
        }

        let terminalMediaToolCalls = executableToolCalls.filter { isTerminalMediaTool($0.function.name) }
        guard toolDepth < maxAutoToolDepth || !terminalMediaToolCalls.isEmpty else {
            finishStreamWithMessage(
                messageId,
                content: "Maximum tool call depth reached. Cannot execute more tool calls.",
                usage: TokenUsage(promptTokens: 0, completionTokens: 0),
                performanceMetrics: fallbackMetrics,
                isMusicGeneration: isMusicGeneration,
                generationID: generationID
            )
            return true
        }

        let toolCallsToExecute = toolDepth < maxAutoToolDepth ? executableToolCalls : terminalMediaToolCalls
        var hasExecutedTerminalMediaTool = false
        var hasBlockedTerminalMediaTool = false
        updateStreamingMessage(messageId, content: "")
        for toolCall in toolCallsToExecute {
            currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [toolCall]))
            let executionResult = await executeToolCall(
                toolCall,
                messages: &currentMessages,
                images: request.images,
                prompt: request.prompt,
                generation: request,
                generationID: generationID
            )
            switch executionResult {
            case .terminalMedia:
                hasExecutedTerminalMediaTool = true
            case .blockedTerminalMedia:
                hasBlockedTerminalMediaTool = true
            case .nonTerminal:
                break
            }
        }

        if hasExecutedTerminalMediaTool {
            finishTerminalMediaToolResult(
                messages: currentMessages,
                messageId: messageId,
                isMusicGeneration: isMusicGeneration,
                generationID: generationID
            )
            return true
        }

        if hasBlockedTerminalMediaTool {
            await generateResponse(for: request, toolMessages: currentMessages, toolDepth: toolDepth + 1, generationID: generationID)
            return true
        }

        await generateResponse(for: request, toolMessages: currentMessages, toolDepth: toolDepth + 1, generationID: generationID)
        return true
    }

    func processStream(
        _ stream: AsyncStream<ExecutionEvent>,
        forMessage messageId: UUID,
        messages: [ExecutionMessage]? = nil,
        request: ChatGenerationRequest,
        toolDepth: Int = 0,
        hasTools: Bool = false,
        allowedToolNames: Set<String> = [],
        isImageGeneration: Bool = false,
        isSpeechGeneration: Bool = false,
        isMusicGeneration: Bool = false,
        generationID: UUID? = nil
    ) async {
        var fullResponse = ""
        var renderedResponse = ""
        var pendingRenderDelta = ""
        var pendingGeneratedImageURLs: [URL] = []
        var pendingGeneratedAudioURLs: [URL] = []
        var lastRenderTime = Date.distantPast
        let minimumRenderInterval: TimeInterval = 1.0 / 60.0
        var performanceTracker = ChatStreamPerformanceTracker()
        let overallTimeout = Self.generationTimeout
        var timeoutTask: Task<Void, Never>?
#if DEBUG
        var tokenIndex = 0
#endif

        func currentPerformanceMetrics(usage: TokenUsage) -> GenerationPerformanceMetrics {
            let completedAt = Date()
            let appMeasuredMetrics = performanceTracker.appMeasuredMetrics(
                usage: usage,
                completedAt: completedAt
            )
            let metrics = performanceTracker.metrics(
                usage: usage,
                completedAt: completedAt
            )
#if DEBUG
            if let bridgeTokensPerSecond = usage.tokensPerSecond,
               let appTokensPerSecond = appMeasuredMetrics.tokensPerSecond {
                ChatStreamDiagnostics.log("performance.compare bridgeTokS=\(String(format: "%.2f", bridgeTokensPerSecond)) appTokS=\(String(format: "%.2f", appTokensPerSecond)) outputTokens=\(metrics.outputTokenCount)")
            }
#endif
            return metrics
        }

        func renderStreamingResponse(force: Bool = false, tokenIndex: Int? = nil, tokenReceivedAt: TimeInterval? = nil) {
            guard !pendingRenderDelta.isEmpty else { return }

            let now = Date()
            guard force || renderedResponse.isEmpty || now.timeIntervalSince(lastRenderTime) >= minimumRenderInterval else {
                return
            }

            appendStreamingMessage(messageId, content: pendingRenderDelta)
            renderedResponse += pendingRenderDelta
            pendingRenderDelta = ""
            lastRenderTime = now

#if DEBUG
            if let tokenIndex, let tokenReceivedAt {
                let updateFinishedAt = ChatStreamDiagnostics.now()
                ChatStreamDiagnostics.log("message.rendered index=\(tokenIndex) responseChars=\(fullResponse.count) elapsedMs=\(String(format: "%.2f", (updateFinishedAt - tokenReceivedAt) * 1000))")
            }
#endif
        }

        timeoutTask = Task { [weak vlmExecutor] in
            try? await Task.sleep(nanoseconds: UInt64(overallTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
#if DEBUG
            ChatStreamDiagnostics.log("generation.timeout seconds=\(overallTimeout)")
#endif
            await vlmExecutor?.terminate()
        }
        defer {
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        for await event in stream {
            guard ownsActiveGeneration(generationID) else { return }
            if Task.isCancelled {
                markMessageStopped(messageId)
                break
            }

            switch event {
            case .started:
                break

            case .token(let token):
#if DEBUG
                tokenIndex += 1
                let tokenReceivedAt = ChatStreamDiagnostics.now()
                ChatStreamDiagnostics.log("token.received index=\(tokenIndex) tokenChars=\(token.count) responseCharsBefore=\(fullResponse.count)")
#endif
                guard !token.isEmpty else {
#if DEBUG
                    ChatStreamDiagnostics.log("token.emptySkipped index=\(tokenIndex) responseChars=\(fullResponse.count)")
#endif
                    continue
                }

                performanceTracker.recordTokenOutput()
                fullResponse += token
                if request.shouldPrepareDirectImagePrompt
                    || (hasTools && shouldBufferToolEnabledOutput(fullResponse)) {
                    loadingMessage = request.shouldPrepareDirectImagePrompt
                        ? "Preparing image prompt..."
                        : "Preparing tool..."
#if DEBUG
                    ChatStreamDiagnostics.log("token.buffered index=\(tokenIndex) responseChars=\(fullResponse.count)")
#endif
                } else {
                    if renderedResponse.isEmpty, pendingRenderDelta.isEmpty, fullResponse != token {
                        pendingRenderDelta = fullResponse
                    } else {
                        pendingRenderDelta += token
                    }
#if DEBUG
                    renderStreamingResponse(force: renderedResponse.isEmpty, tokenIndex: tokenIndex, tokenReceivedAt: tokenReceivedAt)
#else
                    renderStreamingResponse(force: renderedResponse.isEmpty)
#endif
                }
                if performanceTracker.observedTokenEvents % 3 == 0 {
                    await Task.yield()
                }

            case .image(let imageURL):
                performanceTracker.recordNonTokenOutput()
                if isImageGeneration {
                    pendingGeneratedImageURLs.append(imageURL)
                } else {
                    appendGeneratedImage(imageURL, toMessage: messageId)
                }

            case .audio(let audioURL):
                performanceTracker.recordNonTokenOutput()
                if isSpeechGeneration {
                    pendingGeneratedAudioURLs.append(audioURL)
                } else {
                    appendGeneratedAudio(audioURL, toMessage: messageId)
                }

            case .complete(let response, let usage):
#if DEBUG
                ChatStreamDiagnostics.log("stream.complete responseChars=\(response.count)")
#endif
                fullResponse = response
                let performanceMetrics = currentPerformanceMetrics(usage: usage)
                if hasTools {
                    await handleCompletedStream(
                        response: response,
                        usage: usage,
                        messageId: messageId,
                        messages: messages,
                        request: request,
                        toolDepth: toolDepth,
                        allowedToolNames: allowedToolNames,
                        isImageGeneration: isImageGeneration,
                        isSpeechGeneration: isSpeechGeneration,
                        isMusicGeneration: isMusicGeneration,
                        performanceMetrics: performanceMetrics,
                        generationID: generationID
                    )
                    return
                }

                guard ownsActiveGeneration(generationID) else { return }
                for imageURL in pendingGeneratedImageURLs {
                    appendGeneratedImage(imageURL, toMessage: messageId)
                }
                for audioURL in pendingGeneratedAudioURLs {
                    appendGeneratedAudio(audioURL, toMessage: messageId)
                }
                finalizeMessage(
                    messageId,
                    content: (isImageGeneration || isSpeechGeneration) ? "" : fullResponse,
                    usage: usage,
                    clearToolCall: isImageGeneration || isSpeechGeneration,
                    performanceMetrics: performanceMetrics
                )
                finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
                return

            case .toolCalls(let toolCalls):
                let fallbackUsage = TokenUsage(promptTokens: 0, completionTokens: 0)
                let handled = await handleToolCallStreamEvent(
                    toolCalls,
                    messageId: messageId,
                    messages: messages,
                    request: request,
                    toolDepth: toolDepth,
                    allowedToolNames: allowedToolNames,
                    isMusicGeneration: isMusicGeneration,
                    fallbackMetrics: currentPerformanceMetrics(usage: fallbackUsage),
                    generationID: generationID
                )
                if handled {
                    return
                }

            case .error(let error):
                guard ownsActiveGeneration(generationID) else { return }
                handleGenerationError(
                    error,
                    replacingMessageId: messageId,
                    generationID: generationID,
                    isMusicGeneration: isMusicGeneration
                )
                finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
                return

            case .progress(let message):
                loadingMessage = message

            case .modelLoadProgress(let progress):
                modelLoadProgress = progress
                loadingMessage = progress.detail ?? progress.phase.displayTitle

            case .generationProgress(let progress):
                generationProgress = progress
                loadingMessage = progress.displayDetail
                updateMessageToolCall(messageId, progress: progress)
            }
        }

        guard ownsActiveGeneration(generationID) else { return }
        if Task.isCancelled {
            renderStreamingResponse(force: true)
            finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
            return
        }

        let streamStoppedError = ExecutionError.processStopped("The local engine stream ended before reporting completion.")
        if !hasTools,
           !isImageGeneration,
           !isSpeechGeneration,
           !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            renderStreamingResponse(force: true)
            localEngineErrorMessage = "Local engine stopped: The local engine stream ended before reporting completion."
            finalizeMessage(
                messageId,
                content: fullResponse,
                usage: TokenUsage(promptTokens: 0, completionTokens: 0),
                performanceMetrics: currentPerformanceMetrics(usage: TokenUsage(promptTokens: 0, completionTokens: 0))
            )
            finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
            return
        }

        handleGenerationError(
            streamStoppedError,
            replacingMessageId: messageId,
            generationID: generationID,
            isMusicGeneration: isMusicGeneration
        )
    }
}
