import XCTest
@testable import MLXtra

final class ChatViewModelLogicTests: XCTestCase {
    private static let aceStepMusicModelId = "ACE-Step/acestep-v15-turbo-continuous"
    private var standardDefaultsSnapshot: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        standardDefaultsSnapshot = [
            ModelSelectionStore.musicKey: UserDefaults.standard.object(forKey: ModelSelectionStore.musicKey),
        ]
        UserDefaults.standard.set(Self.aceStepMusicModelId, forKey: ModelSelectionStore.musicKey)
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

    @MainActor
    func testRenameChatNormalizesPersistsAndKeepsConversationOrderTimestamp() {
        let chatId = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let persistence = RecordingChatPersistenceService(
            chats: [
                Chat(
                    id: chatId,
                    title: "Old name",
                    messages: [],
                    timestamp: timestamp,
                    icon: "message"
                )
            ],
            selectedChatId: chatId
        )
        let viewModel = ChatViewModel(chatPersistence: persistence)

        viewModel.renameChat(chatId, to: "  Product\nplanning  ")

        XCTAssertEqual(viewModel.chats.first?.title, "Product planning")
        XCTAssertEqual(viewModel.chats.first?.timestamp, timestamp)
        XCTAssertEqual(persistence.savedChats.last?.title, "Product planning")
        XCTAssertEqual(persistence.savedSelectedChatId, chatId)
    }

    @MainActor
    func testRenameChatFallsBackForEmptyTitle() {
        let chatId = UUID()
        let persistence = RecordingChatPersistenceService(
            chats: [
                Chat(
                    id: chatId,
                    title: "Old name",
                    messages: [],
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    icon: "message"
                )
            ],
            selectedChatId: chatId
        )
        let viewModel = ChatViewModel(chatPersistence: persistence)

        viewModel.renameChat(chatId, to: " \n\t ")

        XCTAssertEqual(viewModel.chats.first?.title, "Untitled")
        XCTAssertEqual(persistence.savedChats.last?.title, "Untitled")
    }

    func testMusicReadinessSystemInstructionBlocksPrematureGeneration() {
        let instruction = MusicIntentState.needsInstrumentalOrVocals.systemInstruction

        XCTAssertTrue(instruction.contains("ask whether"))
        XCTAssertTrue(instruction.contains("before calling generate_music"))
    }

    func testMusicIntentReadyForInstrumentalPrompt() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create an instrumental synthwave loop"), .readyToGenerate)
    }

    func testMusicIntentNeedsLyricsForVocalPrompt() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create a pop song with vocals"), .needsLyrics)
        XCTAssertTrue(MusicIntentState.needsLyrics.systemInstruction.contains("explicitly asks you to write lyrics"))
        XCTAssertTrue(MusicIntentState.needsLyrics.systemInstruction.contains("wait for approval"))
        XCTAssertFalse(MusicIntentState.needsLyrics.systemInstruction.contains("Draft concise lyrics yourself"))
    }

    func testMusicIntentNeedsInstrumentalOrVocalsWhenAmbiguous() {
        XCTAssertEqual(MusicIntentState.forPrompt("Create a moody cyberpunk track"), .needsInstrumentalOrVocals)
    }

    func testMusicToolCallAllowsAmbiguousPromptToUseDefaultMusicPath() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a moody cyberpunk track",
            parameters: ["caption": "moody cyberpunk track"]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicToolCallBlockedWhenLyricsAreDraftedWithoutApproval() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a pop song with vocals",
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .awaitingLyricsApproval)
        XCTAssertEqual(
            state.blockedToolMessage,
            "Do not call generate_music yet. Lyrics are present but not clearly user-provided or approved. Ask the user to approve those exact lyrics or provide different lyrics."
        )
    }

    func testMusicToolCallReadyWhenUserApprovesLyrics() {
        let state = MusicIntentState.forToolCall(
            prompt: "Yes, those lyrics look good. Go ahead.",
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicToolCallReadyWhenApprovalUsesPunctuation() {
        let state = MusicIntentState.forToolCall(
            prompt: "yes, generate",
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light",
                "instrumental": false
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicToolCallReadyWhenUserProvidesLyrics() {
        let prompt = """
        Create a pop song with these lyrics:
        [verse]
        Neon hearts are waking
        [chorus]
        We rise into the light
        """
        let state = MusicIntentState.forToolCall(
            prompt: prompt,
            parameters: [
                "caption": "bright pop song with vocals",
                "lyrics": "[verse]\nNeon hearts are waking\n[chorus]\nWe rise into the light"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    func testMusicIntentAcceptsStringInstrumentalToolParameter() {
        let state = MusicIntentState.forToolCall(
            prompt: "Create a mysterious orchestral clockwork garden cue",
            parameters: [
                "caption": "A 1-minute orchestral piece with violin, cello, harp, ticking rhythm, and soft chimes",
                "duration": "60",
                "instrumental": "True"
            ]
        )

        XCTAssertEqual(state, .readyToGenerate)
        XCTAssertNil(state.blockedToolMessage)
    }

    @MainActor
    func testMusicComposerDefaultsAmbiguousPromptToInstrumentalDraft() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create a moody cyberpunk track"

        let resolution = viewModel.musicComposerResolution()
        let draft = viewModel.composerDraft

        XCTAssertEqual(resolution.resolvedMode, .auto)
        XCTAssertEqual(resolution.generationDraft?.vocalMode, .instrumental)
        XCTAssertEqual(resolution.generationDraft?.lyrics, "[Instrumental]")
        XCTAssertNil(resolution.promptState)
        XCTAssertEqual(viewModel.composerPlaceholder, "Describe the music you want...")
        XCTAssertTrue(viewModel.shouldShowMusicComposerControls)
        XCTAssertEqual(viewModel.composerPrimaryActionTitle, "Create music")
        XCTAssertEqual(viewModel.composerPrimaryActionSystemImage, "music.note")
        XCTAssertEqual(viewModel.composerPrimaryActionHelp, "Create music")
        XCTAssertTrue(viewModel.isComposerPrimaryActionEnabled)
        XCTAssertEqual(draft.primaryAction, .createSong)
    }

    @MainActor
    func testMusicComposerRequestsLyricsForExplicitVocalPrompt() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create a pop song with vocals"
        viewModel.selectMusicVocalMode(.vocals)

        let resolution = viewModel.musicComposerResolution()

        XCTAssertEqual(resolution.resolvedMode, .vocals)
        XCTAssertEqual(resolution.promptState, .needsLyrics)
        XCTAssertNil(resolution.generationDraft)
        XCTAssertEqual(viewModel.musicComposerPrompt, .needsLyrics)
        XCTAssertEqual(viewModel.composerPrimaryActionHelp, "Add lyrics or choose Instrumental")
        XCTAssertEqual(viewModel.composerPrimaryActionDisabledHelp, "Add lyrics or choose Instrumental")
        XCTAssertFalse(viewModel.isComposerPrimaryActionEnabled)
    }

    @MainActor
    func testPrepareMusicGenerationSetsInstrumentalDraftAndClearsLyricsState() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.musicLyricsText = "[verse]\nOld draft"
        viewModel.musicLyricsApproved = true
        viewModel.isMusicLyricsEditorVisible = true

        let canGenerate = viewModel.prepareMusicGenerationIfNeeded(prompt: "  instrumental synthwave beat  ")

        XCTAssertTrue(canGenerate)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.vocalMode, .instrumental)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.lyrics, "[Instrumental]")
        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertFalse(viewModel.isMusicLyricsEditorVisible)
    }

    @MainActor
    func testPrepareMusicGenerationRequiresLyricsForVocalPrompt() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.selectMusicVocalMode(.vocals)

        let canGenerate = viewModel.prepareMusicGenerationIfNeeded(prompt: "Create a bright pop song with vocals")

        XCTAssertFalse(canGenerate)
        XCTAssertNil(viewModel.activeMusicGenerationDraft)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
    }

    @MainActor
    func testPrepareMusicGenerationUsesApprovedLyrics() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create a bright pop song"
        viewModel.musicLyricsText = "  [verse]\nNeon hearts wake up  "
        viewModel.approveMusicLyrics()

        let canGenerate = viewModel.prepareMusicGenerationIfNeeded(prompt: viewModel.inputText)

        XCTAssertTrue(canGenerate)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.vocalMode, .vocals)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.lyrics, "[verse]\nNeon hearts wake up")
        XCTAssertTrue(viewModel.hasApprovedMusicLyrics)
    }

    @MainActor
    func testPrepareMusicGenerationExtractsEmbeddedLyrics() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.selectMusicVocalMode(.vocals)

        let canGenerate = viewModel.prepareMusicGenerationIfNeeded(
            prompt: """
            Create a song:
            [verse]
            Static lights in the rain
            [chorus]
            We keep moving
            """
        )

        XCTAssertTrue(canGenerate)
        XCTAssertEqual(viewModel.activeMusicGenerationDraft?.vocalMode, .vocals)
        XCTAssertEqual(
            viewModel.activeMusicGenerationDraft?.lyrics,
            "[verse]\nStatic lights in the rain\n[chorus]\nWe keep moving"
        )
    }

    @MainActor
    func testMusicVocalModeSelectionUpdatesComposerState() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create a track"
        viewModel.musicLyricsText = "[verse]\nDraft"
        viewModel.musicLyricsApproved = true

        viewModel.performComposerSlotAction(.chooseInstrumental)
        XCTAssertEqual(viewModel.musicVocalMode, .instrumental)
        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertFalse(viewModel.isMusicLyricsEditorVisible)

        viewModel.performComposerSlotAction(.chooseVocals)
        XCTAssertEqual(viewModel.musicVocalMode, .vocals)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)

        viewModel.performComposerSlotAction(.showLyricsEditor)
        XCTAssertEqual(viewModel.musicVocalMode, .vocals)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)

        viewModel.selectMusicVocalMode(.auto)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
    }

    @MainActor
    func testApprovingEmptyLyricsKeepsEditorOpen() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.musicLyricsText = "  \n "

        viewModel.approveMusicLyrics()

        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
    }

    @MainActor
    func testComposerPrimaryActionDisabledWhenInputDisabled() {
        let viewModel = makeViewModel()
        viewModel.selectedTool = .music
        viewModel.inputText = "Create an instrumental cue"
        viewModel.isGenerating = true

        XCTAssertFalse(viewModel.isComposerPrimaryActionEnabled)
        XCTAssertEqual(viewModel.composerPrimaryActionDisabledHelp, "Describe the music you want")

        viewModel.performComposerPrimaryAction()
        XCTAssertEqual(viewModel.chats.first?.messages.count, 0)
    }

    @MainActor
    func testDownloadedVisionModelBecomesDefaultWhenNoStoredSelection() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("", forKey: ModelSelectionStore.chatKey)
        let downloadedProfile = try visionProfile("mlx-community/Qwen3.5-2B-MLX-4bit")
        let runtimeManager = DefaultSelectionRuntimeManager(downloadedModelIds: [downloadedProfile.modelId])
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: runtimeManager,
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        let didSelectDownloadedModel = await viewModel.selectDownloadedDefaultModelIfNeeded(for: .vision)

        XCTAssertTrue(didSelectDownloadedModel)
        XCTAssertEqual(viewModel.activeModelProfile.modelId, downloadedProfile.modelId)
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), downloadedProfile.modelId)
    }

    @MainActor
    func testDownloadedDefaultDoesNotOverrideStoredDownloadedVisionSelection() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storedProfile = try visionProfile("mlx-community/gemma-4-e2b-it-4bit")
        let downloadedProfile = try visionProfile("mlx-community/Qwen3.5-2B-MLX-4bit")
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(storedProfile.modelId, for: .vision)
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), storedProfile.modelId)
        let runtimeManager = DefaultSelectionRuntimeManager(downloadedModelIds: [
            storedProfile.modelId,
            downloadedProfile.modelId
        ])
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: runtimeManager,
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        let didSelectDownloadedModel = await viewModel.selectDownloadedDefaultModelIfNeeded(for: .vision)

        XCTAssertFalse(didSelectDownloadedModel)
        XCTAssertEqual(viewModel.activeModelProfile.modelId, storedProfile.modelId)
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), storedProfile.modelId)
    }

    @MainActor
    func testDownloadedDefaultReplacesStoredMissingVisionSelection() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storedMissingProfile = try visionProfile("mlx-community/gemma-4-e2b-it-4bit")
        let downloadedProfile = try visionProfile("mlx-community/Qwen3.5-2B-MLX-4bit")
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(storedMissingProfile.modelId, for: .vision)
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), storedMissingProfile.modelId)
        let runtimeManager = DefaultSelectionRuntimeManager(downloadedModelIds: [downloadedProfile.modelId])
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: runtimeManager,
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        let didSelectDownloadedModel = await viewModel.selectDownloadedDefaultModelIfNeeded(for: .vision)

        XCTAssertTrue(didSelectDownloadedModel)
        XCTAssertEqual(viewModel.activeModelProfile.modelId, downloadedProfile.modelId)
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), downloadedProfile.modelId)
    }

    @MainActor
    func testLaunchPreloadWarmsSelectedDownloadedVisionModel() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        await viewModel.launchModelPreloadTask?.value

        XCTAssertEqual(runtimeManager.initializeCount, 1)
        XCTAssertEqual(executor.preloadRequests.map { $0.modelId }, [profile.modelId])
        XCTAssertEqual(executor.preloadRequests.map { $0.backend }, [profile.backend])
        XCTAssertTrue(viewModel.isLoadedEngineModel(modelId: profile.modelId, backend: profile.backend))
        XCTAssertFalse(viewModel.isPreloadingLocalModel)

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        XCTAssertNil(viewModel.launchModelPreloadTask)
        XCTAssertEqual(executor.preloadRequests.count, 1)
    }

    @MainActor
    func testLaunchPreloadSkipsWhenSettingDisabled() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: ChatViewModel.launchModelPreloadEnabledKey)
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)

        XCTAssertNil(viewModel.launchModelPreloadTask)
        XCTAssertEqual(runtimeManager.initializeCount, 0)
        XCTAssertTrue(executor.preloadRequests.isEmpty)
    }

    @MainActor
    func testLaunchPreloadSkipsUnderSystemPressure() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager,
            launchModelPreloadPressureCheck: { true }
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        await viewModel.launchModelPreloadTask?.value

        XCTAssertNil(viewModel.launchModelPreloadTask)
        XCTAssertFalse(viewModel.isPreloadingLocalModel)
        XCTAssertEqual(runtimeManager.initializeCount, 0)
        XCTAssertTrue(executor.preloadRequests.isEmpty)
    }

    @MainActor
    func testLaunchPreloadSkipsWhenRuntimeIsIncompatible() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager,
            launchModelPreloadRuntimeCompatibilityCheck: { _ in false }
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        await viewModel.launchModelPreloadTask?.value

        XCTAssertNil(viewModel.launchModelPreloadTask)
        XCTAssertFalse(viewModel.isPreloadingLocalModel)
        XCTAssertEqual(runtimeManager.initializeCount, 0)
        XCTAssertTrue(executor.preloadRequests.isEmpty)
    }

    @MainActor
    func testLaunchPreloadSkipsWhenSelectedVisionModelIsNotDownloaded() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        await viewModel.launchModelPreloadTask?.value

        XCTAssertEqual(runtimeManager.initializeCount, 0)
        XCTAssertTrue(executor.preloadRequests.isEmpty)
        XCTAssertFalse(viewModel.isPreloadingLocalModel)

        runtimeManager.downloadedModelIds.insert(profile.modelId)
        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        await viewModel.launchModelPreloadTask?.value

        XCTAssertEqual(runtimeManager.initializeCount, 1)
        XCTAssertEqual(executor.preloadRequests.map { $0.modelId }, [profile.modelId])
    }

    @MainActor
    func testLaunchPreloadCancelsWhenModelSelectionChangesBeforeDelay() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try visionProfile("mlx-community/Qwen3.5-2B-MLX-4bit")
        let alternateProfile = try XCTUnwrap(testVisionProfiles.first { $0.modelId != profile.modelId })
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [
            profile.modelId,
            alternateProfile.modelId
        ])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 500_000_000)
        let task = viewModel.launchModelPreloadTask
        viewModel.selectModelProfile(alternateProfile)
        await task?.value

        XCTAssertNil(viewModel.launchModelPreloadTask)
        XCTAssertEqual(runtimeManager.initializeCount, 0)
        XCTAssertTrue(executor.preloadRequests.isEmpty)
        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.chatKey), alternateProfile.modelId)
    }

    @MainActor
    func testToolSelectionDoesNotCancelDelayedLaunchPreload() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 50_000_000)
        let task = try XCTUnwrap(viewModel.launchModelPreloadTask)
        viewModel.selectTool(.chat)
        await task.value

        XCTAssertEqual(runtimeManager.initializeCount, 1)
        XCTAssertEqual(executor.preloadRequests.map { $0.modelId }, [profile.modelId])
        XCTAssertEqual(executor.terminateCount, 0)
    }

    @MainActor
    func testNonChatModelSelectionDoesNotCancelDelayedLaunchPreload() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        let imageProfile = try XCTUnwrap(ModelCapabilityProfile.sortedProfiles(for: .image).first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 50_000_000)
        let task = try XCTUnwrap(viewModel.launchModelPreloadTask)
        viewModel.selectModelProfile(imageProfile)
        await task.value

        XCTAssertEqual(defaults.string(forKey: ModelSelectionStore.imageKey), imageProfile.modelId)
        XCTAssertEqual(runtimeManager.initializeCount, 1)
        XCTAssertEqual(executor.preloadRequests.map { $0.modelId }, [profile.modelId])
        XCTAssertEqual(executor.terminateCount, 0)
    }

    @MainActor
    func testForegroundGenerationAwaitsStartedLaunchPreloadForSameChatModel() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        executor.holdPreloadUntilReleased = true
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        let didStartPreloading = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            executor.preloadRequests.count == 1 && viewModel.isPreloadingLocalModel
        }
        XCTAssertTrue(didStartPreloading)
        XCTAssertFalse(viewModel.isInputDisabled)

        viewModel.inputText = "Explain the image"
        viewModel.sendMessage()
        XCTAssertTrue(executor.receivedRequests.isEmpty)
        executor.releasePreload()
        await viewModel.generationTask?.value

        XCTAssertEqual(executor.terminateCount, 0)
        XCTAssertEqual(executor.preloadRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests.map(\.modelId), [profile.modelId])
        XCTAssertNil(viewModel.launchModelPreloadTask)
        XCTAssertFalse(viewModel.isPreloadingLocalModel)
        XCTAssertFalse(viewModel.isInputDisabled)
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "Foreground response")
    }

    @MainActor
    func testNewChatDuringStartedLaunchPreloadKeepsWarmupAlive() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        executor.holdPreloadUntilReleased = true
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        let task = try XCTUnwrap(viewModel.launchModelPreloadTask)
        let didStartPreloading = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            executor.preloadRequests.count == 1 && viewModel.isPreloadingLocalModel
        }
        XCTAssertTrue(didStartPreloading)

        viewModel.createNewChat()
        executor.releasePreload()
        await task.value

        XCTAssertEqual(executor.terminateCount, 0)
        XCTAssertTrue(viewModel.isLoadedEngineModel(modelId: profile.modelId, backend: profile.backend))
    }

    @MainActor
    func testNewChatKeepsPreloadedModelReadyForFirstMessage() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        await viewModel.launchModelPreloadTask?.value
        XCTAssertTrue(executor.isModelLoaded)

        viewModel.createNewChat()

        XCTAssertEqual(executor.terminateCount, 0)
        XCTAssertTrue(executor.isModelLoaded)
        XCTAssertTrue(viewModel.isLoadedEngineModel(modelId: profile.modelId, backend: profile.backend))

        viewModel.inputText = "Hello"
        viewModel.sendMessage()
        await viewModel.generationTask?.value

        XCTAssertEqual(executor.preloadRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests.map(\.modelId), [profile.modelId])
        XCTAssertEqual(executor.terminateCount, 0)
    }

    @MainActor
    func testDeletingIdleSelectedChatKeepsPreloadedModelReadyForFirstMessage() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try XCTUnwrap(testVisionProfiles.first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(profile.modelId, for: .vision)
        let executor = LaunchPreloadTestExecutor()
        let runtimeManager = LaunchPreloadRuntimeManager(downloadedModelIds: [profile.modelId])
        let viewModel = makeLaunchPreloadViewModel(
            defaults: defaults,
            executor: executor,
            runtimeManager: runtimeManager
        )

        viewModel.scheduleLaunchModelPreload(delayNanoseconds: 0)
        await viewModel.launchModelPreloadTask?.value
        let selectedChat = try XCTUnwrap(viewModel.selectedChat)

        viewModel.deleteChat(selectedChat)

        XCTAssertEqual(executor.terminateCount, 0)
        XCTAssertTrue(viewModel.isLoadedEngineModel(modelId: profile.modelId, backend: profile.backend))

        viewModel.inputText = "Hello"
        viewModel.sendMessage()
        await viewModel.generationTask?.value

        XCTAssertEqual(executor.preloadRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests.map(\.modelId), [profile.modelId])
        XCTAssertEqual(executor.terminateCount, 0)
    }

    @MainActor
    func testSubmitQuickPromptIgnoresEmptyPrompt() {
        let viewModel = makeQuickPromptViewModel()
        let selectedChatId = viewModel.selectedChatId

        let didSubmit = viewModel.submitQuickPrompt(" \n\t ")

        XCTAssertFalse(didSubmit)
        XCTAssertEqual(viewModel.chats.count, 1)
        XCTAssertEqual(viewModel.selectedChatId, selectedChatId)
        XCTAssertEqual(viewModel.selectedChat?.messages.count, 0)
    }

    @MainActor
    func testSubmitQuickPromptBlocksWhileBusy() {
        let viewModel = makeQuickPromptViewModel()
        viewModel.isGenerating = true

        let didSubmit = viewModel.submitQuickPrompt("Explain this")

        XCTAssertFalse(didSubmit)
        XCTAssertEqual(viewModel.chats.count, 1)
        XCTAssertEqual(viewModel.selectedChat?.messages.count, 0)
    }

    @MainActor
    func testSubmitQuickPromptCreatesNewChatAndSendsUserMessage() {
        let viewModel = makeQuickPromptViewModel()
        let originalChatId = viewModel.selectedChatId

        let didSubmit = viewModel.submitQuickPrompt("  Explain local models  ")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(viewModel.chats.count, 2)
        XCTAssertNotEqual(viewModel.selectedChatId, originalChatId)
        XCTAssertEqual(viewModel.selectedChat?.messages.count, 1)
        XCTAssertEqual(viewModel.selectedChat?.messages.first?.content, "Explain local models")
        XCTAssertEqual(viewModel.selectedChat?.messages.first?.isUser, true)
        XCTAssertEqual(viewModel.inputText, "")
        viewModel.cancelGeneration()
    }

    @MainActor
    func testSubmitQuickPromptResetsToAutoAndClearsComposerOnlyState() {
        let viewModel = makeQuickPromptViewModel()
        viewModel.selectedTool = .music
        viewModel.selectedImagePaths = [URL(fileURLWithPath: "/tmp/reference.png")]
        viewModel.musicLyricsText = "[verse]\nOld draft"
        viewModel.musicLyricsApproved = true
        viewModel.isMusicLyricsEditorVisible = true
        viewModel.musicVocalMode = .vocals

        let didSubmit = viewModel.submitQuickPrompt("Generate a product image")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(viewModel.selectedTool, .auto)
        XCTAssertEqual(viewModel.selectedImagePaths, [])
        XCTAssertEqual(viewModel.musicLyricsText, "")
        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertFalse(viewModel.isMusicLyricsEditorVisible)
        XCTAssertEqual(viewModel.musicVocalMode, .auto)
        XCTAssertEqual(viewModel.selectedChat?.messages.first?.content, "Generate a product image")
        viewModel.cancelGeneration()
    }

    @MainActor
    func testCancelledLyricsDraftDoesNotClearNewerDraftState() async {
        let executor = SuspendedLyricsDraftExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
        viewModel.selectedTool = .music
        viewModel.inputText = "Write a vocal synthpop song"

        viewModel.draftMusicLyrics()
        let didStartStaleDraft = await waitUntil {
            executor.streamCount == 1 && viewModel.isDraftingMusicLyrics
        }
        XCTAssertTrue(didStartStaleDraft)
        let staleTask = viewModel.lyricsDraftTask

        viewModel.cancelMusicLyricsDraft()
        viewModel.inputText = "Write a fresh vocal synthpop song"
        viewModel.draftMusicLyrics()
        let didStartActiveDraft = await waitUntil {
            executor.streamCount == 2 && viewModel.isDraftingMusicLyrics
        }
        XCTAssertTrue(didStartActiveDraft)
        let activeTask = viewModel.lyricsDraftTask
        XCTAssertNotNil(activeTask)

        executor.finishStream(
            at: 0,
            events: [.complete("[verse]\nStale draft", usage: TokenUsage(promptTokens: 1, completionTokens: 2))]
        )
        await staleTask?.value

        XCTAssertTrue(viewModel.isDraftingMusicLyrics)
        XCTAssertNotNil(viewModel.lyricsDraftTask)
        XCTAssertEqual(viewModel.loadingMessage, "Generating lyrics...")
        XCTAssertEqual(viewModel.musicLyricsText, "")

        executor.finishStream(
            at: 1,
            events: [.complete("[verse]\nFresh draft", usage: TokenUsage(promptTokens: 1, completionTokens: 2))]
        )
        await activeTask?.value

        XCTAssertFalse(viewModel.isDraftingMusicLyrics)
        XCTAssertNil(viewModel.lyricsDraftTask)
        XCTAssertNil(viewModel.lyricsDraftToken)
        XCTAssertEqual(viewModel.musicLyricsText, "[verse]\nFresh draft")
    }

    @MainActor
    func testLyricsDraftStreamEndingWithoutCompletionMarksEngineError() async {
        let executor = SuspendedLyricsDraftExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
        viewModel.selectedTool = .music
        viewModel.inputText = "Write a vocal synthpop song"

        viewModel.draftMusicLyrics()
        let didStartDraft = await waitUntil {
            executor.streamCount == 1 && viewModel.isDraftingMusicLyrics
        }
        XCTAssertTrue(didStartDraft)
        let task = viewModel.lyricsDraftTask

        executor.finishStream(at: 0, events: [])
        await task?.value

        XCTAssertFalse(viewModel.isDraftingMusicLyrics)
        XCTAssertNil(viewModel.lyricsDraftTask)
        XCTAssertNil(viewModel.lyricsDraftToken)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
        XCTAssertEqual(viewModel.musicLyricsText, "")
        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertEqual(
            viewModel.localEngineErrorMessage,
            "The local engine stopped before lyrics finished. Restart to continue."
        )
        XCTAssertEqual(viewModel.localEngineStatus.state, .needsAttention)
        XCTAssertEqual(viewModel.localEngineStatus.primaryAction, .restart)
    }

    @MainActor
    func testLyricsDraftStreamEndingAfterTokensKeepsPartialDraftAndMarksEngineError() async {
        let executor = SuspendedLyricsDraftExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
        viewModel.selectedTool = .music
        viewModel.inputText = "Write a vocal synthpop song"

        viewModel.draftMusicLyrics()
        let didStartDraft = await waitUntil {
            executor.streamCount == 1 && viewModel.isDraftingMusicLyrics
        }
        XCTAssertTrue(didStartDraft)
        let task = viewModel.lyricsDraftTask

        executor.finishStream(
            at: 0,
            events: [
                .token("```lyrics\n[verse]\nA partial line"),
                .token("\n```")
            ]
        )
        await task?.value

        XCTAssertFalse(viewModel.isDraftingMusicLyrics)
        XCTAssertNil(viewModel.lyricsDraftTask)
        XCTAssertNil(viewModel.lyricsDraftToken)
        XCTAssertTrue(viewModel.isMusicLyricsEditorVisible)
        XCTAssertEqual(viewModel.musicLyricsText, "[verse]\nA partial line")
        XCTAssertFalse(viewModel.musicLyricsApproved)
        XCTAssertEqual(
            viewModel.localEngineErrorMessage,
            "The local engine stopped before lyrics finished. Restart to continue."
        )
        XCTAssertEqual(viewModel.localEngineStatus.state, .needsAttention)
        XCTAssertEqual(viewModel.localEngineStatus.primaryAction, .restart)
    }

    @MainActor
    func testForegroundGenerationPreloadsModelBeforeExecute() async {
        let executor = QuickPromptTestExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )

        viewModel.inputText = "Explain local models"
        viewModel.sendMessage()
        await viewModel.generationTask?.value

        XCTAssertEqual(executor.lifecycleEvents, ["preload", "execute"])
        XCTAssertEqual(executor.preloadRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertEqual(executor.preloadRequests.first?.modelId, executor.receivedRequests.first?.modelId)
        XCTAssertEqual(executor.preloadRequests.first?.backend, executor.receivedRequests.first?.backend)
        XCTAssertFalse(viewModel.isModelLoading)
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "Quick response")
    }

    @MainActor
    func testImageSendPreparesAttachmentsAsynchronouslyAndBlocksDuplicateSubmit() async throws {
        let persistence = SuspendedAttachmentPersistenceService()
        let executor = QuickPromptTestExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
        let selectedImageURL = URL(fileURLWithPath: "/tmp/reference-input.png")
        let persistedImageURL = URL(fileURLWithPath: "/tmp/reference-persisted.png")

        viewModel.inputText = "Describe this"
        viewModel.selectedImagePaths = [selectedImageURL]
        viewModel.sendMessage()

        XCTAssertTrue(viewModel.isPreparingMessage)
        XCTAssertTrue(viewModel.isInputDisabled)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertEqual(viewModel.selectedImagePaths, [])

        viewModel.sendMessage()

        let didStartAttachmentPersistence = await waitUntil {
            persistence.persistCallCount == 1
        }
        XCTAssertTrue(didStartAttachmentPersistence)
        XCTAssertEqual(persistence.persistedInputs.first?.urls, [selectedImageURL])

        let preparationTask = viewModel.messagePreparationTask
        persistence.resume(returning: [persistedImageURL])
        await preparationTask?.value
        await viewModel.generationTask?.value

        let messages = try XCTUnwrap(viewModel.selectedChat?.messages)
        XCTAssertEqual(messages.filter(\.isUser).count, 1)
        XCTAssertEqual(messages.first?.imageURLs, [persistedImageURL])
        XCTAssertEqual(executor.receivedRequests.first?.images, [persistedImageURL])
        XCTAssertFalse(viewModel.isPreparingMessage)
        XCTAssertFalse(viewModel.isInputDisabled)
    }

    @MainActor
    func testDirectImageGenerationPreloadIncludesRuntimeOptions() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let imageProfile = try XCTUnwrap(ModelCapabilityProfile.sortedProfiles(for: .image).first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(imageProfile.modelId, for: .image)
        let executor = QuickPromptTestExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio"
        viewModel.sendMessage()
        await viewModel.generationTask?.value

        let parameters = try XCTUnwrap(executor.preloadRequests.first?.parameters)
        let runtimeOptions = try XCTUnwrap(parameters["runtimeOptions"] as? [String: Any])
        let mflux = try XCTUnwrap(runtimeOptions["mflux"] as? [String: Any])
        let executionRuntimeOptions = try XCTUnwrap(
            executor.receivedRequests.first?.parameters?["runtimeOptions"] as? [String: Any]
        )
        let executionMFlux = try XCTUnwrap(executionRuntimeOptions["mflux"] as? [String: Any])
        XCTAssertEqual(mflux["config"] as? String, imageProfile.runtimeOptions?.mflux?.config)
        XCTAssertEqual(executionMFlux["config"] as? String, mflux["config"] as? String)
    }

    @MainActor
    func testDirectImageGenerationAttachesImageOnlyAfterCompletion() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let imageProfile = try XCTUnwrap(ModelCapabilityProfile.sortedProfiles(for: .image).first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(imageProfile.modelId, for: .image)
        let imageURL = URL(fileURLWithPath: "/tmp/mlxtra-generated-success.png")
        let executor = QuickPromptTestExecutor()
        executor.executionEvents = [
            .started,
            .image(imageURL),
            .complete("Generated image.", usage: TokenUsage(promptTokens: 1, completionTokens: 2))
        ]
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio"
        viewModel.sendMessage()
        await viewModel.generationTask?.value

        let assistantMessage = try XCTUnwrap(viewModel.selectedChat?.messages.last)
        XCTAssertEqual(assistantMessage.imageURLs, [imageURL])
        XCTAssertFalse(assistantMessage.isStreaming)
        XCTAssertEqual(assistantMessage.content, "")
    }

    @MainActor
    func testDirectImageGenerationDoesNotKeepImageAfterStreamError() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let imageProfile = try XCTUnwrap(ModelCapabilityProfile.sortedProfiles(for: .image).first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(imageProfile.modelId, for: .image)
        let imageURL = URL(fileURLWithPath: "/tmp/mlxtra-generated-failed.png")
        let executor = QuickPromptTestExecutor()
        executor.executionEvents = [
            .started,
            .image(imageURL),
            .error(ExecutionError.processStopped("image bridge failed"))
        ]
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio"
        viewModel.sendMessage()
        await viewModel.generationTask?.value

        let assistantMessage = try XCTUnwrap(viewModel.selectedChat?.messages.last)
        XCTAssertTrue(assistantMessage.imageURLs.isEmpty)
        XCTAssertFalse(assistantMessage.isStreaming)
        XCTAssertTrue(assistantMessage.content.contains("The local engine stopped before it could finish."))
    }

    @MainActor
    func testRetryPromptRemovesFailedAssistantAndResubmitsOriginalUserMessage() async throws {
        let executor = QuickPromptTestExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
        let userMessage = Message(
            content: "Try again",
            isUser: true,
            timestamp: Date()
        )
        let failedAssistant = Message(
            content: "The local engine stopped before it could finish.\n\nbridge failed",
            isUser: false,
            timestamp: Date()
        )
        let chatID = try XCTUnwrap(viewModel.selectedChatId)
        let chatIndex = try XCTUnwrap(viewModel.chats.firstIndex(where: { $0.id == chatID }))
        viewModel.chats[chatIndex].messages = [userMessage, failedAssistant]

        XCTAssertTrue(viewModel.canRetryPrompt(for: failedAssistant.id))

        viewModel.retryPrompt(for: failedAssistant.id)
        await viewModel.generationTask?.value

        let messages = try XCTUnwrap(viewModel.selectedChat?.messages)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].id, userMessage.id)
        XCTAssertEqual(messages[1].content, "Quick response")
        XCTAssertEqual(executor.receivedRequests.first?.messages.last?.content, "Try again")
    }

    @MainActor
    func testRetryPromptFromLastUnansweredUserMessageStartsGenerationWithoutDuplicateUserBubble() async throws {
        let executor = QuickPromptTestExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
        let userMessage = Message(
            content: "No answer yet",
            isUser: true,
            timestamp: Date()
        )
        let chatID = try XCTUnwrap(viewModel.selectedChatId)
        let chatIndex = try XCTUnwrap(viewModel.chats.firstIndex(where: { $0.id == chatID }))
        viewModel.chats[chatIndex].messages = [userMessage]

        XCTAssertTrue(viewModel.canRetryPrompt(for: userMessage.id))

        viewModel.retryPrompt(for: userMessage.id)
        await viewModel.generationTask?.value

        let messages = try XCTUnwrap(viewModel.selectedChat?.messages)
        XCTAssertEqual(messages.filter(\.isUser).count, 1)
        XCTAssertEqual(messages.first?.id, userMessage.id)
        XCTAssertEqual(messages.last?.content, "Quick response")
    }

    @MainActor
    func testDirectSpeechGenerationAttachesAudioOnlyAfterCompletion() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let speechProfile = try XCTUnwrap(ModelCapabilityProfile.sortedProfiles(for: .audio).first)
        ModelSelectionStore(userDefaults: defaults).setSelectedModelId(speechProfile.modelId, for: .audio)
        let audioURL = URL(fileURLWithPath: "/tmp/mlxtra-generated-speech.wav")
        let executor = QuickPromptTestExecutor()
        executor.executionEvents = [
            .started,
            .audio(audioURL),
            .complete("Generated speech.", usage: TokenUsage(promptTokens: 1, completionTokens: 2))
        ]
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults
        )

        viewModel.selectTool(.tts)
        viewModel.inputText = "Read this aloud"
        viewModel.sendMessage()
        await viewModel.generationTask?.value

        let assistantMessage = try XCTUnwrap(viewModel.selectedChat?.messages.last)
        XCTAssertEqual(assistantMessage.audioURLs, [audioURL])
        XCTAssertFalse(assistantMessage.isStreaming)
        XCTAssertEqual(assistantMessage.content, "")
    }

    @MainActor
    func testGenerationBlocksNextPromptUntilCancelTerminationCompletes() async {
        let executor = QuickPromptTestExecutor()
        executor.terminateDelayNanoseconds = 100_000_000
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )

        viewModel.activeGenerationID = UUID()
        viewModel.generationTask = Task {}
        viewModel.isGenerating = true
        viewModel.cancelGeneration()
        XCTAssertTrue(viewModel.isTerminatingLocalEngine)
        XCTAssertTrue(viewModel.isInputDisabled)

        viewModel.inputText = "Second prompt"
        viewModel.sendMessage()
        XCTAssertNil(viewModel.generationTask)
        XCTAssertEqual(executor.receivedRequests.count, 0)

        await viewModel.engineTerminationTask?.value
        XCTAssertFalse(viewModel.isTerminatingLocalEngine)
        XCTAssertFalse(viewModel.isInputDisabled)

        viewModel.sendMessage()
        await viewModel.generationTask?.value

        XCTAssertEqual(executor.terminateCount, 1)
        XCTAssertEqual(executor.lifecycleEvents, ["preload", "execute"])
        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertTrue(executor.isReady)
        XCTAssertTrue(executor.isModelLoaded)
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "Quick response")
    }

    @MainActor
    func testFreeMemoryThenImmediatePromptWaitsForTerminationBeforePreload() async throws {
        let profile = try XCTUnwrap(testVisionProfiles.first)
        let executor = QuickPromptTestExecutor()
        executor.isReady = true
        executor.isModelLoaded = true
        executor.currentModelId = profile.modelId
        executor.currentModelBackend = profile.backend
        executor.terminateDelayNanoseconds = 100_000_000
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )

        XCTAssertTrue(viewModel.canFreeLocalEngineMemory)

        viewModel.freeLocalEngineMemory()
        XCTAssertNotNil(viewModel.engineTerminationTask)
        XCTAssertTrue(viewModel.isTerminatingLocalEngine)
        XCTAssertTrue(viewModel.isInputDisabled)

        viewModel.inputText = "Second prompt"
        viewModel.sendMessage()
        XCTAssertNil(viewModel.generationTask)
        XCTAssertEqual(executor.receivedRequests.count, 0)

        await viewModel.engineTerminationTask?.value
        XCTAssertFalse(viewModel.isTerminatingLocalEngine)
        XCTAssertFalse(viewModel.isInputDisabled)

        viewModel.sendMessage()
        await viewModel.generationTask?.value

        XCTAssertEqual(executor.terminateCount, 1)
        XCTAssertEqual(executor.lifecycleEvents, ["preload", "execute"])
        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertTrue(executor.isReady)
        XCTAssertTrue(executor.isModelLoaded)
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.content, "Quick response")
    }

    @MainActor
    func testStaleGenerationFinalizerDoesNotClearActiveGeneration() {
        let viewModel = makeQuickPromptViewModel()
        let staleGenerationID = UUID()
        let activeGenerationID = UUID()
        let messageID = UUID()

        viewModel.activeGenerationID = activeGenerationID
        viewModel.generationTask = Task {}
        viewModel.isGenerating = true
        viewModel.isPythonLoading = true
        viewModel.isModelLoading = true
        viewModel.streamingMessageId = messageID
        viewModel.loadingMessage = "Generating..."
        viewModel.modelLoadProgress = ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-4B",
            backend: .vlm,
            phase: .preparing,
            detail: "Preparing runtime"
        )

        viewModel.finishActiveGeneration(isMusicGeneration: false, generationID: staleGenerationID)

        XCTAssertEqual(viewModel.activeGenerationID, activeGenerationID)
        XCTAssertNotNil(viewModel.generationTask)
        XCTAssertTrue(viewModel.isGenerating)
        XCTAssertTrue(viewModel.isPythonLoading)
        XCTAssertTrue(viewModel.isModelLoading)
        XCTAssertEqual(viewModel.streamingMessageId, messageID)
        XCTAssertEqual(viewModel.loadingMessage, "Generating...")
        XCTAssertNotNil(viewModel.modelLoadProgress)

        viewModel.finishActiveGeneration(isMusicGeneration: false, generationID: activeGenerationID)

        XCTAssertNil(viewModel.activeGenerationID)
        XCTAssertNil(viewModel.generationTask)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertFalse(viewModel.isPythonLoading)
        XCTAssertFalse(viewModel.isModelLoading)
        XCTAssertNil(viewModel.streamingMessageId)
        XCTAssertEqual(viewModel.loadingMessage, "")
        XCTAssertNil(viewModel.modelLoadProgress)
    }

    @MainActor
    func testStaleGenerationErrorDoesNotClearActiveGenerationOrReplaceMessage() {
        let viewModel = makeQuickPromptViewModel()
        let staleGenerationID = UUID()
        let activeGenerationID = UUID()
        let messageID = UUID()
        let activeProgress = ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-8B",
            backend: .vlm,
            phase: .loadingWeights,
            detail: "Loading active model"
        )

        guard let chatID = viewModel.selectedChatId,
              let chatIndex = viewModel.chats.firstIndex(where: { $0.id == chatID }) else {
            XCTFail("Expected an initial selected chat")
            return
        }

        viewModel.chats[chatIndex].messages.append(Message(
            id: messageID,
            content: "Active stream",
            isUser: false,
            timestamp: Date(),
            isStreaming: true
        ))
        _ = viewModel.streamingContentStore.begin(messageId: messageID, initialText: "Active stream")
        viewModel.activeGenerationID = activeGenerationID
        viewModel.generationTask = Task {}
        viewModel.isGenerating = true
        viewModel.isPythonLoading = true
        viewModel.isModelLoading = true
        viewModel.streamingMessageId = messageID
        viewModel.loadingMessage = "Generating..."
        viewModel.modelLoadProgress = activeProgress

        viewModel.handleGenerationError(
            ExecutionError.timeout,
            replacingMessageId: messageID,
            generationID: staleGenerationID
        )

        XCTAssertEqual(viewModel.activeGenerationID, activeGenerationID)
        XCTAssertNotNil(viewModel.generationTask)
        XCTAssertTrue(viewModel.isGenerating)
        XCTAssertTrue(viewModel.isPythonLoading)
        XCTAssertTrue(viewModel.isModelLoading)
        XCTAssertEqual(viewModel.streamingMessageId, messageID)
        XCTAssertEqual(viewModel.loadingMessage, "Generating...")
        XCTAssertEqual(viewModel.modelLoadProgress, activeProgress)
        XCTAssertNil(viewModel.localEngineErrorMessage)
        XCTAssertEqual(viewModel.chats[chatIndex].messages.last?.content, "Active stream")
        XCTAssertEqual(viewModel.chats[chatIndex].messages.last?.isStreaming, true)
        XCTAssertEqual(viewModel.streamingContent(for: messageID)?.text, "Active stream")
    }

    @MainActor
    func testMusicStreamErrorClearsActiveMusicDraft() async {
        let viewModel = makeQuickPromptViewModel()
        let generationID = UUID()
        let messageID = UUID()

        guard let chatID = viewModel.selectedChatId,
              let chatIndex = viewModel.chats.firstIndex(where: { $0.id == chatID }) else {
            XCTFail("Expected an initial selected chat")
            return
        }

        viewModel.chats[chatIndex].messages.append(Message(
            id: messageID,
            content: "",
            isUser: false,
            timestamp: Date(),
            isStreaming: true
        ))
        _ = viewModel.streamingContentStore.begin(messageId: messageID)
        viewModel.activeGenerationID = generationID
        viewModel.generationTask = Task {}
        viewModel.isGenerating = true
        viewModel.streamingMessageId = messageID
        viewModel.activeMusicGenerationDraft = MusicGenerationDraft(
            vocalMode: .vocals,
            lyrics: "[verse]\nKeep the draft"
        )

        let stream = AsyncStream<ExecutionEvent> { continuation in
            continuation.yield(.error(ExecutionError.pythonError("music failed")))
            continuation.finish()
        }
        let request = ChatGenerationRequest(
            chatId: chatID,
            prompt: "Create a vocal song",
            images: [],
            tool: .music,
            profilesByModality: [:],
            parametersByModelId: [:],
            selectionDownloadRequirement: nil,
            selectionOperationName: "Music generation"
        )

        await viewModel.processStream(
            stream,
            forMessage: messageID,
            request: request,
            isMusicGeneration: true,
            generationID: generationID
        )

        XCTAssertNil(viewModel.activeMusicGenerationDraft)
        XCTAssertNil(viewModel.activeGenerationID)
        XCTAssertNil(viewModel.generationTask)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.streamingMessageId)
        XCTAssertEqual(
            viewModel.chats[chatIndex].messages.last?.content,
            "The local engine reported an error.\n\nmusic failed"
        )
        XCTAssertEqual(viewModel.chats[chatIndex].messages.last?.isStreaming, false)
    }

    @MainActor
    func testStreamEndingWithoutCompletionClearsGenerationState() async {
        let viewModel = makeQuickPromptViewModel()
        let generationID = UUID()
        let messageID = UUID()

        guard let chatID = viewModel.selectedChatId,
              let chatIndex = viewModel.chats.firstIndex(where: { $0.id == chatID }) else {
            XCTFail("Expected an initial selected chat")
            return
        }

        viewModel.chats[chatIndex].messages.append(Message(
            id: messageID,
            content: "",
            isUser: false,
            timestamp: Date(),
            isStreaming: true
        ))
        _ = viewModel.streamingContentStore.begin(messageId: messageID)
        viewModel.activeGenerationID = generationID
        viewModel.generationTask = Task {}
        viewModel.isGenerating = true
        viewModel.streamingMessageId = messageID

        let stream = AsyncStream<ExecutionEvent> { continuation in
            continuation.finish()
        }
        let request = ChatGenerationRequest(
            chatId: chatID,
            prompt: "Explain silent stream endings",
            images: [],
            tool: .chat,
            profilesByModality: [:],
            parametersByModelId: [:],
            selectionDownloadRequirement: nil,
            selectionOperationName: "Chat"
        )

        await viewModel.processStream(
            stream,
            forMessage: messageID,
            request: request,
            generationID: generationID
        )

        XCTAssertNil(viewModel.activeGenerationID)
        XCTAssertNil(viewModel.generationTask)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.streamingMessageId)
        XCTAssertEqual(
            viewModel.chats[chatIndex].messages.last?.content,
            "The local engine stopped before it could finish.\n\nThe local engine stream ended before reporting completion."
        )
        XCTAssertEqual(viewModel.chats[chatIndex].messages.last?.isStreaming, false)
    }

    @MainActor
    func testStreamEndingAfterTokensPreservesPartialResponseAndMarksEngineError() async {
        let viewModel = makeQuickPromptViewModel()
        let generationID = UUID()
        let messageID = UUID()

        guard let chatID = viewModel.selectedChatId,
              let chatIndex = viewModel.chats.firstIndex(where: { $0.id == chatID }) else {
            XCTFail("Expected an initial selected chat")
            return
        }

        viewModel.chats[chatIndex].messages.append(Message(
            id: messageID,
            content: "",
            isUser: false,
            timestamp: Date(),
            isStreaming: true
        ))
        _ = viewModel.streamingContentStore.begin(messageId: messageID)
        viewModel.activeGenerationID = generationID
        viewModel.generationTask = Task {}
        viewModel.isGenerating = true
        viewModel.streamingMessageId = messageID

        let stream = AsyncStream<ExecutionEvent> { continuation in
            continuation.yield(.started)
            continuation.yield(.token("Partial answer"))
            continuation.yield(.token(" with a pending tail"))
            continuation.finish()
        }
        let request = ChatGenerationRequest(
            chatId: chatID,
            prompt: "Explain partial streams",
            images: [],
            tool: .chat,
            profilesByModality: [:],
            parametersByModelId: [:],
            selectionDownloadRequirement: nil,
            selectionOperationName: "Chat"
        )

        await viewModel.processStream(
            stream,
            forMessage: messageID,
            request: request,
            generationID: generationID
        )

        XCTAssertNil(viewModel.activeGenerationID)
        XCTAssertNil(viewModel.generationTask)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.streamingMessageId)
        XCTAssertEqual(
            viewModel.localEngineErrorMessage,
            "Local engine stopped: The local engine stream ended before reporting completion."
        )
        XCTAssertEqual(
            viewModel.chats[chatIndex].messages.last?.content,
            "Partial answer with a pending tail"
        )
        XCTAssertEqual(viewModel.chats[chatIndex].messages.last?.isStreaming, false)
    }

    @MainActor
    func testStructuredTerminalMediaToolExecutesAtMaxToolDepth() async {
        let viewModel = makeQuickPromptViewModel()
        let generationID = UUID()
        let messageID = UUID()

        guard let chatID = viewModel.selectedChatId,
              let chatIndex = viewModel.chats.firstIndex(where: { $0.id == chatID }) else {
            XCTFail("Expected an initial selected chat")
            return
        }

        viewModel.chats[chatIndex].messages.append(Message(
            id: messageID,
            content: "",
            isUser: false,
            timestamp: Date(),
            isStreaming: true
        ))
        _ = viewModel.streamingContentStore.begin(messageId: messageID)
        viewModel.activeGenerationID = generationID
        viewModel.generationTask = Task {}
        viewModel.isGenerating = true
        viewModel.streamingMessageId = messageID

        let toolCall = ExecutionToolCall(
            id: "music-tool-call",
            function: ExecutionToolCallFunction(
                name: "generate_music",
                arguments: viewModel.jsonArguments([
                    "caption": "upbeat instrumental cue",
                    "instrumental": true,
                    "lyrics": "[Instrumental]"
                ])
            )
        )
        let stream = AsyncStream<ExecutionEvent> { continuation in
            continuation.yield(.toolCalls([toolCall]))
            continuation.finish()
        }
        let request = ChatGenerationRequest(
            chatId: chatID,
            prompt: "upbeat instrumental cue",
            images: [],
            tool: .music,
            profilesByModality: [:],
            parametersByModelId: [:],
            selectionDownloadRequirement: nil,
            selectionOperationName: "Music generation"
        )

        await viewModel.processStream(
            stream,
            forMessage: messageID,
            messages: [ExecutionMessage(role: .user, content: "upbeat instrumental cue")],
            request: request,
            toolDepth: viewModel.maxAutoToolDepth,
            hasTools: true,
            allowedToolNames: ["generate_music"],
            isMusicGeneration: true,
            generationID: generationID
        )

        XCTAssertNil(viewModel.activeGenerationID)
        XCTAssertNil(viewModel.generationTask)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.streamingMessageId)
        XCTAssertEqual(viewModel.chats[chatIndex].messages.last?.content, "Quick media response")
        XCTAssertEqual(viewModel.chats[chatIndex].messages.last?.isStreaming, false)
    }

    @MainActor
    func testRuntimeInitializationFailureClearsLoadingState() async {
        let executor = QuickPromptTestExecutor()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: FailingRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )

        viewModel.inputText = "Explain local models"
        viewModel.sendMessage()
        await viewModel.generationTask?.value

        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertFalse(viewModel.isPythonLoading)
        XCTAssertFalse(viewModel.isModelLoading)
        XCTAssertNil(viewModel.modelLoadProgress)
        XCTAssertEqual(viewModel.loadingMessage, "")
        XCTAssertEqual(executor.lifecycleEvents, [])
        XCTAssertEqual(executor.receivedRequests.count, 0)
        XCTAssertEqual(viewModel.selectedChat?.messages.last?.isUser, false)
        XCTAssertTrue(viewModel.selectedChat?.messages.last?.content.contains("runtime failed") == true)
    }

    @MainActor
    func testStaleRuntimePreparationDoesNotClearActiveLoadingState() async throws {
        let runtimeManager = SuspendedRuntimeManager()
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: runtimeManager,
            toolExecutor: QuickPromptToolExecutionService()
        )
        let staleGenerationID = UUID()
        let activeGenerationID = UUID()
        let staleProgress = ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-4B",
            backend: .vlm,
            phase: .preparing,
            detail: "Stale generation"
        )
        let activeProgress = ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-8B",
            backend: .vlm,
            phase: .preparing,
            detail: "Active generation"
        )

        viewModel.activeGenerationID = staleGenerationID
        let readinessTask = Task { @MainActor in
            try await viewModel.ensureLocalRuntimeReady(
                progress: staleProgress,
                generationID: staleGenerationID
            )
        }
        await runtimeManager.waitForInitializeStarted()

        viewModel.activeGenerationID = activeGenerationID
        viewModel.isPythonLoading = true
        viewModel.modelLoadProgress = activeProgress
        runtimeManager.releaseInitialize()

        let isStillActiveGeneration = try await readinessTask.value

        XCTAssertFalse(isStillActiveGeneration)
        XCTAssertEqual(viewModel.activeGenerationID, activeGenerationID)
        XCTAssertTrue(viewModel.isPythonLoading)
        XCTAssertEqual(viewModel.modelLoadProgress, activeProgress)
    }

    @MainActor
    func testStaleModelLoadCallbacksDoNotOverwriteActiveProgress() {
        let viewModel = makeQuickPromptViewModel()
        let activeProgress = ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-8B",
            backend: .vlm,
            phase: .loadingWeights,
            detail: "Loading active model"
        )
        viewModel.isModelLoading = true
        viewModel.loadingMessage = "Loading active model"
        viewModel.modelLoadProgress = activeProgress

        viewModel.modelLoadingProgress(ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-4B",
            backend: .vlm,
            phase: .warming,
            detail: "Stale progress"
        ))
        viewModel.modelLoadingCompleted(modelId: "mlx-community/Qwen3.5-4B")
        viewModel.modelLoadingFailed(modelId: "mlx-community/Qwen3.5-4B", error: ExecutionError.timeout)

        XCTAssertTrue(viewModel.isModelLoading)
        XCTAssertEqual(viewModel.loadingMessage, "Loading active model")
        XCTAssertEqual(viewModel.modelLoadProgress, activeProgress)

        viewModel.modelLoadingProgress(ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-8B",
            backend: .vlm,
            phase: .warming,
            detail: "Warming active model"
        ))

        XCTAssertEqual(viewModel.loadingMessage, "Warming active model")
        XCTAssertEqual(viewModel.modelLoadProgress?.phase, .warming)

        viewModel.modelLoadingCompleted(modelId: "mlx-community/Qwen3.5-8B")

        XCTAssertFalse(viewModel.isModelLoading)
        XCTAssertEqual(viewModel.loadingMessage, "")
        XCTAssertNil(viewModel.modelLoadProgress)
    }

    @MainActor
    func testStaleDownloadStatusRefreshDoesNotRestorePreviousToolRequirement() async {
        let imageModelIds = Set(ModelCapabilityProfile.sortedProfiles(for: .image).map(\.modelId))
        let downloadedVisionModelIds = Set(ModelCapabilityProfile.sortedProfiles(for: .vision).map(\.modelId))
        let runtimeManager = SuspendedDownloadStatusRuntimeManager(
            downloadedModelIds: downloadedVisionModelIds,
            suspendedModelIds: imageModelIds,
            suspensionsRemaining: 1
        )
        let viewModel = ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: runtimeManager,
            toolExecutor: QuickPromptToolExecutionService()
        )

        viewModel.selectTool(.image)
        await runtimeManager.waitForSuspendedCheck()

        viewModel.selectTool(.chat)
        let didClearPendingRequirement = await waitUntil {
            viewModel.selectedTool == .chat && viewModel.pendingEngineDownloadModel == nil
        }
        XCTAssertTrue(didClearPendingRequirement)

        runtimeManager.releaseSuspendedChecks()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.selectedTool, .chat)
        XCTAssertNil(viewModel.pendingEngineDownloadModel)
    }

    @MainActor
    func testCancelGenerationClearsLoadingProgressState() {
        let viewModel = makeQuickPromptViewModel()
        viewModel.isGenerating = true
        viewModel.isPythonLoading = true
        viewModel.isModelLoading = true
        viewModel.loadingMessage = "Loading model"
        viewModel.modelLoadProgress = ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-4B",
            backend: .vlm,
            phase: .loadingWeights,
            detail: "Loading model weights"
        )

        viewModel.cancelGeneration()

        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertFalse(viewModel.isPythonLoading)
        XCTAssertFalse(viewModel.isModelLoading)
        XCTAssertEqual(viewModel.loadingMessage, "")
        XCTAssertNil(viewModel.modelLoadProgress)
    }

    @MainActor
    func testCancelGenerationIsIdempotentAndDoesNotFlushPersistence() throws {
        let persistence = RecordingChatPersistenceService(chats: [], selectedChatId: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
        persistence.resetRecording()

        let messageID = UUID()
        let chatID = try XCTUnwrap(viewModel.selectedChatId)
        let chatIndex = try XCTUnwrap(viewModel.chats.firstIndex(where: { $0.id == chatID }))

        viewModel.chats[chatIndex].messages.append(Message(
            id: messageID,
            content: "",
            isUser: false,
            timestamp: Date(),
            isStreaming: true
        ))
        _ = viewModel.streamingContentStore.begin(messageId: messageID, initialText: "Partial response")
        viewModel.generationTask = Task {}
        viewModel.isGenerating = true
        viewModel.streamingMessageId = messageID

        viewModel.cancelGeneration()
        viewModel.cancelGeneration()

        let stoppedMessage = try XCTUnwrap(viewModel.selectedChat?.messages.first(where: { $0.id == messageID }))
        XCTAssertEqual(stoppedMessage.content, "Partial response")
        XCTAssertFalse(stoppedMessage.isStreaming)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.generationTask)
        XCTAssertNil(viewModel.streamingMessageId)
        XCTAssertEqual(persistence.scheduledSaveCount, 1)
        XCTAssertEqual(persistence.flushPendingSaveCount, 0)
    }

    @MainActor
    func testStaleDeepResearchSeedDoesNotMutateToolProgress() async {
        let viewModel = makeQuickPromptViewModel()
        let staleGenerationID = UUID()
        let activeGenerationID = UUID()
        let messageID = UUID()
        viewModel.activeGenerationID = activeGenerationID
        viewModel.streamingMessageId = messageID
        viewModel.loadingMessage = "Fresh generation"

        let context = await viewModel.seedDeepResearchContext(
            prompt: "research stale update",
            generationID: staleGenerationID
        )

        XCTAssertTrue(context.isEmpty)
        XCTAssertEqual(viewModel.loadingMessage, "Fresh generation")
        XCTAssertTrue(viewModel.chats.flatMap(\.messages).allSatisfy { $0.toolCalls.isEmpty })
    }

    @MainActor
    func testMusicPromptHelpersRecognizeVocalAndLyricsMarkers() {
        let viewModel = makeViewModel()

        XCTAssertTrue(viewModel.promptSoundsVocal("A sung vocal hook"))
        XCTAssertTrue(viewModel.promptContainsLyrics("lyrics: We keep moving"))
        XCTAssertEqual(viewModel.resolvedMusicVocalMode(for: "No vocals, only piano"), .instrumental)
        XCTAssertEqual(viewModel.resolvedMusicVocalMode(for: "A chorus with lyrics"), .vocals)
        XCTAssertEqual(viewModel.resolvedMusicVocalMode(for: "Soft ambient cue"), .auto)
    }

    @MainActor
    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil))
    }

    @MainActor
    private func makeQuickPromptViewModel() -> ChatViewModel {
        ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: QuickPromptTestExecutor(),
            runtimeManager: QuickPromptRuntimeManager(),
            toolExecutor: QuickPromptToolExecutionService()
        )
    }

    @MainActor
    private func makeLaunchPreloadViewModel(
        defaults: UserDefaults,
        executor: LaunchPreloadTestExecutor,
        runtimeManager: LaunchPreloadRuntimeManager,
        launchModelPreloadPressureCheck: @escaping () -> Bool = { false },
        launchModelPreloadRuntimeCompatibilityCheck: @escaping (ModelCapabilityProfile) -> Bool = { _ in true }
    ) -> ChatViewModel {
        ChatViewModel(
            chatPersistence: RecordingChatPersistenceService(chats: [], selectedChatId: nil),
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: QuickPromptToolExecutionService(),
            userDefaults: defaults,
            launchModelPreloadPressureCheck: launchModelPreloadPressureCheck,
            launchModelPreloadRuntimeCompatibilityCheck: launchModelPreloadRuntimeCompatibilityCheck
        )
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "MLXtraTests.ChatViewModelLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let intervalNanoseconds: UInt64 = 10_000_000
        let attempts = max(1, Int(timeoutNanoseconds / intervalNanoseconds))

        for _ in 0..<attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }

        return condition()
    }

    private var testVisionProfiles: [ModelCapabilityProfile] {
        ModelCapabilityProfile.sortedProfiles(for: .vision)
    }

    private func visionProfile(_ modelId: String) throws -> ModelCapabilityProfile {
        let profile = try XCTUnwrap(ModelCapabilityProfile.embeddedProfile(modelId: modelId))
        XCTAssertEqual(profile.modality, .vision)
        return profile
    }
}

@MainActor
private final class RecordingChatPersistenceService: ChatPersistenceServicing {
    private let initialChats: [Chat]
    private let initialSelectedChatId: UUID?
    private(set) var savedChats: [Chat] = []
    private(set) var savedSelectedChatId: UUID?
    private(set) var scheduledSaveCount = 0
    private(set) var flushPendingSaveCount = 0

    init(chats: [Chat], selectedChatId: UUID?) {
        self.initialChats = chats
        self.initialSelectedChatId = selectedChatId
    }

    func loadChats() -> [Chat] {
        initialChats
    }

    func saveChats(_ chats: [Chat]) {
        savedChats = chats
    }

    func loadSelectedChatId() -> UUID? {
        initialSelectedChatId
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        savedSelectedChatId = selectedChatId
    }

    func scheduleSave(_ chats: [Chat], selectedChatId: UUID?) {
        scheduledSaveCount += 1
        savedChats = chats
        savedSelectedChatId = selectedChatId
    }

    func flushPendingSave() {
        flushPendingSaveCount += 1
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) async -> [URL] {
        urls
    }

    func deleteAttachments(for chatId: UUID) {}

    func resetRecording() {
        savedChats = []
        savedSelectedChatId = nil
        scheduledSaveCount = 0
        flushPendingSaveCount = 0
    }
}

@MainActor
private final class SuspendedAttachmentPersistenceService: ChatPersistenceServicing {
    private(set) var savedChats: [Chat] = []
    private(set) var savedSelectedChatId: UUID?
    private(set) var persistCallCount = 0
    private(set) var persistedInputs: [(urls: [URL], chatId: UUID, messageId: UUID)] = []
    private var continuation: CheckedContinuation<[URL], Never>?

    func loadChats() -> [Chat] {
        []
    }

    func saveChats(_ chats: [Chat]) {
        savedChats = chats
    }

    func loadSelectedChatId() -> UUID? {
        nil
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        savedSelectedChatId = selectedChatId
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) async -> [URL] {
        persistCallCount += 1
        persistedInputs.append((urls, chatId, messageId))
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func deleteAttachments(for chatId: UUID) {}

    func resume(returning urls: [URL]) {
        continuation?.resume(returning: urls)
        continuation = nil
    }
}

@MainActor
private final class QuickPromptTestExecutor: ChatModelExecuting {
    let backend: RuntimeBackend = .vlm
    var isReady = true
    var isModelLoaded = false
    var currentModelId: String?
    var currentModelBackend: RuntimeBackend?
    var terminateDelayNanoseconds: UInt64 = 0
    var executionEvents: [ExecutionEvent] = [
        .started,
        .token("Quick response"),
        .complete("Quick response", usage: TokenUsage(promptTokens: 1, completionTokens: 2))
    ]
    weak var delegate: VLMExecutionDelegate?
    private(set) var lifecycleEvents: [String] = []
    private(set) var preloadRequests: [(modelId: String, backend: RuntimeBackend, parameters: [String: Any]?)] = []
    private(set) var receivedRequests: [ExecutionRequest] = []
    private(set) var terminateCount = 0

    func initialize() async throws {
        isReady = true
    }

    func preload(modelId: String, backend: RuntimeBackend, parameters: [String: Any]? = nil) async throws {
        lifecycleEvents.append("preload")
        preloadRequests.append((modelId, backend, parameters))
        isReady = true
        isModelLoaded = true
        currentModelId = modelId
        currentModelBackend = backend
        delegate?.modelLoadingStarted(modelId: modelId)
        delegate?.modelLoadingCompleted(modelId: modelId)
    }

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        lifecycleEvents.append("execute")
        receivedRequests.append(request)
        isReady = true
        isModelLoaded = true
        currentModelId = request.modelId
        currentModelBackend = request.backend

        return AsyncStream { continuation in
            for event in executionEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func terminate() async {
        terminateCount += 1
        if terminateDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: terminateDelayNanoseconds)
        }
        isReady = false
        isModelLoaded = false
        currentModelId = nil
        currentModelBackend = nil
    }
}

@MainActor
private final class SuspendedLyricsDraftExecutor: ChatModelExecuting {
    let backend: RuntimeBackend = .vlm
    var isReady = true
    var isModelLoaded = true
    var currentModelId: String?
    var currentModelBackend: RuntimeBackend?
    weak var delegate: VLMExecutionDelegate?
    private var continuations: [AsyncStream<ExecutionEvent>.Continuation] = []
    private(set) var receivedRequests: [ExecutionRequest] = []

    var streamCount: Int {
        continuations.count
    }

    func initialize() async throws {
        isReady = true
    }

    func preload(modelId: String, backend: RuntimeBackend, parameters: [String: Any]? = nil) async throws {
        isModelLoaded = true
        currentModelId = modelId
        currentModelBackend = backend
    }

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        receivedRequests.append(request)
        currentModelId = request.modelId
        currentModelBackend = request.backend

        let (stream, continuation) = AsyncStream.makeStream(of: ExecutionEvent.self)
        continuations.append(continuation)
        continuation.yield(.started)
        return stream
    }

    func finishStream(at index: Int, events: [ExecutionEvent]) {
        guard continuations.indices.contains(index) else { return }
        let continuation = continuations[index]
        events.forEach { continuation.yield($0) }
        continuation.finish()
    }

    func terminate() async {
        isReady = false
        isModelLoaded = false
        currentModelId = nil
        currentModelBackend = nil
    }
}

@MainActor
private final class LaunchPreloadTestExecutor: ChatModelExecuting {
    let backend: RuntimeBackend = .vlm
    var isReady = false
    var isModelLoaded = false
    var currentModelId: String?
    var currentModelBackend: RuntimeBackend?
    weak var delegate: VLMExecutionDelegate?
    var preloadDelayNanoseconds: UInt64 = 0
    var holdPreloadUntilReleased = false
    private(set) var preloadRequests: [(modelId: String, backend: RuntimeBackend, parameters: [String: Any]?)] = []
    private(set) var receivedRequests: [ExecutionRequest] = []
    private(set) var terminateCount = 0
    private var preloadReleaseContinuation: CheckedContinuation<Void, Never>?

    func initialize() async throws {
        isReady = true
    }

    func preload(modelId: String, backend: RuntimeBackend, parameters: [String: Any]? = nil) async throws {
        preloadRequests.append((modelId, backend, parameters))
        isReady = true
        if holdPreloadUntilReleased {
            await withCheckedContinuation { continuation in
                preloadReleaseContinuation = continuation
            }
        } else if preloadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: preloadDelayNanoseconds)
        }
        try Task.checkCancellation()
        isModelLoaded = true
        currentModelId = modelId
        currentModelBackend = backend
    }

    func releasePreload() {
        holdPreloadUntilReleased = false
        guard let continuation = preloadReleaseContinuation else { return }
        preloadReleaseContinuation = nil
        continuation.resume()
    }

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        receivedRequests.append(request)
        isReady = true
        isModelLoaded = true
        currentModelId = request.modelId
        currentModelBackend = request.backend

        return AsyncStream<ExecutionEvent> { continuation in
            continuation.yield(.started)
            continuation.yield(.token("Foreground response"))
            continuation.yield(.complete("Foreground response", usage: TokenUsage(promptTokens: 1, completionTokens: 2)))
            continuation.finish()
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
private final class QuickPromptRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready

    func initialize() async throws {
        state = .ready
    }

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool {
        true
    }
}

@MainActor
private final class FailingRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .notInitialized

    func initialize() async throws {
        throw ExecutionError.pythonError("runtime failed")
    }

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool {
        true
    }
}

@MainActor
private final class SuspendedRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .notInitialized
    private(set) var initializeStarted = false
    private var initializeContinuation: CheckedContinuation<Void, Never>?

    func initialize() async throws {
        initializeStarted = true
        await withCheckedContinuation { continuation in
            initializeContinuation = continuation
        }
        state = .ready
    }

    func releaseInitialize() {
        guard let initializeContinuation else { return }
        self.initializeContinuation = nil
        initializeContinuation.resume()
    }

    func waitForInitializeStarted() async {
        while !initializeStarted {
            await Task.yield()
        }
    }

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool {
        true
    }
}

@MainActor
private final class SuspendedDownloadStatusRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready
    let downloadedModelIds: Set<String>
    let suspendedModelIds: Set<String>
    var suspensionsRemaining: Int
    private var checkContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        downloadedModelIds: Set<String>,
        suspendedModelIds: Set<String>,
        suspensionsRemaining: Int
    ) {
        self.downloadedModelIds = downloadedModelIds
        self.suspendedModelIds = suspendedModelIds
        self.suspensionsRemaining = suspensionsRemaining
    }

    func initialize() async throws {}

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool {
        if suspendedModelIds.contains(model.modelId), suspensionsRemaining > 0 {
            suspensionsRemaining -= 1
            await withCheckedContinuation { continuation in
                checkContinuations.append(continuation)
            }
        }

        return downloadedModelIds.contains(model.modelId)
    }

    func waitForSuspendedCheck() async {
        while checkContinuations.isEmpty {
            await Task.yield()
        }
    }

    func releaseSuspendedChecks() {
        let continuations = checkContinuations
        checkContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private final class LaunchPreloadRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .notInitialized
    var downloadedModelIds: Set<String>
    private(set) var initializeCount = 0

    init(downloadedModelIds: Set<String>) {
        self.downloadedModelIds = downloadedModelIds
    }

    func initialize() async throws {
        initializeCount += 1
        state = .ready
    }

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool {
        downloadedModelIds.contains(model.modelId)
    }
}

@MainActor
private final class DefaultSelectionRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready
    let downloadedModelIds: Set<String>

    init(downloadedModelIds: Set<String>) {
        self.downloadedModelIds = downloadedModelIds
    }

    func initialize() async throws {}

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool {
        downloadedModelIds.contains(model.modelId)
    }
}

@MainActor
private final class QuickPromptToolExecutionService: ChatToolExecutionServicing {
    func executeWebSearch(query: String) async -> String {
        "search context"
    }

    func executeMediaTool(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async -> ChatToolExecutionOutcome {
        onUpdate(.progress(plan.loadingStatus))
        return .toolMessage("Quick media response")
    }
}
