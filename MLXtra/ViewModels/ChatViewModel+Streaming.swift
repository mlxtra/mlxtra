import Foundation

@MainActor
extension ChatViewModel {
    func loadModel(_ modelId: String) async throws {
        // The executor handles lazy loading, we just need to trigger it
        // by sending a request.
    }

    func finishActiveGeneration(isMusicGeneration: Bool) {
        if isMusicGeneration {
            activeMusicGenerationDraft = nil
        }
        isGenerating = false
        isModelLoading = false
        streamingMessageId = nil
        generationTask = nil
        loadingMessage = ""
        modelLoadProgress = nil
    }

    func finishCancelledGeneration(isMusicGeneration: Bool) {
        if let streamingMessageId {
            markMessageStopped(streamingMessageId)
        }
        finishActiveGeneration(isMusicGeneration: isMusicGeneration)
        chatPersistence.flushPendingSave()
    }

    func finishTerminalMediaToolResult(
        messages: [ExecutionMessage],
        messageId: UUID,
        isMusicGeneration: Bool
    ) {
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

        finishActiveGeneration(isMusicGeneration: isMusicGeneration)
    }

    private func finishStreamWithMessage(
        _ messageId: UUID,
        content: String,
        usage: TokenUsage,
        performanceMetrics: GenerationPerformanceMetrics,
        isMusicGeneration: Bool
    ) {
        finalizeMessage(
            messageId,
            content: content,
            usage: usage,
            clearToolCall: false,
            performanceMetrics: performanceMetrics
        )
        finishActiveGeneration(isMusicGeneration: isMusicGeneration)
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
        performanceMetrics: GenerationPerformanceMetrics
    ) async {
        if let plainTextToolCall = plainTextToolCall(from: response, prompt: request.prompt),
           var currentMessages = messages {
            guard isToolAllowed(plainTextToolCall.function.name, allowedToolNames: allowedToolNames) else {
                finishStreamWithMessage(
                    messageId,
                    content: "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it.",
                    usage: usage,
                    performanceMetrics: performanceMetrics,
                    isMusicGeneration: isMusicGeneration
                )
                return
            }

            guard isTerminalMediaTool(plainTextToolCall.function.name) || toolDepth < maxAutoToolDepth else {
                finishStreamWithMessage(
                    messageId,
                    content: "Maximum tool call depth reached. Cannot execute more tool calls.",
                    usage: usage,
                    performanceMetrics: performanceMetrics,
                    isMusicGeneration: isMusicGeneration
                )
                return
            }

            updateStreamingMessage(messageId, content: "")
            currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [plainTextToolCall]))
            await executeToolCall(
                plainTextToolCall,
                messages: &currentMessages,
                images: request.images,
                prompt: request.prompt,
                generation: request
            )

            if isTerminalMediaTool(plainTextToolCall.function.name) {
                finishTerminalMediaToolResult(
                    messages: currentMessages,
                    messageId: messageId,
                    isMusicGeneration: isMusicGeneration
                )
                return
            }

            await generateResponse(for: request, toolMessages: currentMessages, toolDepth: toolDepth + 1)
            return
        }

        finalizeMessage(
            messageId,
            content: (isImageGeneration || isSpeechGeneration) ? "" : response,
            usage: usage,
            clearToolCall: isImageGeneration || isSpeechGeneration,
            performanceMetrics: performanceMetrics
        )
        finishActiveGeneration(isMusicGeneration: isMusicGeneration)
    }

    private func handleToolCallStreamEvent(
        _ toolCalls: [ExecutionToolCall],
        messageId: UUID,
        messages: [ExecutionMessage]?,
        request: ChatGenerationRequest,
        toolDepth: Int,
        allowedToolNames: Set<String>,
        isMusicGeneration: Bool,
        fallbackMetrics: GenerationPerformanceMetrics
    ) async -> Bool {
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
                isMusicGeneration: isMusicGeneration
            )
            return true
        }

        guard toolDepth < maxAutoToolDepth else {
            finishStreamWithMessage(
                messageId,
                content: "Maximum tool call depth reached. Cannot execute more tool calls.",
                usage: TokenUsage(promptTokens: 0, completionTokens: 0),
                performanceMetrics: fallbackMetrics,
                isMusicGeneration: isMusicGeneration
            )
            return true
        }

        let hasTerminalMediaTool = executableToolCalls.contains { isTerminalMediaTool($0.function.name) }
        for toolCall in executableToolCalls {
            currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [toolCall]))
            await executeToolCall(toolCall, messages: &currentMessages, images: request.images, prompt: request.prompt, generation: request)
        }

        if hasTerminalMediaTool {
            finishTerminalMediaToolResult(
                messages: currentMessages,
                messageId: messageId,
                isMusicGeneration: isMusicGeneration
            )
            return true
        }

        await generateResponse(for: request, toolMessages: currentMessages, toolDepth: toolDepth + 1)
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
        isMusicGeneration: Bool = false
    ) async {
        var fullResponse = ""
        var renderedResponse = ""
        var pendingRenderDelta = ""
        var lastRenderTime = Date.distantPast
        let minimumRenderInterval: TimeInterval = 1.0 / 60.0
        let generationStartedAt = Date()
        var firstOutputAt: Date?
        var observedTokenEvents = 0
        let overallTimeout = Self.generationTimeout
        var timeoutTask: Task<Void, Never>?
#if DEBUG
        var tokenIndex = 0
#endif

        func currentPerformanceMetrics(usage: TokenUsage) -> GenerationPerformanceMetrics {
            let outputTokenCount = usage.completionTokens > 0 ? usage.completionTokens : observedTokenEvents
            let appMeasuredMetrics = GenerationPerformanceMetrics.measured(
                startedAt: generationStartedAt,
                firstOutputAt: firstOutputAt,
                outputTokenCount: outputTokenCount
            )
            let metrics = GenerationPerformanceMetrics.measured(
                startedAt: generationStartedAt,
                firstOutputAt: firstOutputAt,
                outputTokenCount: outputTokenCount,
                backendTokensPerSecond: usage.tokensPerSecond
            )
#if DEBUG
            if let bridgeTokensPerSecond = usage.tokensPerSecond,
               let appTokensPerSecond = appMeasuredMetrics.tokensPerSecond {
                ChatStreamDiagnostics.log("performance.compare bridgeTokS=\(String(format: "%.2f", bridgeTokensPerSecond)) appTokS=\(String(format: "%.2f", appTokensPerSecond)) outputTokens=\(outputTokenCount)")
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

                firstOutputAt = firstOutputAt ?? Date()
                observedTokenEvents += 1
                fullResponse += token
                if hasTools && shouldBufferToolEnabledOutput(fullResponse) {
                    loadingMessage = "Preparing tool..."
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
                if observedTokenEvents % 3 == 0 {
                    await Task.yield()
                }

            case .image(let imageURL):
                firstOutputAt = firstOutputAt ?? Date()
                appendGeneratedImage(imageURL, toMessage: messageId)

            case .audio(let audioURL):
                firstOutputAt = firstOutputAt ?? Date()
                appendGeneratedAudio(audioURL, toMessage: messageId)

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
                        performanceMetrics: performanceMetrics
                    )
                    return
                }

                finalizeMessage(
                    messageId,
                    content: (isImageGeneration || isSpeechGeneration) ? "" : fullResponse,
                    usage: usage,
                    clearToolCall: isImageGeneration || isSpeechGeneration,
                    performanceMetrics: performanceMetrics
                )
                finishActiveGeneration(isMusicGeneration: isMusicGeneration)
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
                    fallbackMetrics: currentPerformanceMetrics(usage: fallbackUsage)
                )
                if handled {
                    return
                }

            case .error(let error):
                handleGenerationError(error, replacingMessageId: messageId)
                finishActiveGeneration(isMusicGeneration: isMusicGeneration)
                return

            case .progress(let message):
                loadingMessage = message

            case .modelLoadProgress(let progress):
                modelLoadProgress = progress
                loadingMessage = progress.detail ?? progress.phase.displayTitle
            }
        }

        if Task.isCancelled {
            renderStreamingResponse(force: true)
            finishActiveGeneration(isMusicGeneration: isMusicGeneration)
        }
    }
}
