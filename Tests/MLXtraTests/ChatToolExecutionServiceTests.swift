import Combine
import XCTest
@testable import MLXtra

@MainActor
final class ChatToolExecutionServiceTests: XCTestCase {
    private static var defaultChatModelId: String {
        ModelCapabilityProfile.bestProfile(for: .vision)?.modelId
            ?? AIModel.defaultForCurrentHardware.modelId
    }
    private var standardDefaultsSnapshot: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        standardDefaultsSnapshot = [
            PromptConfiguration.systemPromptKey: UserDefaults.standard.object(forKey: PromptConfiguration.systemPromptKey),
            PromptConfiguration.deepResearchSystemPromptKey: UserDefaults.standard.object(forKey: PromptConfiguration.deepResearchSystemPromptKey),
            PromptConfiguration.toolDefinitionsKey: UserDefaults.standard.object(forKey: PromptConfiguration.toolDefinitionsKey),
        ]
    }

    override func tearDown() {
        for (key, value) in standardDefaultsSnapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        standardDefaultsSnapshot = [:]
        super.tearDown()
    }

    func testExecuteWebSearchReturnsContext() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let webSearch = MockChatWebSearchService(result: .success("search context"))
        let service = DefaultChatToolExecutionService(
            modelExecutor: executor,
            runtimeManager: runtimeManager,
            webSearchService: webSearch
        )

        let result = await service.executeWebSearch(query: "swift")

        XCTAssertEqual(result, "search context")
        XCTAssertEqual(webSearch.queries, ["swift"])
    }

    func testExecuteMediaToolReturnsDownloadRequiredWhenModelMissing() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let webSearch = MockChatWebSearchService(result: .success(nil))
        let service = DefaultChatToolExecutionService(
            modelExecutor: executor,
            runtimeManager: runtimeManager,
            webSearchService: webSearch
        )
        let model = DownloadableModel(
            id: "missing",
            name: "Missing Model",
            subtitle: "Image generation model",
            modelId: "missing",
            modality: .image,
            downloadSizeGB: 1.0
        )

        let outcome = await service.executeMediaTool(plan: makePlan(model: model)) { _ in }

        XCTAssertEqual(outcome, .downloadRequired(model))
        XCTAssertEqual(executor.receivedRequests.count, 0)
    }

    func testExecuteMediaToolPublishesProgressAndAssetAndReturnsSummary() async {
        let assetURL = URL(fileURLWithPath: "/tmp/generated.png")
        let executor = MockChatModelExecutor(events: [
            .progress("warming up"),
            .image(assetURL),
            .complete("Generated image.", usage: TokenUsage(promptTokens: 1, completionTokens: 2))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: ["image-model"])
        let webSearch = MockChatWebSearchService(result: .success(nil))
        let service = DefaultChatToolExecutionService(
            modelExecutor: executor,
            runtimeManager: runtimeManager,
            webSearchService: webSearch
        )
        var updates: [ChatToolExecutionUpdate] = []

        let outcome = await service.executeMediaTool(plan: makePlan()) { update in
            updates.append(update)
        }

        XCTAssertEqual(
            updates,
            [
                .progress("warming up"),
                .generatedAsset(assetURL, kind: .image)
            ]
        )
        guard case .toolMessage(let content, let metrics) = outcome else {
            XCTFail("Expected tool message outcome")
            return
        }
        XCTAssertEqual(content, "Generated image.\nThe generated image is already displayed in the app UI.")
        XCTAssertEqual(metrics?.outputTokenCount, 2)
        XCTAssertNotNil(metrics?.timeToFirstToken)
        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests[0].modelId, "image-model")
    }

    func testExecuteMediaToolInitializesExecutorWhenNeeded() async {
        let assetURL = URL(fileURLWithPath: "/tmp/generated.png")
        let executor = MockChatModelExecutor(events: [
            .image(assetURL),
            .complete("Generated image.", usage: TokenUsage(promptTokens: 1, completionTokens: 1))
        ])
        executor.isReady = false
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: ["image-model"])
        let webSearch = MockChatWebSearchService(result: .success(nil))
        let service = DefaultChatToolExecutionService(
            modelExecutor: executor,
            runtimeManager: runtimeManager,
            webSearchService: webSearch
        )

        _ = await service.executeMediaTool(plan: makePlan()) { _ in }

        XCTAssertEqual(executor.initializeCount, 1)
        XCTAssertEqual(executor.receivedRequests.count, 1)
    }

    func testInjectedPersistenceRestoresChatsAndNormalizesStreamingMessages() {
        let selectedChat = Chat(
            title: "Injected chat",
            messages: [
                Message(
                    content: "partial",
                    isUser: false,
                    timestamp: Date(),
                    isStreaming: true
                )
            ],
            timestamp: Date(),
            icon: "message"
        )
        let persistence = MockChatPersistenceService(
            chatsToLoad: [selectedChat],
            selectedChatIdToLoad: selectedChat.id
        )
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let toolExecutor = MockChatToolExecutionService()

        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )

        XCTAssertEqual(viewModel.selectedChatId, selectedChat.id)
        XCTAssertEqual(viewModel.chats.count, 1)
        XCTAssertFalse(viewModel.chats[0].messages[0].isStreaming)
        XCTAssertTrue(executor.delegate === viewModel)
    }

    func testStreamingContentUpdatesBypassPublishedChatTreeUntilStopped() throws {
        let messageId = UUID()
        let chat = Chat(
            title: "Streaming chat",
            messages: [
                Message(
                    id: messageId,
                    content: "",
                    isUser: false,
                    timestamp: Date(),
                    isStreaming: true
                )
            ],
            timestamp: Date(),
            icon: "message"
        )
        let viewModel = ChatViewModel(
            chatPersistence: MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil),
            vlmExecutor: MockChatModelExecutor(),
            runtimeManager: MockChatRuntimeManager(downloadedModelIds: []),
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.chats = [chat]
        viewModel.selectedChatId = chat.id
        _ = viewModel.streamingContentStore.begin(messageId: messageId)

        let streamingContent = try XCTUnwrap(viewModel.streamingContent(for: messageId))
        var chatTreePublishCount = 0
        var streamingPublishCount = 0
        var cancellables = Set<AnyCancellable>()
        viewModel.objectWillChange
            .sink { chatTreePublishCount += 1 }
            .store(in: &cancellables)
        streamingContent.objectWillChange
            .sink { streamingPublishCount += 1 }
            .store(in: &cancellables)

        viewModel.appendStreamingMessage(messageId, content: "First streamed")
        viewModel.appendStreamingMessage(messageId, content: " chunk")

        XCTAssertEqual(viewModel.chats[0].messages[0].content, "")
        XCTAssertEqual(streamingContent.text, "First streamed chunk")
        XCTAssertEqual(chatTreePublishCount, 0)
        XCTAssertEqual(streamingPublishCount, 2)

        viewModel.markMessageStopped(messageId)

        XCTAssertEqual(viewModel.chats[0].messages[0].content, "First streamed chunk")
        XCTAssertFalse(viewModel.chats[0].messages[0].isStreaming)
        XCTAssertNil(viewModel.streamingContent(for: messageId))
    }

    func testSendMessageBuildsImageGenerationRequestThroughInjectedExecutor() async {
        let assetURL = URL(fileURLWithPath: "/tmp/generated.png")
        let executor = MockChatModelExecutor(events: [
            .image(assetURL),
            .complete("Generated image.", usage: TokenUsage(promptTokens: 0, completionTokens: 0))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: ["black-forest-labs/FLUX.2-klein-4B"])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests[0].backend, .image)
        XCTAssertEqual(executor.receivedRequests[0].modelId, "black-forest-labs/FLUX.2-klein-4B")
        XCTAssertEqual(executor.receivedRequests[0].messages.first?.content, "Draw a quiet studio desk")
        XCTAssertEqual(viewModel.chats.first?.messages.last?.imageURLs, [assetURL])
        XCTAssertFalse(viewModel.chats.first?.messages.last?.isStreaming ?? true)
    }

    func testSendMessageUsesGenerationSnapshotWhenSelectionChangesAfterSend() async {
        let assetURL = URL(fileURLWithPath: "/tmp/generated.png")
        let executor = MockChatModelExecutor(events: [
            .image(assetURL),
            .complete("Generated image.", usage: TokenUsage(promptTokens: 0, completionTokens: 0))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: ["black-forest-labs/FLUX.2-klein-4B"])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        viewModel.selectedTool = .chat
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertEqual(executor.receivedRequests[0].backend, .image)
        XCTAssertEqual(executor.receivedRequests[0].modelId, "black-forest-labs/FLUX.2-klein-4B")
        XCTAssertEqual(viewModel.chats.first?.messages.last?.imageURLs, [assetURL])
    }

    func testStreamingContinuesUpdatingOriginalChatAfterSelectionChanges() async {
        let executor = MockChatModelExecutor(
            events: [
                .token("Original "),
                .token("answer."),
                .complete("Original answer.", usage: TokenUsage(promptTokens: 1, completionTokens: 2))
            ],
            eventDelayNanoseconds: 50_000_000
        )
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        let originalChatId = viewModel.selectedChatId
        let otherChat = Chat(title: "Other chat", messages: [], timestamp: Date(), icon: "message")
        viewModel.selectTool(.chat)
        viewModel.inputText = "Answer in the original chat"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 && viewModel.streamingMessageId != nil }
        viewModel.chats.append(otherChat)
        viewModel.selectChat(otherChat)

        await waitUntil {
            viewModel.chats.first(where: { $0.id == originalChatId })?.messages.last?.isStreaming == false
        }

        let originalMessages = viewModel.chats.first(where: { $0.id == originalChatId })?.messages ?? []
        let otherMessages = viewModel.chats.first(where: { $0.id == otherChat.id })?.messages ?? []
        XCTAssertEqual(viewModel.selectedChatId, otherChat.id)
        XCTAssertEqual(originalMessages.count, 2)
        XCTAssertEqual(originalMessages.last?.content, "Original answer.")
        XCTAssertFalse(originalMessages.last?.isStreaming ?? true)
        XCTAssertTrue(otherMessages.isEmpty)
    }

    func testGenerationActiveIgnoresComposerSelectionMenuAndFocusMutations() async {
        let executor = MockChatModelExecutor(
            events: [
                .token("First "),
                .complete("First answer.", usage: TokenUsage(promptTokens: 1, completionTokens: 1))
            ],
            eventDelayNanoseconds: 100_000_000
        )
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        let originalModel = viewModel.selectedModel
        let alternateModel = AIModel.allCases.first { $0 != originalModel } ?? originalModel
        let originalFocusRequest = viewModel.composerFocusRequest
        viewModel.selectTool(.chat)
        viewModel.inputText = "First prompt"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 && viewModel.isGenerating }

        viewModel.inputText = "Second prompt"
        viewModel.sendMessage()
        viewModel.selectTool(.image)
        viewModel.selectModel(alternateModel)
        viewModel.toggleToolMenu()
        viewModel.toggleModelMenu()
        viewModel.focusComposer()

        XCTAssertEqual(viewModel.inputText, "Second prompt")
        XCTAssertEqual(viewModel.selectedTool, .chat)
        XCTAssertEqual(viewModel.selectedModel, originalModel)
        XCTAssertFalse(viewModel.isToolMenuOpen)
        XCTAssertFalse(viewModel.isModelMenuOpen)
        XCTAssertEqual(viewModel.composerFocusRequest, originalFocusRequest)
        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertEqual(viewModel.chats.first?.messages.filter(\.isUser).count, 1)

        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }
    }

    func testAutoModeMediaToolCallUsesSendTimeParameterSnapshotAfterSettingsMutate() async throws {
        resetPromptConfigurationDefaults()
        let userDefaults = isolatedUserDefaults()
        let imageProfile = try XCTUnwrap(ModelCapabilityProfile.embeddedProfile(modelId: "black-forest-labs/FLUX.2-klein-4B"))
        let widthDefinition = try XCTUnwrap(imageProfile.parameterDefinition(key: "width"))
        let executor = MockChatModelExecutor(
            events: [
                .complete(
                    #"generate_image(prompt="Draw a quiet studio desk")"#,
                    usage: TokenUsage(promptTokens: 1, completionTokens: 2)
                )
            ],
            eventDelayNanoseconds: 75_000_000
        )
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor,
            userDefaults: userDefaults
        )
        viewModel.setParameterValue("512", for: widthDefinition, profile: imageProfile)
        viewModel.selectTool(.auto)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 && viewModel.isGenerating }
        viewModel.modelParameterStore.setValue("1536", for: "width", modelId: imageProfile.modelId)
        viewModel.selectTool(.tts)

        await waitUntil { toolExecutor.mediaPlans.count == 1 }

        let plan = toolExecutor.mediaPlans[0]
        let parameters = plan.request.parameters ?? [:]
        XCTAssertEqual(plan.functionName, "generate_image")
        XCTAssertEqual(plan.request.backend, .image)
        XCTAssertEqual(plan.request.modelId, imageProfile.modelId)
        XCTAssertEqual(parameters["width"] as? Int, 512)
        XCTAssertEqual(viewModel.selectedTool, .auto)
    }

    func testSendMessageBuildsSpeechGenerationRequestThroughInjectedExecutor() async {
        let assetURL = URL(fileURLWithPath: "/tmp/generated.wav")
        let executor = MockChatModelExecutor(events: [
            .audio(assetURL),
            .complete("Generated speech.", usage: TokenUsage(promptTokens: 0, completionTokens: 0))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: ["kugelaudio/kugelaudio-0-open"])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.tts)
        viewModel.inputText = "Superman is here"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests[0].backend, .audio)
        XCTAssertEqual(executor.receivedRequests[0].modelId, "kugelaudio/kugelaudio-0-open")
        XCTAssertEqual(executor.receivedRequests[0].messages.first?.content, "Superman is here")
        XCTAssertEqual(viewModel.chats.first?.messages.last?.audioURLs, [assetURL])
        XCTAssertFalse(viewModel.chats.first?.messages.last?.isStreaming ?? true)
    }

    func testChatModeSendsPlainVLMRequestWithoutTools() async {
        let executor = MockChatModelExecutor(events: [
            .token("Plain "),
            .token("answer."),
            .complete("Plain answer.", usage: TokenUsage(promptTokens: 1, completionTokens: 2))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.chat)
        viewModel.inputText = "Explain this simply"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertEqual(executor.receivedRequests[0].backend, .vlm)
        XCTAssertNil(executor.receivedRequests[0].tools)
        XCTAssertEqual(viewModel.chats.first?.messages.last?.content, "Plain answer.")
        XCTAssertEqual(viewModel.chats.first?.messages.last?.performanceMetrics?.outputTokenCount, 2)
        XCTAssertNotNil(viewModel.chats.first?.messages.last?.performanceMetrics?.timeToFirstToken)
        XCTAssertNotNil(viewModel.chats.first?.messages.last?.performanceMetrics?.tokensPerSecond)
    }

    func testChatModeUsesBridgeTokensPerSecondWhenAvailable() async {
        let executor = MockChatModelExecutor(events: [
            .token("Plain "),
            .token("answer."),
            .complete(
                "Plain answer.",
                usage: TokenUsage(
                    promptTokens: 1,
                    completionTokens: 2,
                    generationTokensPerSecond: 18.75
                )
            )
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.chat)
        viewModel.inputText = "Explain this simply"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertEqual(viewModel.chats.first?.messages.last?.performanceMetrics?.outputTokenCount, 2)
        XCTAssertEqual(viewModel.chats.first?.messages.last?.performanceMetrics?.tokensPerSecond, 18.75)
    }

    func testChatModeBlocksParsedToolCallWhenToolsAreUnavailable() async {
        let toolCall = ExecutionToolCall(
            id: "call_image",
            function: ExecutionToolCallFunction(
                name: "generate_image",
                arguments: #"{"prompt":"Draw a quiet studio desk"}"#
            )
        )
        let executor = MockChatModelExecutor(events: [
            .toolCalls([toolCall])
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.chat)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertNil(executor.receivedRequests[0].tools)
        XCTAssertTrue(toolExecutor.mediaPlans.isEmpty)
        XCTAssertEqual(
            viewModel.chats.first?.messages.last?.content,
            "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it."
        )
    }

    func testStreamErrorReplacesStreamingAssistantMessage() async {
        let executor = MockChatModelExecutor(events: [
            .error(ExecutionError.pythonError("bridge failed"))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { (viewModel.chats.first?.messages ?? []).count == 2 }

        let messages = viewModel.chats.first?.messages ?? []
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].isUser)
        XCTAssertFalse(messages[1].isUser)
        XCTAssertFalse(messages[1].isStreaming)
        XCTAssertEqual(messages[1].content, "The local engine stopped before it could finish. Restart it, then try again.")
        XCTAssertEqual(viewModel.localEngineStatus.state, .needsAttention)
        XCTAssertEqual(viewModel.localEngineStatus.primaryAction, .restart)
    }

    func testFreeLocalEngineMemoryTerminatesExecutorAndUpdatesStatus() async {
        let executor = MockChatModelExecutor()
        executor.isReady = true
        executor.isModelLoaded = true
        executor.currentModelId = Self.defaultChatModelId
        executor.currentModelBackend = .vlm
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )

        XCTAssertTrue(viewModel.canFreeLocalEngineMemory)

        viewModel.freeLocalEngineMemory()
        await waitUntil { executor.terminateCount == 1 }

        XCTAssertEqual(viewModel.localEngineStatus.state, .memoryFreed)
        XCTAssertEqual(viewModel.localEngineStatus.title, "Memory freed")
        XCTAssertFalse(viewModel.canFreeLocalEngineMemory)
    }

    func testMissingModelStatusPersistsAfterSettingsTriggerIsCleared() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { viewModel.modelDownloadRequest != nil }

        XCTAssertEqual(viewModel.localEngineStatus.state, .needsDownload)

        viewModel.clearModelDownloadRequest()

        XCTAssertNil(viewModel.modelDownloadRequest)
        XCTAssertEqual(viewModel.localEngineStatus.state, .needsDownload)
        XCTAssertEqual(viewModel.localEngineStatus.primaryAction, .openModels)
    }

    func testMissingModelStatusClearsAfterDownloadRefresh() async {
        let executor = MockChatModelExecutor()
        let imageModelId = "black-forest-labs/FLUX.2-klein-4B"
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio desk"
        viewModel.sendMessage()
        await waitUntil { viewModel.localEngineStatus.state == .needsDownload }

        runtimeManager.downloadedModelIds.insert(imageModelId)
        viewModel.refreshLocalEngineDownloadStatus()
        await waitUntil { viewModel.localEngineStatus.state != .needsDownload }

        XCTAssertNil(viewModel.pendingEngineDownloadModel)
    }

    func testSelectedImageModeShowsNeedsDownloadBeforeSend() async {
        let executor = MockChatModelExecutor()
        let imageModelId = "black-forest-labs/FLUX.2-klein-4B"
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )

        viewModel.selectTool(.image)
        viewModel.refreshLocalEngineDownloadStatus()
        await waitUntil { viewModel.localEngineStatus.state == .needsDownload }

        XCTAssertNil(viewModel.modelDownloadRequest)
        XCTAssertEqual(viewModel.pendingEngineDownloadModel?.modelId, imageModelId)
        XCTAssertEqual(viewModel.localEngineStatus.primaryActionModelId, imageModelId)
        XCTAssertEqual(executor.receivedRequests.count, 0)
        XCTAssertEqual(viewModel.chats.first?.messages.count, 0)
    }

    func testPreflightDownloadStatusClearsAfterDownload() async {
        let executor = MockChatModelExecutor()
        let imageModelId = "black-forest-labs/FLUX.2-klein-4B"
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )

        viewModel.selectTool(.image)
        await waitUntil { viewModel.localEngineStatus.state == .needsDownload }

        runtimeManager.downloadedModelIds.insert(imageModelId)
        viewModel.refreshLocalEngineDownloadStatus()
        await waitUntil { viewModel.pendingEngineDownloadModel == nil }

        XCTAssertNotEqual(viewModel.localEngineStatus.state, .needsDownload)
    }

    func testAutoModeDoesNotKeepNonTextPreflightRequirement() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )

        viewModel.inputText = ""
        viewModel.inputText = ""
        viewModel.selectTool(.music)
        await waitUntil { viewModel.localEngineStatus.state == .needsDownload }

        viewModel.selectTool(.auto)
        await waitUntil { viewModel.pendingEngineDownloadModel == nil }

        XCTAssertNotEqual(viewModel.localEngineStatus.state, .needsDownload)
        XCTAssertEqual(executor.receivedRequests.count, 0)
    }

    func testMissingMusicModelBlocksExplicitMusicGenerationBeforeChatLoad() async {
        let executor = MockChatModelExecutor()
        let musicModelId = "ACE-Step/acestep-v15-turbo-continuous"
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.music)
        viewModel.inputText = "Make an instrumental synthwave loop"

        viewModel.sendMessage()
        await waitUntil { viewModel.modelDownloadRequest?.modelId == musicModelId }

        XCTAssertEqual(viewModel.pendingEngineDownloadModel?.modelId, musicModelId)
        XCTAssertEqual(executor.receivedRequests.count, 0)
        XCTAssertEqual(viewModel.chats.first?.messages.count, 1)
    }

    func testAmbiguousMusicPromptRequestsMusicDownloadWithoutGettingStuckInComposer() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.music)
        viewModel.inputText = "Make a moody cyberpunk track"

        viewModel.sendMessage()
        await waitUntil { viewModel.modelDownloadRequest?.modelId == "ACE-Step/acestep-v15-turbo-continuous" }

        XCTAssertNil(viewModel.musicComposerPrompt)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertEqual(viewModel.modelDownloadRequest?.modelId, "ACE-Step/acestep-v15-turbo-continuous")
        XCTAssertEqual(executor.receivedRequests.count, 0)
        XCTAssertEqual(viewModel.chats.first?.messages.count, 1)
    }

    func testVocalMusicPromptStaysInComposerWithInlineLyricsEditorBeforeGenerating() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.music)
        viewModel.selectMusicVocalMode(.vocals)
        viewModel.inputText = "Make a warm pop song about London"

        viewModel.sendMessage()

        XCTAssertEqual(viewModel.musicComposerPrompt, .needsLyrics)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
        XCTAssertEqual(viewModel.composerPrimaryActionTitle, "Create music")
        XCTAssertFalse(viewModel.isComposerPrimaryActionEnabled)
        XCTAssertEqual(viewModel.inputText, "Make a warm pop song about London")
        XCTAssertEqual(executor.receivedRequests.count, 0)
        XCTAssertEqual(viewModel.chats.first?.messages.count, 0)
    }

    func testSelectingVocalMusicWithoutPromptKeepsComposerCompact() {
        let viewModel = ChatViewModel(
            chatPersistence: MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil),
            vlmExecutor: MockChatModelExecutor(),
            runtimeManager: MockChatRuntimeManager(downloadedModelIds: []),
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.music)

        viewModel.selectMusicVocalMode(.vocals)

        XCTAssertFalse(viewModel.isMusicLyricsEditorVisible)
        XCTAssertNil(viewModel.musicComposerPrompt)
        XCTAssertNil(viewModel.composerPrimaryActionTitle)
        XCTAssertFalse(viewModel.isComposerPrimaryActionEnabled)
    }

    func testEditingLyricsAfterApprovalKeepsMusicReadyForCreateAction() {
        let viewModel = ChatViewModel(
            chatPersistence: MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil),
            vlmExecutor: MockChatModelExecutor(),
            runtimeManager: MockChatRuntimeManager(downloadedModelIds: []),
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.music)
        viewModel.selectMusicVocalMode(.vocals)
        viewModel.inputText = "Make a warm pop song about London"
        viewModel.musicLyricsText = "[verse]\nOriginal line"
        viewModel.approveMusicLyrics()

        XCTAssertTrue(viewModel.hasApprovedMusicLyrics)

        viewModel.musicLyricsText = "[verse]\nEdited line"

        XCTAssertFalse(viewModel.hasApprovedMusicLyrics)
        XCTAssertNil(viewModel.musicComposerPrompt)
        XCTAssertEqual(viewModel.composerPrimaryActionTitle, "Create music")
        XCTAssertTrue(viewModel.isComposerPrimaryActionEnabled)
    }

    func testSwitchingMusicVocalModeClearsOppositeRequirements() {
        let viewModel = ChatViewModel(
            chatPersistence: MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil),
            vlmExecutor: MockChatModelExecutor(),
            runtimeManager: MockChatRuntimeManager(downloadedModelIds: []),
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.music)
        viewModel.inputText = "Make a warm pop song about London"
        viewModel.selectMusicVocalMode(.vocals)
        viewModel.musicLyricsText = "[verse]\nA line"
        viewModel.approveMusicLyrics()

        viewModel.selectMusicVocalMode(.instrumental)

        XCTAssertFalse(viewModel.hasApprovedMusicLyrics)
        XCTAssertFalse(viewModel.isMusicLyricsEditorVisible)
        XCTAssertNil(viewModel.musicComposerPrompt)
        XCTAssertEqual(viewModel.composerPrimaryActionTitle, "Create music")

        viewModel.selectMusicVocalMode(.vocals)

        XCTAssertNil(viewModel.musicComposerPrompt)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
        XCTAssertEqual(viewModel.composerPrimaryActionTitle, "Create music")
        XCTAssertTrue(viewModel.isComposerPrimaryActionEnabled)
    }

    func testEmptyMusicPromptWithLyricsDoesNotSendMessage() {
        let executor = MockChatModelExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil),
            vlmExecutor: executor,
            runtimeManager: MockChatRuntimeManager(downloadedModelIds: []),
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.music)
        viewModel.selectMusicVocalMode(.vocals)
        viewModel.musicLyricsText = "[verse]\nA line"
        viewModel.approveMusicLyrics()

        viewModel.sendMessage()

        XCTAssertEqual(executor.receivedRequests.count, 0)
        XCTAssertEqual(viewModel.chats.first?.messages.count, 0)
    }

    func testComposerDraftLabelsExplicitModes() {
        let viewModel = ChatViewModel(
            chatPersistence: MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil),
            vlmExecutor: MockChatModelExecutor(),
            runtimeManager: MockChatRuntimeManager(downloadedModelIds: []),
            toolExecutor: MockChatToolExecutionService()
        )

        viewModel.selectTool(.image)
        XCTAssertEqual(viewModel.composerDraft.placeholder, "Describe the image you want...")
        XCTAssertEqual(viewModel.composerDraft.primaryTitle, "Create image")
        XCTAssertEqual(viewModel.composerDraft.disabledHelp, "Describe the image you want")
        XCTAssertFalse(viewModel.composerDraft.isPrimaryEnabled)
        XCTAssertTrue(viewModel.composerDraft.slots.isEmpty)

        viewModel.inputText = "A quiet studio desk"
        XCTAssertTrue(viewModel.composerDraft.isPrimaryEnabled)

        viewModel.selectTool(.tts)
        XCTAssertEqual(viewModel.composerDraft.placeholder, "Type what you want spoken...")
        XCTAssertEqual(viewModel.composerDraft.primaryTitle, "Create speech")
        XCTAssertEqual(viewModel.composerDraft.disabledHelp, "Type what you want spoken")

        viewModel.selectTool(.research)
        XCTAssertEqual(viewModel.composerDraft.placeholder, "What should I research?")
        XCTAssertEqual(viewModel.composerDraft.primaryTitle, "Research")
        XCTAssertEqual(viewModel.composerDraft.disabledHelp, "Enter what you want researched")
        XCTAssertTrue(viewModel.composerDraft.slots.isEmpty)

        viewModel.inputText = ""
        viewModel.selectTool(.music)
        XCTAssertEqual(viewModel.composerDraft.placeholder, "Describe the music you want...")
        XCTAssertNil(viewModel.composerDraft.primaryTitle)
        XCTAssertEqual(viewModel.composerDraft.disabledHelp, "Describe the music you want")
        XCTAssertTrue(viewModel.composerDraft.slots.isEmpty)

        viewModel.inputText = "A moody cyberpunk track"
        XCTAssertEqual(viewModel.composerDraft.primaryTitle, "Create music")
        XCTAssertTrue(viewModel.composerDraft.slots.isEmpty)
    }

    func testExplicitMusicModeGeneratesDirectlyWithInstrumentalParameters() async {
        let musicModelId = "ACE-Step/acestep-v15-turbo-continuous"
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [
            musicModelId
        ])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.music)
        viewModel.inputText = "Make a moody cyberpunk track"
        viewModel.sendMessage()

        await waitUntil { toolExecutor.mediaPlans.count == 1 }

        XCTAssertEqual(executor.receivedRequests.count, 0)
        let userMessages = viewModel.chats.first?.messages.filter(\.isUser) ?? []
        XCTAssertEqual(userMessages.count, 1)
        XCTAssertEqual(userMessages.first?.content, "Make a moody cyberpunk track")
        let parameters = toolExecutor.mediaPlans[0].request.parameters ?? [:]
        XCTAssertEqual(parameters["instrumental"] as? Bool, true)
        XCTAssertEqual(parameters["lyrics"] as? String, "[Instrumental]")
    }

    func testApprovedMusicLyricsOverrideToolCallParameters() async {
        let musicModelId = "ACE-Step/acestep-v15-turbo-continuous"
        let toolCall = ExecutionToolCall(
            id: "music-1",
            function: ExecutionToolCallFunction(
                name: "generate_music",
                arguments: """
                {"caption":"warm pop song","instrumental":true,"lyrics":"wrong lyrics"}
                """
            )
        )
        let executor = MockChatModelExecutor(events: [
            .toolCalls([toolCall])
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [
            Self.defaultChatModelId,
            musicModelId
        ])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        let lyrics = "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
        viewModel.selectTool(.music)
        viewModel.selectMusicVocalMode(.vocals)
        viewModel.inputText = "Make a warm pop song about London"
        viewModel.musicLyricsText = lyrics
        viewModel.approveMusicLyrics()

        viewModel.sendMessage()
        await waitUntil { toolExecutor.mediaPlans.count == 1 }
        guard toolExecutor.mediaPlans.count == 1 else {
            let messageContents = viewModel.chats.first?.messages.map { $0.content } ?? []
            XCTFail("Expected one media plan, got \(toolExecutor.mediaPlans.count). Messages: \(messageContents)")
            return
        }

        let parameters = toolExecutor.mediaPlans[0].request.parameters ?? [:]
        XCTAssertEqual(parameters["instrumental"] as? Bool, false)
        XCTAssertEqual(parameters["lyrics"] as? String, lyrics)
    }

    func testAutoModeExecutesPlainTextMusicFunctionCallAlias() async {
        resetPromptConfigurationDefaults()
        let musicModelId = "ACE-Step/acestep-v15-turbo-continuous"
        let chatId = UUID()
        let existingChat = Chat(
            id: chatId,
            title: "London song",
            messages: [
                Message(
                    content: "Make a pop song about London with vocals",
                    isUser: true,
                    timestamp: Date()
                ),
                Message(
                    content: "Here are lyrics. Do these look good before I generate the music?",
                    isUser: false,
                    timestamp: Date()
                )
            ],
            timestamp: Date(),
            icon: "message"
        )
        let executor = MockChatModelExecutor(events: [
            .complete(
                #"create_music(lyrics="[Verse 1]\nLondon lights are calling\n[Chorus]\nWe rise tonight", instrumental=false)"#,
                usage: TokenUsage(promptTokens: 1, completionTokens: 2)
            )
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [
            Self.defaultChatModelId,
            musicModelId
        ])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [existingChat], selectedChatIdToLoad: chatId)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.auto)
        viewModel.inputText = "yes, generate"

        viewModel.sendMessage()
        await waitUntil { toolExecutor.mediaPlans.count == 1 }
        guard toolExecutor.mediaPlans.count == 1 else {
            let messageContents = viewModel.chats.first?.messages.map { $0.content } ?? []
            XCTFail("Expected one media plan, got \(toolExecutor.mediaPlans.count). Messages: \(messageContents)")
            return
        }

        let parameters = toolExecutor.mediaPlans[0].request.parameters ?? [:]
        XCTAssertEqual(parameters["caption"] as? String, "Make a pop song about London with vocals")
        XCTAssertEqual(parameters["lyrics"] as? String, "[Verse 1]\nLondon lights are calling\n[Chorus]\nWe rise tonight")
        XCTAssertEqual(parameters["instrumental"] as? Bool, false)
        XCTAssertFalse(viewModel.chats.first?.messages.contains { $0.content.contains("create_music(") } ?? true)
    }

    func testAutoModeExecutesPlainTextImageFunctionCallAlias() async {
        resetPromptConfigurationDefaults()
        let executor = MockChatModelExecutor(events: [
            .complete(
                #"create_image(prompt="Draw a quiet studio desk")"#,
                usage: TokenUsage(promptTokens: 1, completionTokens: 2)
            )
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.auto)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { toolExecutor.mediaPlans.count == 1 }
        guard toolExecutor.mediaPlans.count == 1 else {
            let messageContents = viewModel.chats.first?.messages.map { $0.content } ?? []
            XCTFail("Expected one media plan, got \(toolExecutor.mediaPlans.count). Messages: \(messageContents)")
            return
        }

        let plan = toolExecutor.mediaPlans[0]
        XCTAssertEqual(plan.functionName, "generate_image")
        XCTAssertEqual(plan.request.backend, .image)
        XCTAssertEqual(plan.request.modelId, "black-forest-labs/FLUX.2-klein-4B")
        XCTAssertEqual(plan.request.messages.first?.content, "Draw a quiet studio desk")
        XCTAssertFalse(viewModel.chats.first?.messages.contains { $0.content.contains("create_image(") } ?? true)
    }

    func testAutoModeExecutesPlainTextSpeechFunctionCallAlias() async {
        resetPromptConfigurationDefaults()
        let executor = MockChatModelExecutor(events: [
            .complete(
                #"generate_speech(text="Superman is here")"#,
                usage: TokenUsage(promptTokens: 1, completionTokens: 2)
            )
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.auto)
        viewModel.inputText = "Say Superman is here"

        viewModel.sendMessage()
        await waitUntil { toolExecutor.mediaPlans.count == 1 }
        guard toolExecutor.mediaPlans.count == 1 else {
            let messageContents = viewModel.chats.first?.messages.map { $0.content } ?? []
            XCTFail("Expected one media plan, got \(toolExecutor.mediaPlans.count). Messages: \(messageContents)")
            return
        }

        let plan = toolExecutor.mediaPlans[0]
        XCTAssertEqual(plan.functionName, "create_speech")
        XCTAssertEqual(plan.request.backend, .audio)
        XCTAssertEqual(plan.request.modelId, "kugelaudio/kugelaudio-0-open")
        XCTAssertEqual(plan.request.messages.first?.content, "Superman is here")
        XCTAssertFalse(viewModel.chats.first?.messages.contains { $0.content.contains("generate_speech(") } ?? true)
    }

    func testAutoModeExecutesStructuredMusicFunctionCallAlias() async {
        resetPromptConfigurationDefaults()
        let toolCall = ExecutionToolCall(
            id: "music-alias",
            function: ExecutionToolCallFunction(
                name: "create_music",
                arguments: #"{"caption":"instrumental synthwave loop","instrumental":true}"#
            )
        )
        let executor = MockChatModelExecutor(events: [
            .toolCalls([toolCall])
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.auto)
        viewModel.inputText = "Make an instrumental synthwave loop"

        viewModel.sendMessage()
        await waitUntil { toolExecutor.mediaPlans.count == 1 }
        guard toolExecutor.mediaPlans.count == 1 else {
            let messageContents = viewModel.chats.first?.messages.map { $0.content } ?? []
            XCTFail("Expected one media plan, got \(toolExecutor.mediaPlans.count). Messages: \(messageContents)")
            return
        }

        let plan = toolExecutor.mediaPlans[0]
        let parameters = plan.request.parameters ?? [:]
        XCTAssertEqual(plan.functionName, "generate_music")
        XCTAssertEqual(plan.request.backend, .music)
        XCTAssertEqual(parameters["caption"] as? String, "instrumental synthwave loop")
        XCTAssertEqual(parameters["instrumental"] as? Bool, true)
    }

    func testAutoModeDefaultsAmbiguousMusicToolCallToInstrumental() async {
        resetPromptConfigurationDefaults()
        let musicModelId = "ACE-Step/acestep-v15-turbo-continuous"
        let executor = MockChatModelExecutor(events: [
            .complete(
                #"generate_music(caption="moody cyberpunk track")"#,
                usage: TokenUsage(promptTokens: 1, completionTokens: 2)
            )
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [
            Self.defaultChatModelId,
            musicModelId
        ])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.auto)
        viewModel.inputText = "Make a moody cyberpunk track"

        viewModel.sendMessage()
        await waitUntil { toolExecutor.mediaPlans.count == 1 }

        let parameters = toolExecutor.mediaPlans[0].request.parameters ?? [:]
        XCTAssertEqual(parameters["caption"] as? String, "moody cyberpunk track")
        XCTAssertEqual(parameters["instrumental"] as? Bool, true)
        XCTAssertEqual(parameters["lyrics"] as? String, "[Instrumental]")
    }

    func testMalformedPlainTextFunctionCallStaysVisibleAndDoesNotExecute() async {
        resetPromptConfigurationDefaults()
        let executor = MockChatModelExecutor(events: [
            .complete(
                #"generate_image(prompt="Draw a quiet studio desk""#,
                usage: TokenUsage(promptTokens: 1, completionTokens: 2)
            )
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.auto)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertTrue(toolExecutor.mediaPlans.isEmpty)
        XCTAssertEqual(
            viewModel.chats.first?.messages.last?.content,
            #"generate_image(prompt="Draw a quiet studio desk""#
        )
    }

    func testMixedStructuredToolCallsExecuteOnlyAvailableTools() async {
        resetPromptConfigurationDefaults()
        let allowedToolCall = ExecutionToolCall(
            id: "image-1",
            function: ExecutionToolCallFunction(
                name: "generate_image",
                arguments: #"{"prompt":"Draw a quiet studio desk"}"#
            )
        )
        let unsupportedToolCall = ExecutionToolCall(
            id: "delete-1",
            function: ExecutionToolCallFunction(
                name: "delete_file",
                arguments: #"{"path":"/tmp/file"}"#
            )
        )
        let executor = MockChatModelExecutor(events: [
            .toolCalls([allowedToolCall, unsupportedToolCall])
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService()
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.auto)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { toolExecutor.mediaPlans.count == 1 }

        XCTAssertEqual(toolExecutor.mediaPlans.first?.functionName, "generate_image")
        XCTAssertFalse(viewModel.chats.first?.messages.contains { $0.content.contains("delete_file") } ?? true)
    }

    func testResearchSeedsWebSearchAndLimitsToolsToSearch() async {
        resetPromptConfigurationDefaults()
        let executor = MockChatModelExecutor(events: [
            .complete("Research answer.", usage: TokenUsage(promptTokens: 1, completionTokens: 1))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService(webSearchResult: "Source context")
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.research)
        viewModel.inputText = "What changed in Swift concurrency recently?"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }

        let request = executor.receivedRequests[0]
        XCTAssertEqual(toolExecutor.webSearchQueries, ["What changed in Swift concurrency recently?"])
        XCTAssertTrue(request.messages.contains { $0.content?.contains("Research mode") == true })
        XCTAssertTrue(request.messages.contains { $0.role == .tool && $0.content == "Source context" })

        let toolNames = request.tools?.compactMap { tool -> String? in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(toolNames, ["web_search"])
    }

    func testResearchModeExecutesPlainTextWebSearchFunctionCall() async {
        resetPromptConfigurationDefaults()
        let executor = MockChatModelExecutor(eventBatches: [
            [
                .complete(
                    #"web_search(query="Swift concurrency updates")"#,
                    usage: TokenUsage(promptTokens: 1, completionTokens: 2)
                )
            ],
            [
                .complete(
                    "Swift concurrency update summary.",
                    usage: TokenUsage(promptTokens: 3, completionTokens: 4)
                )
            ]
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService(webSearchResult: "Source context")
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.research)
        viewModel.inputText = "What changed in Swift concurrency recently?"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 2 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertEqual(
            toolExecutor.webSearchQueries,
            [
                "What changed in Swift concurrency recently?",
                "Swift concurrency updates"
            ]
        )
        XCTAssertEqual(viewModel.chats.first?.messages.last?.content, "Swift concurrency update summary.")
    }

    func testResearchModeBlocksPlainTextMediaToolCall() async {
        resetPromptConfigurationDefaults()
        let executor = MockChatModelExecutor(events: [
            .complete(
                #"generate_image(prompt="Draw a quiet studio desk")"#,
                usage: TokenUsage(promptTokens: 1, completionTokens: 2)
            )
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService(webSearchResult: "Source context")
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.research)
        viewModel.inputText = "Find studio desk inspiration"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertEqual(toolExecutor.webSearchQueries, ["Find studio desk inspiration"])
        XCTAssertTrue(toolExecutor.mediaPlans.isEmpty)
        XCTAssertEqual(
            viewModel.chats.first?.messages.last?.content,
            "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it."
        )
    }

    func testReadyStatusUsesExecutorLoadedModelInsteadOfSelectedModel() {
        let executor = MockChatModelExecutor()
        executor.isReady = true
        executor.isModelLoaded = true
        executor.currentModelId = "ACE-Step/acestep-v15-turbo-continuous"
        executor.currentModelBackend = .music
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )

        XCTAssertEqual(viewModel.localEngineStatus.title, "Music model is ready")
        XCTAssertEqual(viewModel.localEngineStatus.detail, "ACE-Step 1.5 Turbo is using memory locally.")
    }

    func testCompletedTerminalToolCallCancelsGenerationTimeout() async throws {
        resetPromptConfigurationDefaults()
        let originalTimeout = ChatViewModel.generationTimeout
        ChatViewModel.generationTimeout = 0.05
        defer { ChatViewModel.generationTimeout = originalTimeout }

        let executor = MockChatModelExecutor(events: [
            .complete(
                #"generate_image(prompt="Draw a quiet studio desk")"#,
                usage: TokenUsage(promptTokens: 1, completionTokens: 2)
            )
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [Self.defaultChatModelId])
        let toolExecutor = MockChatToolExecutionService(
            mediaOutcome: .toolMessage("The generated image is already displayed in the app UI.")
        )
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )
        viewModel.selectTool(.auto)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { toolExecutor.mediaPlans.count == 1 && !viewModel.isGenerating }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(executor.terminateCount, 0)
    }

    private func makePlan(model: DownloadableModel? = nil) -> ChatMediaToolExecutionPlan {
        let resolvedModel = model ?? DownloadableModel(
            id: "image-model",
            name: "Image Model",
            subtitle: "Image generation model",
            modelId: "image-model",
            modality: .image,
            downloadSizeGB: 1.0
        )

        return ChatMediaToolExecutionPlan(
            functionName: "generate_image",
            toolName: "Image generation",
            status: "Draw a cat",
            icon: "photo",
            details: [],
            model: resolvedModel,
            request: ExecutionRequest(
                backend: .image,
                modelId: resolvedModel.modelId,
                messages: [ExecutionMessage(role: .user, content: "Draw a cat")],
                outputDirectory: URL(fileURLWithPath: "/tmp"),
                maxTokens: 0,
                temperature: 1.0
            ),
            loadingStatus: "Generating image...",
            operationName: "Image generation",
            unavailablePrefix: "Image generation unavailable",
            noOutputMessage: "Image generation finished without returning an image.",
            completionHint: "The generated image is already displayed in the app UI.",
            attachmentKind: .image
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func resetPromptConfigurationDefaults() {
        UserDefaults.standard.removeObject(forKey: PromptConfiguration.systemPromptKey)
        UserDefaults.standard.removeObject(forKey: PromptConfiguration.deepResearchSystemPromptKey)
        UserDefaults.standard.removeObject(forKey: PromptConfiguration.toolDefinitionsKey)
    }

    private func isolatedUserDefaults() -> UserDefaults {
        let suiteName = "ChatToolExecutionServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class MockChatModelExecutor: ChatModelExecuting {
    let backend: RuntimeBackend = .vlm
    var isReady: Bool = true
    var isModelLoaded: Bool = false
    var currentModelId: String?
    var currentModelBackend: RuntimeBackend?
    weak var delegate: VLMExecutionDelegate?
    private let eventBatches: [[ExecutionEvent]]
    private let eventDelayNanoseconds: UInt64
    private(set) var receivedRequests: [ExecutionRequest] = []
    private(set) var terminateCount = 0
    private(set) var initializeCount = 0

    init(events: [ExecutionEvent] = [], eventDelayNanoseconds: UInt64 = 0) {
        self.eventBatches = [events]
        self.eventDelayNanoseconds = eventDelayNanoseconds
    }

    init(eventBatches: [[ExecutionEvent]], eventDelayNanoseconds: UInt64 = 0) {
        self.eventBatches = eventBatches.isEmpty ? [[]] : eventBatches
        self.eventDelayNanoseconds = eventDelayNanoseconds
    }

    func initialize() async throws {
        initializeCount += 1
        isReady = true
    }

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        let requestIndex = receivedRequests.count
        receivedRequests.append(request)
        currentModelId = request.modelId
        currentModelBackend = request.backend
        isModelLoaded = true
        let events = eventBatches[min(requestIndex, eventBatches.count - 1)]
        return AsyncStream { continuation in
            Task { @MainActor in
                for event in events {
                    if eventDelayNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: eventDelayNanoseconds)
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func terminate() async {
        terminateCount += 1
        isReady = false
        isModelLoaded = false
        currentModelId = nil
        currentModelBackend = nil
    }
}

@MainActor
private final class MockChatRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready
    var downloadedModelIds: Set<String>

    init(downloadedModelIds: Set<String>) {
        self.downloadedModelIds = downloadedModelIds
    }

    func initialize() async throws {}

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(modelId: String) async -> Bool {
        downloadedModelIds.contains(modelId)
    }
}

@MainActor
private final class MockChatWebSearchService: ChatWebSearching {
    var queries: [String] = []
    private let result: Result<String?, Error>

    init(result: Result<String?, Error>) {
        self.result = result
    }

    func searchContext(for query: String) async throws -> String? {
        queries.append(query)
        return try result.get()
    }
}

@MainActor
private final class MockChatPersistenceService: ChatPersistenceServicing {
    private let chatsToLoad: [Chat]
    private let selectedChatIdToLoad: UUID?
    private(set) var savedChats: [Chat] = []
    private(set) var savedSelectedChatId: UUID?

    init(chatsToLoad: [Chat], selectedChatIdToLoad: UUID?) {
        self.chatsToLoad = chatsToLoad
        self.selectedChatIdToLoad = selectedChatIdToLoad
    }

    func loadChats() -> [Chat] {
        chatsToLoad
    }

    func saveChats(_ chats: [Chat]) {
        savedChats = chats
    }

    func loadSelectedChatId() -> UUID? {
        selectedChatIdToLoad
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        savedSelectedChatId = selectedChatId
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL] {
        urls
    }

    func deleteAttachments(for chatId: UUID) {}
}

@MainActor
private final class MockChatToolExecutionService: ChatToolExecutionServicing {
    private let webSearchResult: String
    private let mediaOutcome: ChatToolExecutionOutcome
    private(set) var webSearchQueries: [String] = []
    private(set) var mediaPlans: [ChatMediaToolExecutionPlan] = []

    init(
        webSearchResult: String = "unused",
        mediaOutcome: ChatToolExecutionOutcome = .toolMessage("unused")
    ) {
        self.webSearchResult = webSearchResult
        self.mediaOutcome = mediaOutcome
    }

    func executeWebSearch(query: String) async -> String {
        webSearchQueries.append(query)
        return webSearchResult
    }

    func executeMediaTool(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async -> ChatToolExecutionOutcome {
        mediaPlans.append(plan)
        return mediaOutcome
    }
}
