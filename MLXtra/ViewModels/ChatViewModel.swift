import SwiftUI
import Combine

#if DEBUG
enum ChatStreamDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXTRA_STREAM_DIAGNOSTICS"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXtra.streamDiagnostics")
    }

    static func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        print("[StreamDiag][ChatVM] \(String(format: "%.6f", now())) \(message)")
    }
}
#endif

@MainActor
class ChatViewModel: ObservableObject {
    static var generationTimeout: TimeInterval = 300.0
    static let launchModelPreloadEnabledKey = "MLXtra.preloadLocalVLMOnLaunch"
    static let defaultLaunchModelPreloadDelayNanoseconds: UInt64 = 2_500_000_000

    nonisolated static func defaultLaunchModelPreloadPressureCheck() -> Bool {
        let thermalState = ProcessInfo.processInfo.thermalState
        return thermalState == .serious || thermalState == .critical
    }

    nonisolated static func defaultLaunchModelPreloadRuntimeCompatibilityCheck(
        _ profile: ModelCapabilityProfile
    ) -> Bool {
        profile.isRuntimeCompatible()
    }

    var cachedRecentChats: [Chat] = []
    var _cachedRecentChatsRevision: UInt = 0
    var chatsSortRevision: UInt = 0
    var sidebarMetadataCache: [UUID: ChatSidebarMetadata] = [:]
    var _sidebarMetadataRevision: UInt = 0

    @Published var chats: [Chat] = [] {
        didSet { chatsSortRevision &+= 1 }
    }
    @Published var selectedChatId: UUID?
    @Published var inputText: String = "" {
        didSet {
            guard inputText != oldValue, selectedTool == .music, !isCommittingComposerInput else { return }
            activeMusicGenerationDraft = nil
            if musicLyricsApproved {
                musicLyricsApproved = false
            }
        }
    }
    @Published var selectedTool: Tool = .auto
    @Published var isToolMenuOpen: Bool = false
    @Published var isModelMenuOpen: Bool = false
    @Published var selectedImagePaths: [URL] = []

    @Published var isPythonLoading: Bool = false
    @Published var isModelLoading: Bool = false
    @Published var isPreloadingLocalModel: Bool = false
    @Published var isLoadingConversationHistory: Bool = false
    @Published var isPreparingMessage: Bool = false
    @Published var isGenerating: Bool = false
    @Published var isTerminatingLocalEngine: Bool = false
    @Published var isDraftingMusicLyrics: Bool = false
    @Published var loadingMessage: String = ""
    @Published var modelLoadProgress: ModelLoadProgress?
    @Published var generationProgress: GenerationProgress?
    @Published var streamingMessageId: UUID?
    @Published var modelDownloadRequest: DownloadableModel?
    @Published var pendingEngineDownloadModel: DownloadableModel?
    @Published var musicIntentState: MusicIntentState = .needsInstrumentalOrVocals
    @Published var musicVocalMode: MusicVocalMode = .auto
    @Published var musicLyricsText: String = "" {
        didSet {
            if musicLyricsText != oldValue {
                musicLyricsApproved = false
            }
        }
    }
    @Published var isMusicLyricsEditorVisible: Bool = false
    @Published var musicLyricsApproved: Bool = false
    @Published var activeEngineModelName: String?
    @Published var activeEngineModelRole: LocalEngineModelRole = .chat
    @Published var freedEngineModelName: String?
    @Published var localEngineErrorMessage: String?
    @Published var modelSelectionRevision = 0
    @Published var modelParameterRevision = 0
    @Published var composerFocusRequest = 0

    let chatPersistence: ChatPersistenceServicing
    let vlmExecutor: ChatModelExecuting
    let runtimeManager: ChatRuntimeManaging
    let toolExecutor: ChatToolExecutionServicing
    let modelSelectionStore: ModelSelectionStore
    let modelParameterStore: ModelParameterStore
    let userDefaults: UserDefaults
    let launchModelPreloadPressureCheck: () -> Bool
    let launchModelPreloadRuntimeCompatibilityCheck: (ModelCapabilityProfile) -> Bool
    let streamingContentStore = StreamingMessageContentStore()
    var generationTask: Task<Void, Never>?
    var messagePreparationTask: Task<Void, Never>?
    var conversationHistoryLoadTask: Task<Void, Never>?
    var activeMessagePreparationID: UUID?
    var activeGenerationID: UUID?
    var engineTerminationTask: Task<Void, Never>?
    var engineTerminationToken: UUID?
    var launchModelPreloadTask: Task<Void, Never>?
    let maxAutoToolDepth = 4
    var pendingDownloadMonitorTask: Task<Void, Never>?
    var downloadStatusRefreshToken: UUID?
    var pendingEngineDownloadReason: PendingEngineDownloadReason?
    var lyricsDraftTask: Task<Void, Never>?
    var lyricsDraftToken: UUID?
    var activeMusicGenerationDraft: MusicGenerationDraft?
    var isCommittingComposerInput = false

    var generatedImagesDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXtra", isDirectory: true)
            .appendingPathComponent("GeneratedImages", isDirectory: true)
    }

    var generatedSpeechDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXtra", isDirectory: true)
            .appendingPathComponent("GeneratedSpeech", isDirectory: true)
    }

    var generatedMusicDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXtra", isDirectory: true)
            .appendingPathComponent("GeneratedMusic", isDirectory: true)
    }

    init(
        chatPersistence: ChatPersistenceServicing? = nil,
        vlmExecutor: ChatModelExecuting? = nil,
        runtimeManager: ChatRuntimeManaging? = nil,
        toolExecutor: ChatToolExecutionServicing? = nil,
        userDefaults: UserDefaults = .standard,
        launchModelPreloadPressureCheck: @escaping () -> Bool = ChatViewModel.defaultLaunchModelPreloadPressureCheck,
        launchModelPreloadRuntimeCompatibilityCheck: @escaping (ModelCapabilityProfile) -> Bool = ChatViewModel.defaultLaunchModelPreloadRuntimeCompatibilityCheck
    ) {
        let resolvedChatPersistence = chatPersistence ?? LocalChatPersistenceService()
        let resolvedRuntimeManager = runtimeManager ?? RuntimeManager()
        let resolvedExecutor = vlmExecutor ?? VLMExecutor()

        self.chatPersistence = resolvedChatPersistence
        self.runtimeManager = resolvedRuntimeManager
        self.vlmExecutor = resolvedExecutor
        self.userDefaults = userDefaults
        self.launchModelPreloadPressureCheck = launchModelPreloadPressureCheck
        self.launchModelPreloadRuntimeCompatibilityCheck = launchModelPreloadRuntimeCompatibilityCheck
        self.modelSelectionStore = ModelSelectionStore(userDefaults: userDefaults)
        self.modelParameterStore = ModelParameterStore(userDefaults: userDefaults)
        self.toolExecutor = toolExecutor ?? DefaultChatToolExecutionService(
            modelExecutor: resolvedExecutor,
            runtimeManager: resolvedRuntimeManager,
            webSearchService: MCPWebSearchService()
        )

        if resolvedChatPersistence.loadsConversationHistoryAsynchronously {
            isLoadingConversationHistory = true
            conversationHistoryLoadTask = Task { @MainActor [weak self] in
                await self?.loadConversationHistoryAsync()
            }
        } else {
            loadConversationHistory()
        }
        self.vlmExecutor.delegate = self
    }

    deinit {
        conversationHistoryLoadTask?.cancel()
        messagePreparationTask?.cancel()
        engineTerminationTask?.cancel()
        launchModelPreloadTask?.cancel()
    }

}
