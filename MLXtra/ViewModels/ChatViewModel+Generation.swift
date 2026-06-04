import Foundation

private struct ChatGenerationExecutionContext {
    let prompt: String
    let isImageGeneration: Bool
    let isSpeechGeneration: Bool
    let isMusicGeneration: Bool
    let isDeepResearch: Bool
    let activeChatProfile: ModelCapabilityProfile
    let executionProfile: ModelCapabilityProfile
    let resolvedModelId: String
    let activeModelName: String
    let activeBackend: RuntimeBackend
    let modelWillLoad: Bool
    let modelLoadParameters: [String: Any]?
    let requiredModel: DownloadableModel

    var requiredOperationName: String {
        isImageGeneration ? "Image generation" : (isSpeechGeneration ? "Speech generation" : "Chat")
    }

    var activeEngineRole: LocalEngineModelRole {
        isImageGeneration ? .image : (isSpeechGeneration ? .speech : .chat)
    }
}

@MainActor
extension ChatViewModel {
    func generateMusicDirectly(for request: ChatGenerationRequest, generationID: UUID? = nil) async {
        guard ownsActiveGeneration(generationID) else { return }
        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            finishActiveGeneration(isMusicGeneration: true, generationID: generationID)
            return
        }

        do {
            let musicProfile = request.profile(for: .music)
            let model = musicProfile.downloadableModel
            setActiveEngineModel(name: musicProfile.name, role: .music)

            guard await requireDownloadedModel(model: model, operation: "Music generation") else {
                finishActiveGeneration(isMusicGeneration: true, generationID: generationID)
                return
            }
            guard ownsActiveGeneration(generationID) else { return }

            guard try await ensureLocalRuntimeReady(generationID: generationID) else { return }

            isGenerating = true
            loadingMessage = "Generating music..."
            generationProgress = nil

            let aiMessage = Message(
                content: "",
                isUser: false,
                timestamp: Date(),
                isStreaming: true
            )

            if let index = chats.firstIndex(where: { $0.id == request.chatId }) {
                _ = streamingContentStore.begin(messageId: aiMessage.id)
                chats[index].messages.append(aiMessage)
                chats[index].timestamp = Date()
                streamingMessageId = aiMessage.id
            }

            let parameters = ChatMusicToolPlanBuilder.makeParameters(
                prompt: trimmedPrompt,
                decodedArguments: nil,
                executionParameters: request.executionParameters(for: musicProfile),
                composerSelection: musicComposerSelection(prompt: trimmedPrompt),
                applyAutomaticInstrumentalFallback: false,
                promptSoundsVocal: promptSoundsVocal
            )

            let toolCall = ExecutionToolCall(
                id: "direct-music-\(UUID().uuidString)",
                function: ExecutionToolCallFunction(
                    name: "generate_music",
                    arguments: jsonArguments(parameters)
                )
            )
            var toolMessages = [ExecutionMessage(role: .assistant, toolCalls: [toolCall])]

            await executeMusicGenerationToolCall(
                toolCall,
                messages: &toolMessages,
                prompt: trimmedPrompt,
                generation: request,
                generationID: generationID
            )
            guard ownsActiveGeneration(generationID) else { return }

            finishTerminalMediaToolResult(
                messages: toolMessages,
                messageId: aiMessage.id,
                isMusicGeneration: true,
                generationID: generationID
            )
        } catch {
            guard ownsActiveGeneration(generationID) else { return }
            activeMusicGenerationDraft = nil
            isPythonLoading = false
            isModelLoading = false
            isGenerating = false
            generationTask = nil
            loadingMessage = ""
            generationProgress = nil
            if Task.isCancelled {
                finishCancelledGeneration(isMusicGeneration: true, generationID: generationID)
                return
            }
            if let streamingMessageId {
                handleGenerationError(
                    error,
                    replacingMessageId: streamingMessageId,
                    generationID: generationID,
                    isMusicGeneration: true
                )
            } else {
                handleGenerationError(error, generationID: generationID, isMusicGeneration: true)
            }
        }
    }

    func generateResponse(for request: ChatGenerationRequest, toolMessages: [ExecutionMessage]? = nil, toolDepth: Int = 0, generationID: UUID? = nil) async {
        guard ownsActiveGeneration(generationID) else { return }
        let cancellationIsMusicGeneration = request.isMusicGeneration
        do {
            let context = generationExecutionContext(for: request)
            let prompt = context.prompt
            let isImageGeneration = context.isImageGeneration
            let isSpeechGeneration = context.isSpeechGeneration
            let isMusicGeneration = context.isMusicGeneration
            let isDeepResearch = context.isDeepResearch
            let activeChatProfile = context.activeChatProfile
            let executionProfile = context.executionProfile
            setActiveEngineModel(
                name: context.activeModelName,
                role: context.activeEngineRole
            )

            guard await requireGenerationDownloads(
                for: context,
                request: request,
                generationID: generationID
            ) else { return }

            guard try await prepareLocalEngineForGeneration(
                context,
                generationID: generationID
            ) else { return }

            isGenerating = true
            generationProgress = nil

            let aiMessage: Message
            let isFollowUp = toolMessages != nil

            if isFollowUp {
                guard let existingId = streamingMessageId,
                      let chatIndex = chats.firstIndex(where: { $0.id == request.chatId }),
                      let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == existingId }) else {
                    finishActiveGeneration(isMusicGeneration: isMusicGeneration, generationID: generationID)
                    return
                }
                _ = streamingContentStore.begin(messageId: existingId, initialText: chats[chatIndex].messages[messageIndex].content)
                aiMessage = chats[chatIndex].messages[messageIndex]
                loadingMessage = "Using tool result..."
            } else {
                let initialToolCall: ToolCall?
                if isImageGeneration {
                    initialToolCall = ToolCall(
                        toolName: "Image generation",
                        status: prompt,
                        icon: "photo",
                        details: toolCallDetails([], includingModel: executionProfile.name)
                    )
                } else if isSpeechGeneration {
                    initialToolCall = ToolCall(
                        toolName: "Speech generation",
                        status: prompt,
                        icon: "waveform",
                        details: toolCallDetails([], includingModel: executionProfile.name)
                    )
                } else {
                    initialToolCall = nil
                }

                aiMessage = Message(
                    content: "",
                    isUser: false,
                    timestamp: Date(),
                    toolCall: initialToolCall,
                    isStreaming: true
                )

                if let index = chats.firstIndex(where: { $0.id == request.chatId }) {
                    _ = streamingContentStore.begin(messageId: aiMessage.id)
                    chats[index].messages.append(aiMessage)
                    chats[index].timestamp = Date()
                    streamingMessageId = aiMessage.id
                }
            }

            let tools: [[String: Any]]? = (isImageGeneration || isSpeechGeneration) ? nil : (isMusicGeneration ? [musicGenerationTool] : availableTools(toolDepth: toolDepth, for: request.tool))
            let allowedToolNames = ChatExecutionMessageBuilder.toolNames(from: tools)

            var messages: [ExecutionMessage]
            if let toolMessages {
                messages = toolMessages
            } else {
                let musicContext: ChatExecutionMusicSystemContext?
                if isMusicGeneration {
                    musicIntentState = musicIntentStateForCurrentComposer(prompt: prompt)
                    musicContext = ChatExecutionMusicSystemContext(
                        intentState: musicIntentState,
                        composerInstruction: musicComposerInstruction(prompt: prompt)
                    )
                } else {
                    musicContext = nil
                }

                messages = ChatExecutionMessageBuilder.makeInitialMessages(
                    chat: chats.first(where: { $0.id == request.chatId }),
                    excluding: aiMessage.id,
                    baseSystemPrompt: isDeepResearch ? deepResearchSystemPrompt : systemPrompt,
                    allowedToolNames: allowedToolNames,
                    musicContext: musicContext
                )

                if isDeepResearch {
                    let researchContext = await seedDeepResearchContext(
                        prompt: prompt,
                        generationID: generationID
                    )
                    guard ownsActiveGeneration(generationID) else { return }
                    messages.append(contentsOf: researchContext)
                }
            }

            let outputDirectory = isImageGeneration ? generatedImagesDirectory : (isSpeechGeneration ? generatedSpeechDirectory : nil)
            let executionRequest = ChatExecutionRequestBuilder.makeRequest(
                generation: request,
                activeChatProfile: activeChatProfile,
                executionProfile: executionProfile,
                messages: messages,
                tools: tools,
                outputDirectory: outputDirectory
            )

            let stream = try await vlmExecutor.execute(request: executionRequest)
            guard ownsActiveGeneration(generationID) else { return }

            await processStream(
                stream,
                forMessage: aiMessage.id,
                messages: messages,
                request: request,
                toolDepth: toolDepth,
                hasTools: tools != nil,
                allowedToolNames: allowedToolNames,
                isImageGeneration: isImageGeneration,
                isSpeechGeneration: isSpeechGeneration,
                isMusicGeneration: isMusicGeneration,
                generationID: generationID
            )

        } catch {
            guard ownsActiveGeneration(generationID) else { return }
            if Task.isCancelled {
                finishCancelledGeneration(isMusicGeneration: cancellationIsMusicGeneration, generationID: generationID)
                return
            }
            if let streamingMessageId {
                handleGenerationError(
                    error,
                    replacingMessageId: streamingMessageId,
                    generationID: generationID,
                    isMusicGeneration: cancellationIsMusicGeneration
                )
            } else {
                handleGenerationError(
                    error,
                    generationID: generationID,
                    isMusicGeneration: cancellationIsMusicGeneration
                )
            }
        }
    }

    @discardableResult
    func executeToolCall(
        _ toolCall: ExecutionToolCall,
        messages: inout [ExecutionMessage],
        images: [URL],
        prompt: String,
        generation: ChatGenerationRequest,
        generationID: UUID? = nil
    ) async -> ChatToolCallExecutionResult {
        guard ownsActiveGeneration(generationID) else { return .nonTerminal }
        switch canonicalToolName(toolCall.function.name) {
        case "web_search":
            await executeWebSearchToolCall(
                toolCall,
                messages: &messages,
                prompt: prompt,
                generationID: generationID
            )
            return .nonTerminal
        case "generate_image":
            await executeImageGenerationToolCall(
                toolCall,
                messages: &messages,
                images: images,
                prompt: prompt,
                generation: generation,
                generationID: generationID
            )
            return .terminalMedia
        case "create_speech":
            await executeSpeechGenerationToolCall(
                toolCall,
                messages: &messages,
                prompt: prompt,
                generation: generation,
                generationID: generationID
            )
            return .terminalMedia
        case "generate_music", "create_music":
            return await executeMusicGenerationToolCall(
                toolCall,
                messages: &messages,
                prompt: prompt,
                generation: generation,
                generationID: generationID
            )
        default:
            messages.append(ExecutionMessage(
                role: .tool,
                content: "Unsupported tool: \(toolCall.function.name)",
                toolCallId: toolCall.id,
                name: toolCall.function.name
            ))
            return .nonTerminal
        }
    }

    private func executeWebSearchToolCall(
        _ toolCall: ExecutionToolCall,
        messages: inout [ExecutionMessage],
        prompt: String,
        generationID: UUID? = nil
    ) async {
        guard ownsActiveGeneration(generationID) else { return }
        var searchQuery = prompt
        if let decoded = decodeToolArguments(toolCall),
           let query = decoded["query"] as? String {
            searchQuery = query
        }

        loadingMessage = "Searching for \"\(searchQuery)\"..."
        beginToolCallProgress(
            toolName: "Web search",
            status: searchQuery,
            icon: "magnifyingglass",
            generationID: generationID
        )
        let result = await toolExecutor.executeWebSearch(query: searchQuery)
        guard ownsActiveGeneration(generationID) else { return }
        messages.append(ExecutionMessage(role: .tool, content: result, toolCallId: toolCall.id, name: "web_search"))
    }

    private func executeImageGenerationToolCall(
        _ toolCall: ExecutionToolCall,
        messages: inout [ExecutionMessage],
        images: [URL],
        prompt: String,
        generation: ChatGenerationRequest,
        generationID: UUID? = nil
    ) async {
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolPlanBuilder.makeImagePlan(
                decodedArguments: decodeToolArguments(toolCall),
                fallbackPrompt: prompt,
                images: images,
                generation: generation,
                outputDirectory: generatedImagesDirectory
            ),
            generationID: generationID
        )
    }

    private func executeSpeechGenerationToolCall(
        _ toolCall: ExecutionToolCall,
        messages: inout [ExecutionMessage],
        prompt: String,
        generation: ChatGenerationRequest,
        generationID: UUID? = nil
    ) async {
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolPlanBuilder.makeSpeechPlan(
                decodedArguments: decodeToolArguments(toolCall),
                fallbackPrompt: prompt,
                generation: generation,
                outputDirectory: generatedSpeechDirectory
            ),
            generationID: generationID
        )
    }

    @discardableResult
    private func executeMusicGenerationToolCall(
        _ toolCall: ExecutionToolCall,
        messages: inout [ExecutionMessage],
        prompt: String,
        generation: ChatGenerationRequest,
        generationID: UUID? = nil
    ) async -> ChatToolCallExecutionResult {
        let musicProfile = generation.profile(for: .music)
        let parameters = ChatMusicToolPlanBuilder.makeParameters(
            prompt: prompt,
            decodedArguments: decodeToolArguments(toolCall),
            executionParameters: generation.executionParameters(for: musicProfile),
            composerSelection: musicComposerSelection(prompt: prompt),
            applyAutomaticInstrumentalFallback: true,
            promptSoundsVocal: promptSoundsVocal
        )

        musicIntentState = musicIntentStateForCurrentComposer(prompt: prompt, parameters: parameters)
        if let blockedToolMessage = musicIntentState.blockedToolMessage {
            messages.append(ExecutionMessage(
                role: .tool,
                content: blockedToolMessage,
                toolCallId: toolCall.id,
                name: "generate_music"
            ))
            return .blockedTerminalMedia
        }

        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMusicToolPlanBuilder.makePlan(
                parameters: parameters,
                fallbackPrompt: prompt,
                musicProfile: musicProfile,
                outputDirectory: generatedMusicDirectory
            ),
            generationID: generationID
        )
        return .terminalMedia
    }

    private func generationExecutionContext(for request: ChatGenerationRequest) -> ChatGenerationExecutionContext {
        let isImageGeneration = request.isImageGeneration
        let isSpeechGeneration = request.isSpeechGeneration
        let selectedCapabilityProfile = request.profile(for: request.tool)
        let activeChatProfile = request.profile(for: .chat)
        let executionProfile = (isImageGeneration || isSpeechGeneration) ? selectedCapabilityProfile : activeChatProfile
        let resolvedModelId = executionProfile.modelId
        let activeBackend = executionProfile.backend
        let modelLoadParameters = (isImageGeneration || isSpeechGeneration)
            ? request.executionParameters(for: executionProfile)
            : nil

        return ChatGenerationExecutionContext(
            prompt: request.prompt,
            isImageGeneration: isImageGeneration,
            isSpeechGeneration: isSpeechGeneration,
            isMusicGeneration: request.isMusicGeneration,
            isDeepResearch: request.isDeepResearch,
            activeChatProfile: activeChatProfile,
            executionProfile: executionProfile,
            resolvedModelId: resolvedModelId,
            activeModelName: executionProfile.name,
            activeBackend: activeBackend,
            modelWillLoad: !isLoadedEngineModel(modelId: resolvedModelId, backend: activeBackend),
            modelLoadParameters: modelLoadParameters,
            requiredModel: executionProfile.downloadableModel
        )
    }

    private func requireGenerationDownloads(
        for context: ChatGenerationExecutionContext,
        request: ChatGenerationRequest,
        generationID: UUID?
    ) async -> Bool {
        if let selectionRequirement = request.selectionDownloadRequirement,
           selectionRequirement.modelId != context.requiredModel.modelId {
            guard await requireDownloadedModel(
                model: selectionRequirement,
                operation: request.selectionOperationName
            ) else {
                finishActiveGeneration(isMusicGeneration: context.isMusicGeneration, generationID: generationID)
                return false
            }
            guard ownsActiveGeneration(generationID) else { return false }
        }

        guard await requireDownloadedModel(
            model: context.requiredModel,
            operation: context.requiredOperationName
        ) else {
            finishActiveGeneration(isMusicGeneration: context.isMusicGeneration, generationID: generationID)
            return false
        }
        return ownsActiveGeneration(generationID)
    }

    private func prepareLocalEngineForGeneration(
        _ context: ChatGenerationExecutionContext,
        generationID: UUID?
    ) async throws -> Bool {
        let runtimeProgress = ModelLoadProgress(
            modelId: context.resolvedModelId,
            backend: context.activeBackend,
            phase: .preparing,
            detail: "Preparing runtime"
        )
        guard try await ensureLocalRuntimeReady(
            progress: runtimeProgress,
            generationID: generationID
        ) else {
            return false
        }

        return try await loadModelIfNeeded(for: context, generationID: generationID)
    }

    private func loadModelIfNeeded(
        for context: ChatGenerationExecutionContext,
        generationID: UUID?
    ) async throws -> Bool {
        guard context.modelWillLoad else { return true }

        isModelLoading = true
        loadingMessage = "Loading \(context.activeModelName)..."
        modelLoadProgress = ModelLoadProgress(
            modelId: context.resolvedModelId,
            backend: context.activeBackend,
            phase: .preparing,
            detail: "Preparing \(context.activeModelName)"
        )

        do {
            try await loadModel(
                context.resolvedModelId,
                backend: context.activeBackend,
                parameters: context.modelLoadParameters
            )
            return ownsActiveGeneration(generationID)
        } catch {
            if ownsActiveGeneration(generationID) {
                isModelLoading = false
                modelLoadProgress = nil
                generationProgress = nil
            }
            throw error
        }
    }

    private func musicComposerSelection(prompt: String) -> ChatMusicComposerSelection {
        ChatMusicComposerSelection(
            mode: activeMusicGenerationDraft?.vocalMode ?? resolvedMusicVocalMode(for: prompt),
            approvedLyrics: activeMusicGenerationDraft?.lyrics
                ?? musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
