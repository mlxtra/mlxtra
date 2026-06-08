import Foundation

private struct ChatGenerationExecutionContext {
    let prompt: String
    let isImageGeneration: Bool
    let isImagePromptPreparation: Bool
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
    let promptPreparationOperationName: String?
    let promptPreparationStatus: String?
    let requiredDownloadDetail: String?

    var requiredOperationName: String {
        if isImagePromptPreparation {
            return promptPreparationOperationName ?? "Image prompt preparation"
        }
        return isImageGeneration ? "Image generation" : (isSpeechGeneration ? "Speech generation" : "Chat")
    }

    var activeEngineRole: LocalEngineModelRole {
        if isImagePromptPreparation {
            return .chat
        }
        return isImageGeneration ? .image : (isSpeechGeneration ? .speech : .chat)
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
                instrumentalOnly: !musicProfile.supportsMusicLyrics,
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
                requestTool: request.tool,
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
            let isImagePromptPreparation = context.isImagePromptPreparation
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
            if let promptPreparationStatus = context.promptPreparationStatus {
                loadingMessage = promptPreparationStatus
            }
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
                if isImageGeneration && !isImagePromptPreparation {
                    initialToolCall = ToolCall(
                        toolName: "Image generation",
                        status: prompt,
                        icon: "photo",
                        details: toolCallDetails([], includingModel: request.profile(for: .image).name)
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

            let tools: [[String: Any]]?
            if isImagePromptPreparation {
                tools = nil
            } else if isImageGeneration || isSpeechGeneration {
                tools = nil
            } else if isMusicGeneration {
                tools = [musicGenerationTool]
            } else {
                tools = availableTools(toolDepth: toolDepth, for: request.tool)
            }
            let allowedToolNames = ChatExecutionMessageBuilder.toolNames(from: tools)

            var messages: [ExecutionMessage]
            let activeChat = chats.first(where: { $0.id == request.chatId })
            var contextImages: [URL]
            if let toolMessages {
                messages = toolMessages
                contextImages = ChatExecutionMessageBuilder.contextImages(
                    chat: activeChat,
                    excluding: aiMessage.id
                )
            } else if isImagePromptPreparation {
                let imageProfile = request.profile(for: .image)
                let promptPreparationContext = ChatExecutionMessageBuilder.makeInitialContext(
                    chat: activeChat,
                    excluding: aiMessage.id,
                    baseSystemPrompt: PromptConfiguration.imagePromptPreparationSystemPrompt(
                        adapter: imageProfile.imagePromptAdapter,
                        modelName: imageProfile.name,
                        improvingPrompt: request.shouldImproveImagePrompt(for: imageProfile),
                        width: request.imageDimension("width", for: imageProfile),
                        height: request.imageDimension("height", for: imageProfile)
                    ),
                    allowedToolNames: [],
                    musicContext: nil
                )
                messages = promptPreparationContext.messages
                contextImages = promptPreparationContext.images
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

                let initialContext = ChatExecutionMessageBuilder.makeInitialContext(
                    chat: activeChat,
                    excluding: aiMessage.id,
                    baseSystemPrompt: isDeepResearch ? deepResearchSystemPrompt : systemPrompt,
                    allowedToolNames: allowedToolNames,
                    musicContext: musicContext
                )
                messages = initialContext.messages
                contextImages = initialContext.images

                if isDeepResearch {
                    let researchContext = await seedDeepResearchContext(
                        prompt: prompt,
                        generationID: generationID
                    )
                    guard ownsActiveGeneration(generationID) else { return }
                    messages.append(contentsOf: researchContext)
                }
            }

            let outputDirectory = context.executionProfile.backend == .image
                ? generatedImagesDirectory
                : (context.executionProfile.backend == .audio ? generatedSpeechDirectory : nil)
            let responseFormat = isImagePromptPreparation
                ? PromptConfiguration.imagePromptPreparationResponseFormat(
                    adapter: request.profile(for: .image).imagePromptAdapter
                )
                : nil
            let executionRequest = ChatExecutionRequestBuilder.makeRequest(
                generation: request,
                activeChatProfile: activeChatProfile,
                executionProfile: executionProfile,
                messages: messages,
                tools: tools,
                outputDirectory: outputDirectory,
                contextImages: contextImages,
                responseFormat: responseFormat
            )

            let stream = try await vlmExecutor.execute(request: executionRequest)
            guard ownsActiveGeneration(generationID) else { return }

            await processStream(
                stream,
                forMessage: aiMessage.id,
                messages: messages,
                request: request,
                toolDepth: toolDepth,
                hasTools: tools != nil || isImagePromptPreparation,
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

    func executeImageGenerationToolCall(
        _ toolCall: ExecutionToolCall,
        messages: inout [ExecutionMessage],
        images: [URL],
        prompt: String,
        generation: ChatGenerationRequest,
        promptIsPrepared: Bool = false,
        generationID: UUID? = nil
    ) async {
        let decodedArguments = decodeToolArguments(toolCall)
        let imageArguments: [String: Any]?
        do {
            let promptPreparationImages = combinedImages(
                ChatExecutionMessageBuilder.contextImages(
                    chat: chats.first(where: { $0.id == generation.chatId }),
                    excluding: streamingMessageId ?? UUID()
                ),
                images
            )
            imageArguments = promptIsPrepared
                ? decodedArguments
                : try await prepareImageToolArgumentsIfNeeded(
                    decodedArguments: decodedArguments,
                    fallbackPrompt: prompt,
                    generation: generation,
                    contextMessages: messages,
                    contextImages: promptPreparationImages,
                    generationID: generationID
                )
        } catch {
            guard ownsActiveGeneration(generationID) else { return }
            messages.append(ExecutionMessage(
                role: .tool,
                content: "Image generation unavailable: Image prompt preparation failed: \(error.localizedDescription)",
                toolCallId: toolCall.id,
                name: "generate_image"
            ))
            return
        }

        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolPlanBuilder.makeImagePlan(
                decodedArguments: imageArguments,
                fallbackPrompt: prompt,
                images: images,
                generation: generation,
                outputDirectory: generatedImagesDirectory
            ),
            generationID: generationID
        )
    }

    private func prepareImageToolArgumentsIfNeeded(
        decodedArguments: [String: Any]?,
        fallbackPrompt: String,
        generation: ChatGenerationRequest,
        contextMessages: [ExecutionMessage] = [],
        contextImages: [URL] = [],
        generationID: UUID?
    ) async throws -> [String: Any]? {
        let imageProfile = generation.profile(for: .image)
        guard generation.shouldPrepareImagePrompt(for: imageProfile) else {
            return decodedArguments
        }
        if imageProfile.imagePromptAdapter == .ideogram4JSON,
           ChatMediaToolPlanBuilder.structuredImageCaption(from: decodedArguments) != nil {
            return decodedArguments
        }

        let sourcePrompt = ChatMediaToolPlanBuilder.resolvedImagePrompt(
            decodedArguments: decodedArguments,
            fallbackPrompt: fallbackPrompt
        )
        loadingMessage = "Preparing image prompt..."
        let response = try await generateImagePromptPreparationResponse(
            sourcePrompt: sourcePrompt,
            imageProfile: imageProfile,
            generation: generation,
            contextMessages: contextMessages,
            contextImages: contextImages,
            generationID: generationID
        )
        return try imageToolArguments(
            fromPreparedResponse: response,
            sourcePrompt: sourcePrompt,
            adapter: imageProfile.imagePromptAdapter
        )
    }

    private func generateImagePromptPreparationResponse(
        sourcePrompt: String,
        imageProfile: ModelCapabilityProfile,
        generation: ChatGenerationRequest,
        contextMessages: [ExecutionMessage] = [],
        contextImages: [URL] = [],
        generationID: UUID?
    ) async throws -> String {
        let activeChatProfile = generation.profile(for: .chat)
        let systemPrompt = PromptConfiguration.imagePromptPreparationSystemPrompt(
            adapter: imageProfile.imagePromptAdapter,
            modelName: imageProfile.name,
            improvingPrompt: generation.shouldImproveImagePrompt(for: imageProfile),
            width: generation.imageDimension("width", for: imageProfile),
            height: generation.imageDimension("height", for: imageProfile)
        )
        let messages = ChatExecutionMessageBuilder.promptPreparationMessages(
            systemPrompt: systemPrompt,
            contextMessages: contextMessages,
            sourcePrompt: sourcePrompt
        )
        let request = ChatExecutionRequestBuilder.makeRequest(
            generation: generation,
            activeChatProfile: activeChatProfile,
            executionProfile: activeChatProfile,
            messages: messages,
            tools: nil,
            outputDirectory: nil,
            contextImages: contextImages,
            responseFormat: PromptConfiguration.imagePromptPreparationResponseFormat(
                adapter: imageProfile.imagePromptAdapter
            )
        )

        let stream = try await vlmExecutor.execute(request: request)
        var streamedResponse = ""
        var completedResponse: String?
        for await event in stream {
            guard ownsActiveGeneration(generationID) else {
                throw CancellationError()
            }
            if Task.isCancelled {
                throw CancellationError()
            }

            switch event {
            case .token(let token):
                streamedResponse += token
            case .complete(let response, _):
                completedResponse = response
            case .error(let error):
                throw error
            case .progress(let message):
                loadingMessage = message
            case .modelLoadProgress(let progress):
                modelLoadProgress = progress
                loadingMessage = progress.detail ?? progress.phase.displayTitle
            case .started, .image, .audio, .toolCalls, .generationProgress:
                break
            }
        }

        let response = (completedResponse ?? streamedResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else {
            throw ExecutionError.invalidResponse
        }
        return response
    }

    private func combinedImages(_ first: [URL], _ second: [URL]) -> [URL] {
        var seen = Set<String>()
        return (first + second).filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    func imageToolArguments(
        fromPreparedResponse response: String,
        sourcePrompt: String,
        adapter: ImagePromptAdapter
    ) throws -> [String: Any] {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logInvalidImagePromptPreparationResponse(
                "Image prompt preparation returned invalid JSON",
                response: response,
                adapter: adapter
            )
            throw ExecutionError.pythonError("The VLM did not return valid JSON. See diagnostics log for the returned text.")
        }

        logImagePromptPreparationJSON(object, adapter: adapter)

        switch adapter {
        case .plainText:
            guard let prompt = object["prompt"] as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logInvalidImagePromptPreparationResponse(
                    "Image prompt preparation JSON is missing prompt",
                    response: response,
                    adapter: adapter
                )
                throw ExecutionError.pythonError("The VLM response is missing a non-empty prompt.")
            }
            return ["prompt": prompt]
        case .ideogram4JSON:
            guard object["compositional_deconstruction"] is [String: Any] else {
                logInvalidImagePromptPreparationResponse(
                    "Ideogram prompt preparation JSON is missing compositional_deconstruction",
                    response: response,
                    adapter: adapter
                )
                throw ExecutionError.pythonError(
                    "The Ideogram 4 caption is missing compositional_deconstruction."
                )
            }
            return [
                "prompt": sourcePrompt,
                "caption": object
            ]
        }
    }

    private func logInvalidImagePromptPreparationResponse(
        _ message: String,
        response: String,
        adapter: ImagePromptAdapter
    ) {
        DiagnosticsLogStore.log(
            message,
            category: .generation,
            level: .warning,
            details: """
            Adapter: \(adapter.rawValue)
            Returned text:
            \(Self.truncatedDiagnosticsPreview(response))
            """
        )
    }

    private func logImagePromptPreparationJSON(
        _ object: [String: Any],
        adapter: ImagePromptAdapter
    ) {
        DiagnosticsLogStore.capture(
            "Image prompt preparation JSON captured before generation",
            category: .generation,
            level: .info,
            details: """
            Adapter: \(adapter.rawValue)
            Generated JSON:
            \(Self.truncatedDiagnosticsPreview(Self.diagnosticsJSONString(object)))
            """
        )
    }

    private static func truncatedDiagnosticsPreview(_ text: String, limit: Int = 4_000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed.isEmpty ? "<empty>" : trimmed
        }
        return "\(trimmed.prefix(limit))\n… [truncated \(trimmed.count - limit) characters]"
    }

    private static func diagnosticsJSONString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
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
            instrumentalOnly: !musicProfile.supportsMusicLyrics,
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
        let isImagePromptPreparation = request.shouldPrepareDirectImagePrompt
        let isSpeechGeneration = request.isSpeechGeneration
        let selectedCapabilityProfile = request.profile(for: request.tool)
        let activeChatProfile = request.profile(for: .chat)
        let imageProfile = request.profile(for: .image)
        let executionProfile = isImagePromptPreparation
            ? activeChatProfile
            : ((isImageGeneration || isSpeechGeneration) ? selectedCapabilityProfile : activeChatProfile)
        let resolvedModelId = executionProfile.modelId
        let activeBackend = executionProfile.backend
        let modelLoadParameters = (!isImagePromptPreparation && (isImageGeneration || isSpeechGeneration))
            ? request.executionParameters(for: executionProfile)
            : nil
        let ideogramPromptPreparation = isImagePromptPreparation
            && imageProfile.imagePromptAdapter == .ideogram4JSON
        let promptPreparationStatus: String?
        let requiredDownloadDetail: String?
        if ideogramPromptPreparation {
            if let reason = request.ideogramCaptionFallbackReason {
                promptPreparationStatus = "Preparing Ideogram caption with \(activeChatProfile.name)..."
                requiredDownloadDetail = "That does not look like a complete Ideogram JSON caption: \(reason) Download \(activeChatProfile.name) to prepare it automatically, or provide a valid Ideogram JSON caption to use Ideogram only."
            } else {
                promptPreparationStatus = nil
                requiredDownloadDetail = "Ideogram uses \(activeChatProfile.name) to turn plain prompts into structured captions. Download it, or provide a valid Ideogram JSON caption to use Ideogram only."
            }
        } else {
            promptPreparationStatus = nil
            requiredDownloadDetail = nil
        }

        return ChatGenerationExecutionContext(
            prompt: request.prompt,
            isImageGeneration: isImageGeneration,
            isImagePromptPreparation: isImagePromptPreparation,
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
            requiredModel: executionProfile.downloadableModel,
            promptPreparationOperationName: ideogramPromptPreparation ? "Ideogram prompt preparation" : nil,
            promptPreparationStatus: promptPreparationStatus,
            requiredDownloadDetail: requiredDownloadDetail
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
            operation: context.requiredOperationName,
            detail: context.requiredDownloadDetail
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
