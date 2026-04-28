import SwiftUI
import Combine

#if DEBUG
private enum ChatStreamDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXHUB_STREAM_DIAGNOSTICS"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXHub.streamDiagnostics")
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

enum MusicIntentState: Equatable {
    case needsInstrumentalOrVocals
    case needsLyrics
    case awaitingLyricsApproval
    case readyToGenerate

    var systemInstruction: String {
        switch self {
        case .needsInstrumentalOrVocals:
            return "Current music intent state: ask whether the user wants instrumental music or vocals with lyrics before calling generate_music."
        case .needsLyrics:
            return "Current music intent state: the user wants vocals, but lyrics are missing. Generate lyrics or ask for lyrics, then wait for approval before calling generate_music."
        case .awaitingLyricsApproval:
            return "Current music intent state: lyrics are drafted but not approved. Ask for explicit approval before calling generate_music."
        case .readyToGenerate:
            return "Current music intent state: enough information is available to call generate_music."
        }
    }

    var blockedToolMessage: String? {
        switch self {
        case .needsInstrumentalOrVocals:
            return "Do not call generate_music yet. Ask the user whether they want instrumental music or vocals with lyrics."
        case .needsLyrics:
            return "Do not call generate_music yet. The user wants vocals, but lyrics are missing. Generate lyrics or ask the user for lyrics, then wait for approval."
        case .awaitingLyricsApproval:
            return "Do not call generate_music yet. You drafted lyrics, but the user has not explicitly approved them. Ask whether the lyrics look good or need changes."
        case .readyToGenerate:
            return nil
        }
    }

    static func forPrompt(_ prompt: String) -> MusicIntentState {
        let normalized = prompt.lowercased()
        if containsAny(normalized, ["instrumental", "no vocals", "without vocals", "beat", "backing track", "background music"]) {
            return .readyToGenerate
        }
        if containsLyricsMarkers(prompt) {
            return .readyToGenerate
        }
        if containsAny(normalized, ["lyrics", "vocal", "vocals", "sing", "sung"]) {
            return .needsLyrics
        }
        if containsApproval(normalized) {
            return .readyToGenerate
        }
        return .needsInstrumentalOrVocals
    }

    static func forToolCall(prompt: String, parameters: [String: Any]) -> MusicIntentState {
        let caption = (parameters["caption"] as? String) ?? prompt
        let lyrics = ((parameters["lyrics"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let instrumental = boolValue(parameters["instrumental"])
        let normalizedPrompt = prompt.lowercased()
        let normalizedCaption = caption.lowercased()

        if instrumental || containsAny(normalizedPrompt + " " + normalizedCaption, ["instrumental", "no vocals", "without vocals", "beat", "backing track", "background music"]) {
            return .readyToGenerate
        }

        if lyrics.isEmpty {
            if containsAny(normalizedPrompt + " " + normalizedCaption, ["lyrics", "vocal", "vocals", "sing", "sung"]) {
                return .needsLyrics
            }
            return .needsInstrumentalOrVocals
        }

        if userProvidedLyrics(prompt: prompt, lyrics: lyrics) || containsApproval(normalizedPrompt) {
            return .readyToGenerate
        }

        return .awaitingLyricsApproval
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            default:
                return false
            }
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func containsLyricsMarkers(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return containsAny(normalized, ["[verse]", "[chorus]", "[bridge]", "lyrics:"])
    }

    private static func containsApproval(_ text: String) -> Bool {
        let normalizedWords = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
        let paddedWords = " \(normalizedWords) "
        let approvalPhrases = [
            "yes",
            "approved",
            "looks good",
            "go ahead",
            "use those lyrics",
            "use the lyrics",
            "use them",
            "that's fine",
            "that works",
            "ok",
            "okay"
        ]
        return approvalPhrases.contains { phrase in
            let normalizedPhrase = phrase
                .split { !$0.isLetter && !$0.isNumber }
                .joined(separator: " ")
            return normalizedWords == normalizedPhrase || paddedWords.contains(" \(normalizedPhrase) ")
        }
    }

    private static func userProvidedLyrics(prompt: String, lyrics: String) -> Bool {
        if containsLyricsMarkers(prompt) {
            return true
        }
        let normalizedPrompt = prompt.lowercased()
        let lyricWords = lyrics
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 3 }
        guard lyricWords.count >= 4 else { return false }
        let matchingWords = lyricWords.filter { normalizedPrompt.contains(String($0)) }
        return matchingWords.count >= min(6, lyricWords.count)
    }
}

enum MusicVocalMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case instrumental = "Instrumental"
    case vocals = "With vocals"

    var id: String { rawValue }
}

enum MusicComposerPrompt: Equatable {
    case chooseVocals
    case needsLyrics
    case reviewLyrics
}

private enum MusicPrimaryAction {
    case chooseVocals
    case writeLyrics
    case useLyrics
    case createSong
}

private struct MusicGenerationDraft {
    let vocalMode: MusicVocalMode
    let lyrics: String?
}

enum ComposerDraftPrimaryAction: Equatable {
    case send
    case chooseMusicVocals
    case generateMusicLyrics
    case useMusicLyrics
    case createSong
}

enum ComposerDraftSlotAction: String, Equatable, Identifiable {
    case attachReference
    case chooseInstrumental
    case chooseVocals
    case showLyricsEditor
    case regenerateLyrics

    var id: String { rawValue }
}

struct ComposerDraftSlotActionItem: Identifiable, Equatable {
    let action: ComposerDraftSlotAction
    let title: String
    let systemImage: String

    var id: ComposerDraftSlotAction { action }
}

struct ComposerDraftSlot: Identifiable, Equatable {
    enum Tone: Equatable {
        case neutral
        case needed
    }

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let tone: Tone
    let actions: [ComposerDraftSlotActionItem]
}

struct ComposerDraft: Equatable {
    let mode: Tool
    let placeholder: String
    let primaryTitle: String?
    let primarySystemImage: String
    let primaryHelp: String
    let primaryAction: ComposerDraftPrimaryAction
    let isPrimaryEnabled: Bool
    let showsMusicControls: Bool
    let slots: [ComposerDraftSlot]
}

@MainActor
protocol ChatPersistenceServicing: AnyObject {
    func loadChats() -> [Chat]
    func saveChats(_ chats: [Chat])
    func loadSelectedChatId() -> UUID?
    func saveSelectedChatId(_ selectedChatId: UUID?)
    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL]
    func deleteAttachments(for chatId: UUID)
}

@MainActor
protocol ChatModelExecuting: ModelExecutor {
    var isModelLoaded: Bool { get }
    var currentModelId: String? { get }
    var currentModelBackend: RuntimeBackend? { get }
    var delegate: VLMExecutionDelegate? { get set }
}

@MainActor
protocol ChatRuntimeManaging: AnyObject {
    var state: RuntimeManager.RuntimeState { get }
    func initialize() async throws
    func estimatedModelSize(modelId: String) -> Double
    func isModelDownloadedOffMain(modelId: String) async -> Bool
}

@MainActor
protocol ChatWebSearching: AnyObject {
    func searchContext(for query: String) async throws -> String?
}

enum ChatGeneratedAssetKind: Equatable {
    case image
    case audio
}

struct ChatMediaToolExecutionPlan {
    let functionName: String
    let toolName: String
    let status: String
    let icon: String
    let details: [ToolCallDetail]
    let model: DownloadableModel
    let request: ExecutionRequest
    let loadingStatus: String
    let operationName: String
    let unavailablePrefix: String
    let noOutputMessage: String
    let completionHint: String
    let attachmentKind: ChatGeneratedAssetKind
}

enum ChatToolExecutionUpdate: Equatable {
    case progress(String)
    case generatedAsset(URL, kind: ChatGeneratedAssetKind)
}

enum ChatToolExecutionOutcome: Equatable {
    case toolMessage(String)
    case downloadRequired(DownloadableModel)
}

private enum PendingEngineDownloadReason {
    case generation
    case preflight
}

@MainActor
protocol ChatToolExecutionServicing: AnyObject {
    func executeWebSearch(query: String) async -> String
    func executeMediaTool(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async -> ChatToolExecutionOutcome
}

@MainActor
final class LocalChatPersistenceService: ChatPersistenceServicing {
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let selectedChatKey: String
    private let storageDirectory: URL

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        storageDirectory: URL? = nil,
        selectedChatKey: String = "MLXHub.selectedChatId"
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.selectedChatKey = selectedChatKey
        self.storageDirectory = storageDirectory ?? (
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
        )
        .appendingPathComponent("MLXHub", isDirectory: true)
    }

    private var conversationsURL: URL {
        storageDirectory.appendingPathComponent("conversations.json")
    }

    private var attachmentsDirectory: URL {
        storageDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }

    func loadChats() -> [Chat] {
        guard fileManager.fileExists(atPath: conversationsURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: conversationsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Chat].self, from: data)
        } catch {
            print("Failed to load conversation history: \(error)")
            return []
        }
    }

    func saveChats(_ chats: [Chat]) {
        do {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(chats)
            try data.write(to: conversationsURL, options: [.atomic])
        } catch {
            print("Failed to save conversation history: \(error)")
        }
    }

    func loadSelectedChatId() -> UUID? {
        guard let storedValue = userDefaults.string(forKey: selectedChatKey) else {
            return nil
        }

        return UUID(uuidString: storedValue)
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        if let selectedChatId {
            userDefaults.set(selectedChatId.uuidString, forKey: selectedChatKey)
        } else {
            userDefaults.removeObject(forKey: selectedChatKey)
        }
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL] {
        guard !urls.isEmpty else { return [] }

        let messageAttachmentsDirectory = attachmentsDirectory
            .appendingPathComponent(chatId.uuidString, isDirectory: true)
            .appendingPathComponent(messageId.uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: messageAttachmentsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to create attachment directory: \(error)")
            return urls
        }

        return urls.enumerated().map { index, sourceURL in
            let destinationURL = messageAttachmentsDirectory
                .appendingPathComponent("\(index)-\(sourceURL.lastPathComponent)")

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return destinationURL
            } catch {
                print("Failed to copy attachment \(sourceURL.path): \(error)")
                return sourceURL
            }
        }
    }

    func deleteAttachments(for chatId: UUID) {
        let chatAttachmentsDirectory = attachmentsDirectory
            .appendingPathComponent(chatId.uuidString, isDirectory: true)

        guard fileManager.fileExists(atPath: chatAttachmentsDirectory.path) else { return }

        do {
            try fileManager.removeItem(at: chatAttachmentsDirectory)
        } catch {
            print("Failed to delete attachments for chat \(chatId): \(error)")
        }
    }
}

@MainActor
final class DefaultChatToolExecutionService: ChatToolExecutionServicing {
    private let modelExecutor: ChatModelExecuting
    private let runtimeManager: ChatRuntimeManaging
    private let webSearchService: ChatWebSearching

    init(
        modelExecutor: ChatModelExecuting,
        runtimeManager: ChatRuntimeManaging,
        webSearchService: ChatWebSearching
    ) {
        self.modelExecutor = modelExecutor
        self.runtimeManager = runtimeManager
        self.webSearchService = webSearchService
    }

    func executeWebSearch(query: String) async -> String {
        do {
            guard let context = try await webSearchService.searchContext(for: query) else {
                return "No results found."
            }

            return context
        } catch {
            return "Web search unavailable: \(error.localizedDescription)"
        }
    }

    func executeMediaTool(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async -> ChatToolExecutionOutcome {
        guard await runtimeManager.isModelDownloadedOffMain(modelId: plan.model.modelId) else {
            return .downloadRequired(plan.model)
        }

        do {
            let stream = try await modelExecutor.execute(request: plan.request)
            var generatedAssetURL: URL?
            var generationSummary = "\(plan.operationName) completed."

            for await event in stream {
                if Task.isCancelled {
                    break
                }

                switch event {
                case .progress(let message):
                    onUpdate(.progress(message))
                case .image(let imageURL) where plan.attachmentKind == .image:
                    generatedAssetURL = imageURL
                    onUpdate(.generatedAsset(imageURL, kind: .image))
                case .audio(let audioURL) where plan.attachmentKind == .audio:
                    generatedAssetURL = audioURL
                    onUpdate(.generatedAsset(audioURL, kind: .audio))
                case .complete(let response, _):
                    if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        generationSummary = response
                    }
                case .error(let error):
                    throw error
                case .started, .token, .toolCalls, .image, .audio:
                    break
                }
            }

            if generatedAssetURL != nil {
                return .toolMessage("\(generationSummary)\n\(plan.completionHint)")
            }

            return .toolMessage(plan.noOutputMessage)
        } catch {
            return .toolMessage("\(plan.unavailablePrefix): \(error.localizedDescription)")
        }
    }
}

extension VLMExecutor: ChatModelExecuting {}

extension RuntimeManager: ChatRuntimeManaging {
    func isModelDownloadedOffMain(modelId: String) async -> Bool {
        let checkpointsPath = checkpointsPath
        return await Task.detached(priority: .utility) {
            RuntimeManager.isModelDownloaded(modelId: modelId, checkpointsPath: checkpointsPath)
        }.value
    }
}

extension MCPWebSearchService: ChatWebSearching {}

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var chats: [Chat] = []
    @Published var selectedChatId: UUID?
    @Published var inputText: String = "" {
        didSet {
            guard inputText != oldValue, selectedTool == .music else { return }
            activeMusicGenerationDraft = nil
            if musicLyricsApproved {
                musicLyricsApproved = false
            }
            refreshMusicDraftGuidance()
        }
    }
    @Published var selectedTool: Tool = .auto
    @Published var selectedModel: AIModel = AIModel.defaultForCurrentHardware
    @Published var isToolMenuOpen: Bool = false
    @Published var isModelMenuOpen: Bool = false
    @Published var selectedImagePaths: [URL] = []

    // MARK: - VLM Integration Properties
    @Published var isPythonLoading: Bool = false
    @Published var isModelLoading: Bool = false
    @Published var isGenerating: Bool = false
    @Published var isDraftingMusicLyrics: Bool = false
    @Published var loadingMessage: String = ""
    @Published var streamingMessageId: UUID?
    @Published private(set) var modelDownloadRequest: DownloadableModel?
    @Published private(set) var pendingEngineDownloadModel: DownloadableModel?
    @Published private(set) var musicIntentState: MusicIntentState = .needsInstrumentalOrVocals
    @Published var musicVocalMode: MusicVocalMode = .auto
    @Published var musicLyricsText: String = "" {
        didSet {
            if musicLyricsText != oldValue {
                musicLyricsApproved = false
                if !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    musicComposerPrompt = .reviewLyrics
                }
            }
        }
    }
    @Published var isMusicLyricsEditorVisible: Bool = false
    @Published private(set) var musicLyricsApproved: Bool = false
    @Published private(set) var musicComposerPrompt: MusicComposerPrompt?
    @Published private(set) var activeEngineModelName: String?
    @Published private(set) var activeEngineModelRole: LocalEngineModelRole = .chat
    @Published private(set) var freedEngineModelName: String?
    @Published private(set) var localEngineErrorMessage: String?
    @Published private var modelSelectionRevision = 0
    @Published private var modelParameterRevision = 0

    // MARK: - Private Properties
    private let chatPersistence: ChatPersistenceServicing
    private let vlmExecutor: ChatModelExecuting
    private let runtimeManager: ChatRuntimeManaging
    private let toolExecutor: ChatToolExecutionServicing
    private let modelSelectionStore: ModelSelectionStore
    private let modelParameterStore: ModelParameterStore
    private var generationTask: Task<Void, Never>?
    private let maxAutoToolDepth = 4
    private var pendingDownloadMonitorTask: Task<Void, Never>?
    private var pendingEngineDownloadReason: PendingEngineDownloadReason?
    private var lyricsDraftTask: Task<Void, Never>?
    private var activeMusicGenerationDraft: MusicGenerationDraft?

    // MARK: - Computed Properties
    var hasSelectedImages: Bool {
        !selectedImagePaths.isEmpty
    }

    var selectedChat: Chat? {
        chats.first { $0.id == selectedChatId }
    }

    var recentChats: [Chat] {
        chats.sorted { $0.timestamp > $1.timestamp }
    }

    var isInputDisabled: Bool {
        isPythonLoading || isModelLoading || isGenerating || isDraftingMusicLyrics
    }

    var hasApprovedMusicLyrics: Bool {
        musicLyricsApproved && !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasMusicDraftPrompt: Bool {
        !musicPromptForCurrentDraft().isEmpty
    }

    private var musicPrimaryAction: MusicPrimaryAction? {
        guard selectedTool == .music else { return nil }
        let prompt = musicPromptForCurrentDraft()
        guard !prompt.isEmpty else { return nil }

        switch resolvedMusicVocalMode(for: prompt) {
        case .instrumental:
            return .createSong
        case .vocals:
            if hasApprovedMusicLyrics || promptContainsLyrics(prompt) {
                return .createSong
            }
            return musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .writeLyrics
                : .useLyrics
        case .auto:
            return .chooseVocals
        }
    }

    var composerDraft: ComposerDraft {
        let promptIsEmpty = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let basePlaceholder: String
        let title: String?
        let icon: String
        let help: String
        let action: ComposerDraftPrimaryAction
        let enabled: Bool
        let showsMusicControls = selectedTool == .music
        let slots: [ComposerDraftSlot]

        switch selectedTool {
        case .auto:
            basePlaceholder = hasSelectedImages ? "Add a note..." : "Ask anything..."
            title = nil
            icon = "arrow.up"
            help = "Send message"
            action = .send
            enabled = !isInputDisabled && (!promptIsEmpty || hasSelectedImages)
            slots = []

        case .chat:
            basePlaceholder = hasSelectedImages ? "Add a note..." : "Ask anything..."
            title = nil
            icon = "arrow.up"
            help = "Send message"
            action = .send
            enabled = !isInputDisabled && (!promptIsEmpty || hasSelectedImages)
            slots = []

        case .image:
            basePlaceholder = "Describe the image you want..."
            title = "Create image"
            icon = "photo"
            help = "Create image"
            action = .send
            enabled = !isInputDisabled && !promptIsEmpty
            slots = imageComposerSlots

        case .tts:
            basePlaceholder = "Enter the text to speak..."
            title = "Create speech"
            icon = "waveform"
            help = "Create speech"
            action = .send
            enabled = !isInputDisabled && !promptIsEmpty
            slots = []

        case .music:
            basePlaceholder = "Describe the song you want..."
            let primaryAction = musicPrimaryAction
            title = composerTitle(for: primaryAction)
            icon = composerSystemImage(for: primaryAction)
            help = composerHelp(for: primaryAction)
            action = composerPrimaryAction(for: primaryAction)
            enabled = musicPrimaryActionIsEnabled(primaryAction) && !promptIsEmpty
            slots = musicComposerSlots

        case .research:
            basePlaceholder = "What should I research on the web?"
            title = "Research"
            icon = "magnifyingglass"
            help = "Research the web"
            action = .send
            enabled = !isInputDisabled && !promptIsEmpty
            slots = [
                ComposerDraftSlot(
                    id: "research-web",
                    title: "Web research",
                    subtitle: "Searches live web sources before answering.",
                    systemImage: "network",
                    tone: .neutral,
                    actions: []
                )
            ]
        }

        return ComposerDraft(
            mode: selectedTool,
            placeholder: basePlaceholder,
            primaryTitle: title,
            primarySystemImage: icon,
            primaryHelp: help,
            primaryAction: action,
            isPrimaryEnabled: enabled,
            showsMusicControls: showsMusicControls,
            slots: slots
        )
    }

    var composerPlaceholder: String {
        composerDraft.placeholder
    }

    var shouldShowMusicComposerControls: Bool {
        composerDraft.showsMusicControls
    }

    var composerPrimaryActionTitle: String? {
        composerDraft.primaryTitle
    }

    var composerPrimaryActionSystemImage: String {
        composerDraft.primarySystemImage
    }

    var composerPrimaryActionHelp: String {
        composerDraft.primaryHelp
    }

    var isComposerPrimaryActionEnabled: Bool {
        composerDraft.isPrimaryEnabled
    }

    private func composerTitle(for musicPrimaryAction: MusicPrimaryAction?) -> String? {
        switch musicPrimaryAction {
        case .chooseVocals:
            return "Next"
        case .writeLyrics:
            return isDraftingMusicLyrics ? "Generating" : "Generate lyrics"
        case .useLyrics:
            return "Use lyrics"
        case .createSong:
            return "Create song"
        case nil:
            return nil
        }
    }

    private func composerSystemImage(for musicPrimaryAction: MusicPrimaryAction?) -> String {
        switch musicPrimaryAction {
        case .chooseVocals:
            return "arrow.right"
        case .writeLyrics:
            return "pencil.and.sparkles"
        case .useLyrics:
            return "checkmark.circle"
        case .createSong:
            return "music.note"
        case nil:
            return "arrow.up"
        }
    }

    private func composerHelp(for musicPrimaryAction: MusicPrimaryAction?) -> String {
        switch musicPrimaryAction {
        case .chooseVocals:
            return "Choose instrumental or vocals"
        case .writeLyrics:
            return "Generate lyrics from this song idea"
        case .useLyrics:
            return "Use these lyrics for the song"
        case .createSong:
            return "Create song"
        case nil:
            return "Send message"
        }
    }

    private func composerPrimaryAction(for musicPrimaryAction: MusicPrimaryAction?) -> ComposerDraftPrimaryAction {
        switch musicPrimaryAction {
        case .chooseVocals:
            return .chooseMusicVocals
        case .writeLyrics:
            return .generateMusicLyrics
        case .useLyrics:
            return .useMusicLyrics
        case .createSong:
            return .createSong
        case nil:
            return .send
        }
    }

    private func musicPrimaryActionIsEnabled(_ musicPrimaryAction: MusicPrimaryAction?) -> Bool {
        guard !isInputDisabled, let musicPrimaryAction else {
            return false
        }
        switch musicPrimaryAction {
        case .writeLyrics:
            return !isDraftingMusicLyrics
        case .useLyrics:
            return !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .chooseVocals, .createSong:
            return true
        }
    }

    private var imageComposerSlots: [ComposerDraftSlot] {
        guard selectedTool == .image else { return [] }

        if hasSelectedImages {
            return [
                ComposerDraftSlot(
                    id: "image-reference-attached",
                    title: selectedImagePaths.count == 1 ? "Reference image attached" : "\(selectedImagePaths.count) reference images attached",
                    subtitle: "The image model will use attached images as visual context.",
                    systemImage: "paperclip",
                    tone: .neutral,
                    actions: []
                )
            ]
        }

        return [
            ComposerDraftSlot(
                id: "image-reference",
                title: "Reference image optional",
                subtitle: "Attach one if you want to guide style or composition.",
                systemImage: "photo.on.rectangle",
                tone: .neutral,
                actions: [
                    ComposerDraftSlotActionItem(
                        action: .attachReference,
                        title: "Attach image",
                        systemImage: "paperclip"
                    )
                ]
            )
        ]
    }

    private var musicComposerSlots: [ComposerDraftSlot] {
        switch musicComposerPrompt {
        case .chooseVocals:
            return [
                ComposerDraftSlot(
                    id: "music-vocals-choice",
                    title: "Should it have vocals?",
                    subtitle: nil,
                    systemImage: "music.note",
                    tone: .needed,
                    actions: [
                        ComposerDraftSlotActionItem(action: .chooseInstrumental, title: "Instrumental", systemImage: "music.note"),
                        ComposerDraftSlotActionItem(action: .chooseVocals, title: "With vocals", systemImage: "waveform")
                    ]
                )
            ]
        case .needsLyrics:
            return [
                ComposerDraftSlot(
                    id: "music-lyrics-needed",
                    title: "Vocals need lyrics",
                    subtitle: nil,
                    systemImage: "text.quote",
                    tone: .needed,
                    actions: [
                        ComposerDraftSlotActionItem(action: .showLyricsEditor, title: "Paste/type", systemImage: "text.quote"),
                        ComposerDraftSlotActionItem(action: .chooseInstrumental, title: "Instrumental", systemImage: "music.note")
                    ]
                )
            ]
        case .reviewLyrics:
            let lyricsAreEmpty = musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !lyricsAreEmpty, !hasApprovedMusicLyrics else { return [] }
            return [
                ComposerDraftSlot(
                    id: "music-lyrics-review",
                    title: "Review lyrics, then use them.",
                    subtitle: nil,
                    systemImage: "checkmark.circle",
                    tone: .needed,
                    actions: [
                        ComposerDraftSlotActionItem(action: .regenerateLyrics, title: "Regenerate", systemImage: "arrow.clockwise")
                    ]
                )
            ]
        case nil:
            return []
        }
    }

    var localEngineStatus: LocalEngineStatus {
        LocalEngineStatus.resolve(
            runtimeState: runtimeManager.state,
            isPythonLoading: isPythonLoading,
            isModelLoading: isModelLoading,
            isGenerating: isGenerating,
            loadingMessage: loadingMessage,
            isExecutorReady: vlmExecutor.isReady,
            isModelLoaded: vlmExecutor.isModelLoaded,
            selectedModelName: activeModelProfile.name,
            activeModelName: loadedEngineModelName ?? activeEngineModelName,
            activeModelRole: loadedEngineModelRole ?? activeEngineModelRole,
            pendingDownloadModelId: pendingEngineDownloadModel?.modelId,
            pendingDownloadModelName: pendingEngineDownloadModel?.name,
            freedModelName: freedEngineModelName,
            lastErrorMessage: localEngineErrorMessage
        )
    }

    var canFreeLocalEngineMemory: Bool {
        !isInputDisabled && localEngineStatus.canFreeMemory
    }

    var activeModelProfile: ModelCapabilityProfile {
        profile(for: selectedTool)
    }

    var availableProfilesForCurrentMode: [ModelCapabilityProfile] {
        ModelCapabilityProfile.sortedProfiles(for: modelModality(for: selectedTool))
    }

    private var generatedImagesDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXHub", isDirectory: true)
            .appendingPathComponent("GeneratedImages", isDirectory: true)
    }

    private var generatedSpeechDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXHub", isDirectory: true)
            .appendingPathComponent("GeneratedSpeech", isDirectory: true)
    }

    private var generatedMusicDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXHub", isDirectory: true)
            .appendingPathComponent("GeneratedMusic", isDirectory: true)
    }

    // MARK: - Initialization
    init(
        chatPersistence: ChatPersistenceServicing? = nil,
        vlmExecutor: ChatModelExecuting? = nil,
        runtimeManager: ChatRuntimeManaging? = nil,
        toolExecutor: ChatToolExecutionServicing? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        let resolvedChatPersistence = chatPersistence ?? LocalChatPersistenceService()
        let resolvedRuntimeManager = runtimeManager ?? RuntimeManager()
        let resolvedExecutor = vlmExecutor ?? VLMExecutor()

        self.chatPersistence = resolvedChatPersistence
        self.runtimeManager = resolvedRuntimeManager
        self.vlmExecutor = resolvedExecutor
        self.modelSelectionStore = ModelSelectionStore(userDefaults: userDefaults)
        self.modelParameterStore = ModelParameterStore(userDefaults: userDefaults)
        self.toolExecutor = toolExecutor ?? DefaultChatToolExecutionService(
            modelExecutor: resolvedExecutor,
            runtimeManager: resolvedRuntimeManager,
            webSearchService: MCPWebSearchService()
        )

        if let storedChatModel = modelSelectionStore.selectedProfile(for: .vision)?.aiModel {
            selectedModel = storedChatModel
        }

        loadConversationHistory()
        self.vlmExecutor.delegate = self
    }

    // MARK: - Persistence
    private func loadConversationHistory() {
        chats = chatPersistence.loadChats().map { chat in
            var restoredChat = chat
            restoredChat.messages = chat.messages.map { message in
                var restoredMessage = message
                restoredMessage.isStreaming = false
                return restoredMessage
            }
            return restoredChat
        }

        selectedChatId = chatPersistence.loadSelectedChatId()

        if selectedChatId == nil || !chats.contains(where: { $0.id == selectedChatId }) {
            selectedChatId = recentChats.first?.id
        }

        if chats.isEmpty {
            let newChat = Chat(
                title: "New chat",
                messages: [],
                timestamp: Date(),
                icon: "message"
            )
            chats = [newChat]
            selectedChatId = newChat.id
            persistConversationHistory()
        }
    }

    private func persistConversationHistory() {
        chatPersistence.saveChats(chats)
        chatPersistence.saveSelectedChatId(selectedChatId)
    }

    // MARK: - Actions
    func createNewChat() {
        cancelGeneration()

        let newChat = Chat(
            title: "New chat",
            messages: [],
            timestamp: Date(),
            icon: "message"
        )
        chats.insert(newChat, at: 0)
        selectedChatId = newChat.id
        inputText = ""
        selectedImagePaths = []
        persistConversationHistory()
    }

    func selectChat(_ chat: Chat) {
        selectedChatId = chat.id
        chatPersistence.saveSelectedChatId(selectedChatId)
    }

    func renameChat(_ chatId: UUID, to title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = chats.firstIndex(where: { $0.id == chatId }) else { return }

        chats[index].title = trimmedTitle.isEmpty ? "New chat" : trimmedTitle
        chats[index].timestamp = Date()
        persistConversationHistory()
    }

    func deleteChat(_ chat: Chat) {
        if selectedChatId == chat.id {
            cancelGeneration()
        }

        chats.removeAll { $0.id == chat.id }
        chatPersistence.deleteAttachments(for: chat.id)

        if selectedChatId == chat.id {
            selectedChatId = recentChats.first?.id
        }

        if chats.isEmpty {
            let newChat = Chat(
                title: "New chat",
                messages: [],
                timestamp: Date(),
                icon: "message"
            )
            chats = [newChat]
            selectedChatId = newChat.id
        }

        persistConversationHistory()
    }

    func sendMessage() {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !selectedImagePaths.isEmpty else { return }

        if selectedTool == .music, !prepareMusicGenerationIfNeeded(prompt: trimmedInput) {
            return
        }

        if selectedChatId == nil || !chats.contains(where: { $0.id == selectedChatId }) {
            createNewChat()
        }

        guard let chatId = selectedChatId else { return }

        let userMessageId = UUID()
        let images = chatPersistence.persistAttachments(
            selectedImagePaths,
            chatId: chatId,
            messageId: userMessageId
        )

        // Build message content
        let messageContent = trimmedInput
        if images.isEmpty && trimmedInput.isEmpty {
            return // Don't send empty messages
        }

        let userMessage = Message(
            id: userMessageId,
            content: messageContent,
            isUser: true,
            timestamp: Date(),
            imageURLs: images
        )

        if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
            chats[index].messages.append(userMessage)
            chats[index].timestamp = Date()
            
            // Update title if this is the first message
            if chats[index].messages.count == 1 {
                chats[index].title = messageContent.isEmpty ? "Image attachment" : String(messageContent.prefix(30))
            }

            persistConversationHistory()
        }

        let messageText = trimmedInput
        inputText = ""
        selectedImagePaths = []

        startGeneration(for: messageText, images: images)
    }

    func performComposerPrimaryAction() {
        let draft = composerDraft
        guard draft.isPrimaryEnabled else { return }

        switch draft.primaryAction {
        case .chooseMusicVocals:
            musicComposerPrompt = .chooseVocals
        case .generateMusicLyrics:
            draftMusicLyrics()
        case .useMusicLyrics:
            approveMusicLyrics()
        case .createSong, .send:
            sendMessage()
        }
    }

    func performComposerSlotAction(_ action: ComposerDraftSlotAction) {
        switch action {
        case .attachReference:
            break
        case .chooseInstrumental:
            selectMusicVocalMode(.instrumental)
        case .chooseVocals:
            selectMusicVocalMode(.vocals)
        case .showLyricsEditor:
            showMusicLyricsEditor()
        case .regenerateLyrics:
            rewriteMusicLyrics()
        }
    }

    private func startGeneration(for messageText: String, images: [URL]) {
        // Start generation
        print("[ChatVM] Starting generation task for: \(messageText.prefix(50))...")
        generationTask = Task {
            await generateResponse(for: messageText, images: images)
        }
    }

    @discardableResult
    private func prepareMusicGenerationIfNeeded(prompt: String) -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return true }
        activeMusicGenerationDraft = nil

        switch resolvedMusicVocalMode(for: trimmedPrompt) {
        case .instrumental:
            musicComposerPrompt = nil
            isMusicLyricsEditorVisible = false
            musicLyricsApproved = false
            activeMusicGenerationDraft = MusicGenerationDraft(vocalMode: .instrumental, lyrics: "[Instrumental]")
            return true

        case .vocals:
            if hasApprovedMusicLyrics || promptContainsLyrics(trimmedPrompt) {
                musicLyricsApproved = true
                musicComposerPrompt = nil
                activeMusicGenerationDraft = currentMusicGenerationDraft(for: trimmedPrompt)
                return true
            }

            isMusicLyricsEditorVisible = !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            musicComposerPrompt = musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .needsLyrics
                : .reviewLyrics
            return false

        case .auto:
            musicComposerPrompt = .chooseVocals
            return false
        }
    }

    func selectMusicVocalMode(_ mode: MusicVocalMode) {
        musicVocalMode = mode
        switch mode {
        case .auto:
            refreshMusicDraftGuidance()
        case .instrumental:
            musicLyricsApproved = false
            isMusicLyricsEditorVisible = false
            musicComposerPrompt = nil
        case .vocals:
            isMusicLyricsEditorVisible = !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            musicComposerPrompt = musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .needsLyrics
                : .reviewLyrics
        }
    }

    func showMusicLyricsEditor() {
        musicVocalMode = .vocals
        isMusicLyricsEditorVisible = true
        musicComposerPrompt = musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .needsLyrics
            : .reviewLyrics
    }

    func approveMusicLyrics() {
        guard !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            musicComposerPrompt = .needsLyrics
            return
        }
        musicVocalMode = .vocals
        musicLyricsApproved = true
        musicComposerPrompt = nil
        isMusicLyricsEditorVisible = false
    }

    func rewriteMusicLyrics() {
        musicLyricsApproved = false
        draftMusicLyrics()
    }

    func draftMusicLyrics() {
        let brief = musicPromptForCurrentDraft()
        guard selectedTool == .music,
              !brief.isEmpty,
              !isInputDisabled,
              !isDraftingMusicLyrics else {
            return
        }

        musicVocalMode = .vocals
        isMusicLyricsEditorVisible = true
        musicLyricsApproved = false
        musicComposerPrompt = .reviewLyrics

        lyricsDraftTask?.cancel()
        lyricsDraftTask = Task { [weak self] in
            guard let self else { return }
            await self.generateMusicLyricsDraft(for: brief)
        }
    }

    private func musicPromptForCurrentDraft() -> String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshMusicDraftGuidance() {
        guard selectedTool == .music else { return }
        let prompt = musicPromptForCurrentDraft()
        guard !prompt.isEmpty else {
            musicComposerPrompt = nil
            return
        }

        switch resolvedMusicVocalMode(for: prompt) {
        case .instrumental:
            musicComposerPrompt = nil
            isMusicLyricsEditorVisible = false
        case .vocals:
            let hasLyrics = !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasApprovedMusicLyrics || promptContainsLyrics(prompt) {
                musicComposerPrompt = nil
            } else {
                musicComposerPrompt = hasLyrics ? .reviewLyrics : .needsLyrics
            }
        case .auto:
            musicComposerPrompt = nil
        }
    }

    func cancelMusicLyricsDraft() {
        lyricsDraftTask?.cancel()
        lyricsDraftTask = nil
        isDraftingMusicLyrics = false
        loadingMessage = ""
    }

    private func currentMusicGenerationDraft(for prompt: String) -> MusicGenerationDraft {
        let mode = resolvedMusicVocalMode(for: prompt)
        switch mode {
        case .instrumental:
            return MusicGenerationDraft(vocalMode: .instrumental, lyrics: "[Instrumental]")
        case .vocals:
            let approvedLyrics = musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
            return MusicGenerationDraft(
                vocalMode: .vocals,
                lyrics: approvedLyrics.isEmpty ? nil : approvedLyrics
            )
        case .auto:
            return MusicGenerationDraft(vocalMode: .auto, lyrics: nil)
        }
    }

    private func resolvedMusicVocalMode(for prompt: String) -> MusicVocalMode {
        if let activeMusicGenerationDraft {
            return activeMusicGenerationDraft.vocalMode
        }

        if musicVocalMode != .auto {
            return musicVocalMode
        }

        if promptSoundsInstrumental(prompt) {
            return .instrumental
        }
        if promptSoundsVocal(prompt) || promptContainsLyrics(prompt) {
            return .vocals
        }
        return .auto
    }

    private func promptSoundsInstrumental(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        return [
            "instrumental",
            "no vocals",
            "without vocals",
            "beat",
            "backing track",
            "background music"
        ].contains { normalized.contains($0) }
    }

    private func promptSoundsVocal(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        return [
            "lyrics",
            "vocal",
            "vocals",
            "sing",
            "sung",
            "song"
        ].contains { normalized.contains($0) }
    }

    private func promptContainsLyrics(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        return ["[verse]", "[chorus]", "[bridge]", "lyrics:"].contains { normalized.contains($0) }
    }

    private func generateMusicLyricsDraft(for brief: String) async {
        isDraftingMusicLyrics = true
        loadingMessage = "Generating lyrics..."

        defer {
            isDraftingMusicLyrics = false
            lyricsDraftTask = nil
            if !isGenerating && !isModelLoading && !isPythonLoading {
                loadingMessage = ""
            }
        }

        do {
            let chatProfile = profile(for: .chat)
            let chatModel = chatProfile.aiModel ?? selectedModel
            guard await requireDownloadedModel(model: chatProfile.downloadableModel, operation: "Lyrics writing") else {
                musicComposerPrompt = .needsLyrics
                return
            }

            setActiveEngineModel(name: chatProfile.name, role: .chat)

            if runtimeManager.state != .ready {
                isPythonLoading = true
                loadingMessage = "Initializing Python runtime..."
                try await runtimeManager.initialize()
                try await vlmExecutor.initialize()
                isPythonLoading = false
            }

            if !vlmExecutor.isReady {
                try await vlmExecutor.initialize()
            }

            loadingMessage = "Generating lyrics..."
            let chatExecutionParameters = modelParameterStore.executionParameters(for: chatProfile)
            let enableThinking = (chatExecutionParameters["enable_thinking"] as? Bool) ?? false
            let chatTemplateKwargs: [String: Any]? = chatProfile.modelId.lowercased().contains("qwen")
                ? ["enable_thinking": enableThinking]
                : nil
            let request = ExecutionRequest(
                backend: .vlm,
                modelId: chatProfile.modelId,
                messages: [
                    ExecutionMessage(
                        role: .system,
                        content: "Write song lyrics only. Use short section labels like [verse] and [chorus]. Do not include explanation, markdown fences, or production notes."
                    ),
                    ExecutionMessage(
                        role: .user,
                        content: "Song idea: \(brief)\n\nWrite concise, singable lyrics for this song."
                    )
                ],
                maxTokens: min((chatExecutionParameters["max_tokens"] as? Int) ?? chatModel.defaultMaxTokens, 900),
                temperature: max((chatExecutionParameters["temperature"] as? Double) ?? 0.8, 0.7),
                topP: chatExecutionParameters["top_p"] as? Double ?? chatModel.topP,
                topK: chatExecutionParameters["top_k"] as? Int ?? chatModel.topK,
                minP: chatExecutionParameters["min_p"] as? Double ?? chatModel.minP,
                repetitionPenalty: chatExecutionParameters["repetition_penalty"] as? Double ?? chatModel.repetitionPenalty,
                chatTemplateKwargs: chatTemplateKwargs,
                tools: nil
            )

            let stream = try await vlmExecutor.execute(request: request)
            var draft = ""
            for await event in stream {
                if Task.isCancelled { return }

                switch event {
                case .token(let token):
                    draft += token
                case .complete(let response, _):
                    draft = response
                case .progress(let message):
                    loadingMessage = message
                case .error(let error):
                    throw error
                case .started, .image, .audio, .toolCalls:
                    break
                }
            }

            let cleanedDraft = cleanLyricsDraft(draft)
            if !cleanedDraft.isEmpty {
                musicLyricsText = cleanedDraft
                musicLyricsApproved = false
                musicComposerPrompt = .reviewLyrics
                isMusicLyricsEditorVisible = true
            } else {
                musicComposerPrompt = .needsLyrics
            }
        } catch {
            if Task.isCancelled { return }
            musicComposerPrompt = .needsLyrics
            localEngineErrorMessage = "Could not generate lyrics. Paste lyrics or try again."
        }
    }

    private func cleanLyricsDraft(_ draft: String) -> String {
        draft
            .replacingOccurrences(of: "```lyrics", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelGeneration() {
        print("[ChatVM] cancelGeneration called")
        generationTask?.cancel()
        generationTask = nil
        cancelMusicLyricsDraft()
        activeMusicGenerationDraft = nil
        
        if let messageId = streamingMessageId {
            markMessageStopped(messageId)
        }

        isGenerating = false
        streamingMessageId = nil
        isModelLoading = false
        loadingMessage = ""

        Task {
            await vlmExecutor.terminate()
        }
    }

    func freeLocalEngineMemory() {
        guard canFreeLocalEngineMemory else { return }

        let freedModelName = loadedEngineModelName ?? activeEngineModelName ?? activeModelProfile.name
        isPythonLoading = false
        isModelLoading = false
        isGenerating = false
        loadingMessage = ""
        localEngineErrorMessage = nil

        Task {
            await vlmExecutor.terminate()
            activeEngineModelName = nil
            activeEngineModelRole = .chat
            self.freedEngineModelName = freedModelName
        }
    }

    func restartLocalEngine() {
        guard !isInputDisabled else { return }

        isPythonLoading = true
        loadingMessage = "Preparing local engine..."
        activeEngineModelName = nil
        activeEngineModelRole = .chat
        freedEngineModelName = nil
        localEngineErrorMessage = nil

        Task {
            await vlmExecutor.terminate()

            do {
                try await runtimeManager.initialize()
                try await vlmExecutor.initialize()
                isPythonLoading = false
                loadingMessage = ""
            } catch {
                isPythonLoading = false
                loadingMessage = ""
                localEngineErrorMessage = "The local engine stopped. Restart to continue."
            }
        }
    }

    func refreshLocalEngineDownloadStatus() {
        let currentPendingModel = pendingEngineDownloadModel
        let selectionRequirement = downloadRequirementForCurrentSelection()

        Task {
            if let currentPendingModel,
               await isModelDownloadedOffMain(modelId: currentPendingModel.modelId),
               self.pendingEngineDownloadModel?.modelId == currentPendingModel.modelId {
                self.clearPendingEngineDownloadModel(matching: currentPendingModel.modelId)
            }

            await refreshSelectedDownloadRequirement(selectionRequirement)
        }
    }

    private func refreshSelectedDownloadRequirement(_ requirement: DownloadableModel?) async {
        guard let requirement else {
            if pendingEngineDownloadReason == .preflight {
                clearPendingEngineDownloadModel()
            }
            return
        }

        if await isModelDownloadedOffMain(modelId: requirement.modelId) {
            if pendingEngineDownloadReason == .preflight {
                clearPendingEngineDownloadModel()
            }
            return
        }

        if pendingEngineDownloadReason == .generation,
           pendingEngineDownloadModel?.modelId != requirement.modelId,
           selectedTool == .auto || selectedTool == .chat || selectedTool == .research {
            return
        }

        if pendingEngineDownloadModel?.modelId != requirement.modelId || pendingEngineDownloadReason != .preflight {
            pendingEngineDownloadModel = requirement
            pendingEngineDownloadReason = .preflight
            startPendingDownloadMonitor(for: requirement)
        }
    }

    private func downloadRequirementForCurrentSelection() -> DownloadableModel? {
        downloadRequirement(for: selectedTool)
    }

    func downloadRequirement(for tool: Tool) -> DownloadableModel? {
        profile(for: tool).downloadableModel
    }

    private func modelModality(for tool: Tool) -> ModelModality {
        switch tool {
        case .auto, .chat, .research:
            return .vision
        case .image:
            return .image
        case .tts:
            return .audio
        case .music:
            return .music
        }
    }

    private func profile(for tool: Tool) -> ModelCapabilityProfile {
        let modality = modelModality(for: tool)
        if let profile = modelSelectionStore.selectedProfile(for: modality) {
            return profile
        }

        return ModelCapabilityProfile.profiles(for: modality).first
            ?? ModelCapabilityProfile.embedded.first!
    }

    func isModelProfileSelected(_ profile: ModelCapabilityProfile) -> Bool {
        self.profile(for: selectedTool).modelId == profile.modelId
    }

    func selectModelProfile(_ profile: ModelCapabilityProfile) {
        modelSelectionStore.setSelectedModelId(profile.modelId, for: profile.modality)
        if let aiModel = profile.aiModel {
            selectedModel = aiModel
        }
        modelSelectionRevision += 1
        isModelMenuOpen = false
        refreshLocalEngineDownloadStatus()
    }

    func parameterValue(for profile: ModelCapabilityProfile, key: String) -> String {
        _ = modelParameterRevision
        return modelParameterStore.values(for: profile)[key]
            ?? profile.parameterDefinition(key: key)?.defaultValue
            ?? ""
    }

    func setParameterValue(_ value: String, for definition: ModelParameterDefinition, profile: ModelCapabilityProfile) {
        let resolvedValue: String
        switch definition.type {
        case .decimal, .integer:
            resolvedValue = definition.clampedString(Double(value) ?? Double(definition.defaultValue) ?? 0)
        case .boolean, .option, .text:
            resolvedValue = value
        }

        modelParameterStore.setValue(resolvedValue, for: definition.key, modelId: profile.modelId)
        modelParameterRevision += 1
    }

    func applyParameterPreset(_ preset: ModelParameterPreset, to profile: ModelCapabilityProfile) {
        modelParameterStore.applyPreset(preset, to: profile)
        modelParameterRevision += 1
    }

    func resetParameters(for profile: ModelCapabilityProfile) {
        modelParameterStore.reset(profile: profile)
        modelParameterRevision += 1
    }

    private func clearPendingEngineDownloadModel() {
        pendingEngineDownloadModel = nil
        pendingEngineDownloadReason = nil
        pendingDownloadMonitorTask?.cancel()
        pendingDownloadMonitorTask = nil
    }

    // MARK: - Private Methods
    private var webSearchTool: [String: Any] {
        PromptConfiguration.toolDefinition(named: "web_search") ?? PromptConfiguration.webSearchTool
    }

    private var imageGenerationTool: [String: Any] {
        PromptConfiguration.toolDefinition(named: "generate_image") ?? PromptConfiguration.imageGenerationTool
    }

    private var speechGenerationTool: [String: Any] {
        PromptConfiguration.toolDefinition(named: "create_speech") ?? PromptConfiguration.speechGenerationTool
    }

    private var musicGenerationTool: [String: Any] {
        PromptConfiguration.toolDefinition(named: "generate_music") ?? PromptConfiguration.musicGenerationTool
    }

    private var shouldIncludeAutoTools: Bool {
        selectedTool == .auto
    }

    private var systemPrompt: String {
        PromptConfiguration.systemPrompt()
    }

    private var deepResearchSystemPrompt: String {
        PromptConfiguration.deepResearchSystemPrompt()
    }

    private var autoTools: [[String: Any]] {
        PromptConfiguration.toolDefinitions()
    }

    private var deepResearchTools: [[String: Any]] {
        [webSearchTool]
    }

    private func availableTools(toolDepth: Int) -> [[String: Any]]? {
        guard toolDepth < maxAutoToolDepth else { return nil }

        if selectedTool == .research {
            return deepResearchTools
        }

        guard shouldIncludeAutoTools else { return nil }
        return autoTools
    }

    private func toolNames(from tools: [[String: Any]]?) -> Set<String> {
        guard let tools else { return [] }
        return Set(tools.compactMap { tool in
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return name
        })
    }

    private func toolAvailabilityInstruction(allowedToolNames: Set<String>) -> String {
        guard !allowedToolNames.isEmpty else {
            return "Available tools in this mode: none. Do not write, simulate, or mention tool calls."
        }

        let names = allowedToolNames.sorted().joined(separator: ", ")
        return "Available tools in this mode: \(names). Use only these tools. Do not call any other tool."
    }

    private func requestDownloadBeforeUse(model: DownloadableModel) {
        modelDownloadRequest = model
        pendingEngineDownloadModel = model
        pendingEngineDownloadReason = .generation
        startPendingDownloadMonitor(for: model)
        loadingMessage = ""
    }

    func clearModelDownloadRequest() {
        modelDownloadRequest = nil
    }

    private func modelDownloadRequiredMessage(for model: DownloadableModel, operation: String) -> String {
        "Model download required: \(operation) needs \(model.name) (\(String(format: "%.1f", model.downloadSizeGB)) GB)."
    }

    private func isModelDownloadedOffMain(modelId: String) async -> Bool {
        await runtimeManager.isModelDownloadedOffMain(modelId: modelId)
    }

    private func requireDownloadedModel(model: DownloadableModel, operation: String) async -> Bool {
        guard !(await isModelDownloadedOffMain(modelId: model.modelId)) else {
            clearPendingEngineDownloadModel(matching: model.modelId)
            return true
        }

        requestDownloadBeforeUse(model: model)
        isGenerating = false
        isModelLoading = false
        streamingMessageId = nil
        generationTask = nil
        return false
    }

    private func operationNameForCurrentSelection() -> String {
        switch selectedTool {
        case .auto, .chat:
            return "Chat"
        case .image:
            return "Image generation"
        case .tts:
            return "Speech generation"
        case .music:
            return "Music generation"
        case .research:
            return "Research"
        }
    }

    private func generateResponse(for prompt: String, images: [URL], toolMessages: [ExecutionMessage]? = nil, toolDepth: Int = 0) async {
        do {
            let isImageGeneration = selectedTool == .image
            let isSpeechGeneration = selectedTool == .tts
            let isMusicGeneration = selectedTool == .music
            let isDeepResearch = selectedTool == .research

            let selectedCapabilityProfile = profile(for: selectedTool)
            let activeChatProfile = profile(for: .chat)
            let activeChatModel = activeChatProfile.aiModel ?? selectedModel
            let executionProfile = (isImageGeneration || isSpeechGeneration) ? selectedCapabilityProfile : activeChatProfile
            let resolvedModelId = executionProfile.modelId
            let activeModelName = executionProfile.name
            let activeBackend: RuntimeBackend = isImageGeneration ? .image : (isSpeechGeneration ? .audio : .vlm)
            let modelWillLoad = !isLoadedEngineModel(modelId: resolvedModelId, backend: activeBackend)
            setActiveEngineModel(
                name: activeModelName,
                role: isImageGeneration ? .image : (isSpeechGeneration ? .speech : .chat)
            )
            let requiredModel = executionProfile.downloadableModel

            if let selectionRequirement = downloadRequirementForCurrentSelection(),
               selectionRequirement.modelId != requiredModel.modelId {
                guard await requireDownloadedModel(
                    model: selectionRequirement,
                    operation: operationNameForCurrentSelection()
                ) else {
                    return
                }
            }

                guard await requireDownloadedModel(model: requiredModel, operation: isImageGeneration ? "Image generation" : (isSpeechGeneration ? "Speech generation" : "Chat")) else {
                return
            }

            if runtimeManager.state != .ready {
                isPythonLoading = true
                loadingMessage = "Initializing Python runtime..."
                try await runtimeManager.initialize()
                try await vlmExecutor.initialize()
                isPythonLoading = false
            }

            if !vlmExecutor.isReady {
                try await vlmExecutor.initialize()
            }

            if modelWillLoad {
                isModelLoading = true
                loadingMessage = "Loading \(activeModelName)..."

                do {
                    try await loadModel(resolvedModelId)
                } catch {
                    isModelLoading = false
                    throw error
                }
                // isModelLoading will be set to false in processStream when .complete or .error is received
            }

            isGenerating = true

            let aiMessage: Message
            let isFollowUp = toolMessages != nil

            if isFollowUp {
                guard let existingId = streamingMessageId,
                      let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
                      let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == existingId }) else {
                    isGenerating = false
                    return
                }
                aiMessage = chats[chatIndex].messages[messageIndex]
                loadingMessage = "Using tool result..."
            } else {
                let initialToolCall: ToolCall?
                if isImageGeneration {
                    initialToolCall = ToolCall(toolName: "\(executionProfile.name) image generation", status: prompt, icon: "photo")
                } else if isSpeechGeneration {
                    initialToolCall = ToolCall(toolName: "\(executionProfile.name) speech generation", status: prompt, icon: "waveform")
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

                if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
        chats[index].messages.append(aiMessage)
            chats[index].timestamp = Date()
            streamingMessageId = aiMessage.id
                }
            }

            let tools: [[String: Any]]? = (isImageGeneration || isSpeechGeneration) ? nil : (isMusicGeneration ? [musicGenerationTool] : availableTools(toolDepth: toolDepth))
            let allowedToolNames = toolNames(from: tools)

            var messages: [ExecutionMessage]
            if let toolMessages {
                messages = toolMessages
            } else {
                messages = []
                var systemContent = isDeepResearch ? deepResearchSystemPrompt : systemPrompt
                systemContent += "\n\n\(toolAvailabilityInstruction(allowedToolNames: allowedToolNames))"

                if isMusicGeneration {
                    musicIntentState = musicIntentStateForCurrentComposer(prompt: prompt)
                    systemContent += "\n\n\(musicIntentState.systemInstruction)"
                    if let composerInstruction = musicComposerInstruction(prompt: prompt) {
                        systemContent += "\n\n\(composerInstruction)"
                    }
                }

                messages.append(ExecutionMessage(role: .system, content: systemContent))

                if let chat = selectedChat {
                    for message in contextMessages(from: chat, excluding: aiMessage.id) {
                        let role: MessageRole = message.isUser ? .user : .assistant
                        messages.append(ExecutionMessage(role: role, content: message.content))
                    }
                }

                if isDeepResearch {
                    let researchContext = await seedDeepResearchContext(prompt: prompt)
                    messages.append(contentsOf: researchContext)
                }
            }

            let chatExecutionParameters = modelParameterStore.executionParameters(for: activeChatProfile)
            let mediaExecutionParameters = isImageGeneration || isSpeechGeneration
                ? modelParameterStore.executionParameters(for: executionProfile)
                : nil
            let enableThinking = (chatExecutionParameters["enable_thinking"] as? Bool) ?? activeChatModel.enableThinking
            let chatTemplateKwargs: [String: Any]? = !isImageGeneration && !isSpeechGeneration && !isMusicGeneration && activeChatProfile.modelId.lowercased().contains("qwen")
                ? ["enable_thinking": enableThinking]
                : nil

            let outputDirectory = isImageGeneration ? generatedImagesDirectory : (isSpeechGeneration ? generatedSpeechDirectory : nil)
            let isDirectMediaGeneration = isImageGeneration || isSpeechGeneration
            let maxTokens = (chatExecutionParameters["max_tokens"] as? Int) ?? activeChatModel.defaultMaxTokens
            let temperature = (chatExecutionParameters["temperature"] as? Double) ?? activeChatModel.temperatureRange.default
            let topP = (chatExecutionParameters["top_p"] as? Double) ?? activeChatModel.topP
            let topK = (chatExecutionParameters["top_k"] as? Int) ?? activeChatModel.topK
            let minP = (chatExecutionParameters["min_p"] as? Double) ?? activeChatModel.minP
            let repetitionPenalty = (chatExecutionParameters["repetition_penalty"] as? Double) ?? activeChatModel.repetitionPenalty

            let request = ExecutionRequest(
                backend: activeBackend,
                modelId: resolvedModelId,
                messages: isDirectMediaGeneration ? [ExecutionMessage(role: .user, content: prompt)] : messages,
                images: images.isEmpty ? nil : images,
                outputDirectory: outputDirectory,
                maxTokens: isDirectMediaGeneration ? 0 : maxTokens,
                temperature: isDirectMediaGeneration ? 1.0 : temperature,
                topP: isDirectMediaGeneration ? nil : topP,
                topK: isDirectMediaGeneration ? nil : topK,
                minP: isDirectMediaGeneration ? nil : minP,
                repetitionPenalty: isDirectMediaGeneration ? nil : repetitionPenalty,
                chatTemplateKwargs: chatTemplateKwargs,
                tools: tools,
                parameters: mediaExecutionParameters
            )

            let stream = try await vlmExecutor.execute(request: request)

            await processStream(
                stream,
                forMessage: aiMessage.id,
                messages: messages,
                images: images,
                prompt: prompt,
                toolDepth: toolDepth,
                hasTools: tools != nil,
                allowedToolNames: allowedToolNames,
                isImageGeneration: isImageGeneration,
                isSpeechGeneration: isSpeechGeneration,
                isMusicGeneration: isMusicGeneration
            )

        } catch {
            if Task.isCancelled {
                return
            }
            handleGenerationError(error)
        }
    }

    private func executeToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], images: [URL], prompt: String) async {
        switch toolCall.function.name {
        case "web_search":
            await executeWebSearchToolCall(toolCall, messages: &messages, prompt: prompt)
        case "generate_image":
            await executeImageGenerationToolCall(toolCall, messages: &messages, images: images, prompt: prompt)
        case "create_speech":
            await executeSpeechGenerationToolCall(toolCall, messages: &messages, prompt: prompt)
        case "generate_music", "create_music":
            await executeMusicGenerationToolCall(toolCall, messages: &messages, prompt: prompt)
        default:
            messages.append(ExecutionMessage(
                role: .tool,
                content: "Unsupported tool: \(toolCall.function.name)",
                toolCallId: toolCall.id,
                name: toolCall.function.name
            ))
        }
    }

    private func seedDeepResearchContext(prompt: String) async -> [ExecutionMessage] {
        let toolCall = ExecutionToolCall(
            id: "deep-research-initial-search",
            function: ExecutionToolCallFunction(
                name: "web_search",
                arguments: jsonArguments(["query": prompt])
            )
        )

        loadingMessage = "Researching..."
        beginToolCallProgress(
            toolName: "Web search",
            status: prompt,
            icon: "magnifyingglass"
        )

        let result = await toolExecutor.executeWebSearch(query: prompt)
        return [
            ExecutionMessage(role: .assistant, toolCalls: [toolCall]),
            ExecutionMessage(
                role: .tool,
                content: result,
                toolCallId: toolCall.id,
                name: "web_search"
            )
        ]
    }

    private func jsonArguments(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    private func defaultMusicParameters(caption: String) -> [String: Any] {
        var parameters = modelParameterStore.executionParameters(for: profile(for: .music))
        parameters.merge([
            "caption": caption,
            "batch_size": 1,
            "audio_format": "wav",
            "thinking": false,
            "bpm": 0,
            "keyscale": "",
            "timesignature": "",
            "vocal_language": "unknown",
            "instrumental": caption.localizedCaseInsensitiveContains("instrumental")
                || caption.localizedCaseInsensitiveContains("beat")
                || caption.localizedCaseInsensitiveContains("background music")
        ]) { _, newValue in newValue }

        return parameters
    }

    private func musicIntentStateForCurrentComposer(prompt: String, parameters: [String: Any]? = nil) -> MusicIntentState {
        let mode = activeMusicGenerationDraft?.vocalMode ?? resolvedMusicVocalMode(for: prompt)
        switch mode {
        case .instrumental:
            return .readyToGenerate
        case .vocals:
            let approvedLyrics = activeMusicGenerationDraft?.lyrics
                ?? musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !approvedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || promptContainsLyrics(prompt) {
                return .readyToGenerate
            }
            return .needsLyrics
        case .auto:
            if let parameters {
                return MusicIntentState.forToolCall(prompt: prompt, parameters: parameters)
            }
            return MusicIntentState.forPrompt(prompt)
        }
    }

    private func musicComposerInstruction(prompt: String) -> String? {
        let mode = activeMusicGenerationDraft?.vocalMode ?? resolvedMusicVocalMode(for: prompt)
        switch mode {
        case .instrumental:
            return "The user selected instrumental music. If calling generate_music, set instrumental to true and lyrics to \"[Instrumental]\"."
        case .vocals:
            let approvedLyrics = activeMusicGenerationDraft?.lyrics
                ?? musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !approvedLyrics.isEmpty else {
                return "The user selected vocals, but lyrics are not approved yet. Ask for lyrics before calling generate_music."
            }
            return """
            The user selected vocals and approved these lyrics. If calling generate_music, set instrumental to false and use these lyrics exactly:
            \(approvedLyrics)
            """
        case .auto:
            return nil
        }
    }

    private func applyMusicComposerOverrides(to parameters: inout [String: Any], prompt: String) {
        let mode = activeMusicGenerationDraft?.vocalMode ?? resolvedMusicVocalMode(for: prompt)
        switch mode {
        case .instrumental:
            parameters["instrumental"] = true
            parameters["lyrics"] = "[Instrumental]"
        case .vocals:
            let approvedLyrics = activeMusicGenerationDraft?.lyrics
                ?? musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !approvedLyrics.isEmpty {
                parameters["instrumental"] = false
                parameters["lyrics"] = approvedLyrics
            }
        case .auto:
            break
        }
    }

    private func executeWebSearchToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        var searchQuery = prompt
        if let decoded = decodeToolArguments(toolCall),
           let query = decoded["query"] as? String {
            searchQuery = query
        }

        loadingMessage = "Searching for \"\(searchQuery)\"..."
        beginToolCallProgress(
            toolName: "Web search",
            status: searchQuery,
            icon: "magnifyingglass"
        )
        let result = await toolExecutor.executeWebSearch(query: searchQuery)
        messages.append(ExecutionMessage(role: .tool, content: result, toolCallId: toolCall.id, name: "web_search"))
    }

    private func executeImageGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], images: [URL], prompt: String) async {
        var imagePrompt = prompt
        if let decoded = decodeToolArguments(toolCall),
           let decodedPrompt = decoded["prompt"] as? String,
           !decodedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            imagePrompt = decodedPrompt
        }

        let imageProfile = profile(for: .image)
        let model = imageProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "generate_image",
                toolName: "\(imageProfile.name) image generation",
                status: imagePrompt,
                icon: "photo",
                details: [],
                model: model,
                request: ExecutionRequest(
                    backend: .image,
                    modelId: imageProfile.modelId,
                    messages: [ExecutionMessage(role: .user, content: imagePrompt)],
                    images: images.isEmpty ? nil : images,
                    outputDirectory: generatedImagesDirectory,
                    maxTokens: 0,
                    temperature: 1.0,
                    parameters: modelParameterStore.executionParameters(for: imageProfile)
                ),
                loadingStatus: "Generating image...",
                operationName: "Image generation",
                unavailablePrefix: "Image generation unavailable",
                noOutputMessage: "Image generation finished without returning an image.",
                completionHint: "The generated image is already displayed in the app UI. In your final response, use text only. Do not include markdown image syntax, image URLs, local file paths, HTML image tags, data URLs, or links to external image services such as Pollinations.",
                attachmentKind: .image
            )
        )
    }

    private func executeSpeechGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        var speechText = prompt
        if let decoded = decodeToolArguments(toolCall),
           let decodedText = decoded["text"] as? String,
           !decodedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speechText = decodedText
        }

        let speechProfile = profile(for: .tts)
        let model = speechProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "create_speech",
                toolName: "\(speechProfile.name) speech generation",
                status: speechText,
                icon: "waveform",
                details: [],
                model: model,
                request: ExecutionRequest(
                    backend: .audio,
                    modelId: speechProfile.modelId,
                    messages: [ExecutionMessage(role: .user, content: speechText)],
                    outputDirectory: generatedSpeechDirectory,
                    maxTokens: 0,
                    temperature: 1.0,
                    parameters: modelParameterStore.executionParameters(for: speechProfile)
                ),
                loadingStatus: "Generating speech...",
                operationName: "Speech generation",
                unavailablePrefix: "Speech generation unavailable",
                noOutputMessage: "Speech generation finished without returning audio.",
                completionHint: "The generated audio is already displayed in the app UI. In your final response, use text only. Do not include local file paths.",
                attachmentKind: .audio
            )
        )
    }

    private func executeMusicGenerationToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], prompt: String) async {
        var parameters = defaultMusicParameters(caption: prompt)
        if let decoded = decodeToolArguments(toolCall) {
            if let caption = decoded["caption"] as? String,
               !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parameters["caption"] = caption
            }
            if let lyrics = decoded["lyrics"] as? String {
                parameters["lyrics"] = lyrics
            }
            if let duration = decoded["duration"] {
                parameters["duration"] = normalizedMusicNumber(duration)
            }
            if let instrumental = decoded["instrumental"] {
                parameters["instrumental"] = normalizedMusicBool(instrumental) ?? instrumental
            }
            if let bpm = decoded["bpm"] {
                parameters["bpm"] = normalizedMusicNumber(bpm)
            }
            if let keyscale = decoded["keyscale"] as? String {
                parameters["keyscale"] = keyscale
            }
            if let timesignature = decoded["timesignature"] as? String {
                parameters["timesignature"] = timesignature
            }
            if let vocalLanguage = decoded["vocal_language"] as? String {
                parameters["vocal_language"] = vocalLanguage
            }
        }
        applyMusicComposerOverrides(to: &parameters, prompt: prompt)

        let musicPrompt = (parameters["caption"] as? String) ?? prompt
        musicIntentState = musicIntentStateForCurrentComposer(prompt: prompt, parameters: parameters)
        if let blockedToolMessage = musicIntentState.blockedToolMessage {
            messages.append(ExecutionMessage(
                role: .tool,
                content: blockedToolMessage,
                toolCallId: toolCall.id,
                name: "generate_music"
            ))
            return
        }

        let musicProfile = profile(for: .music)
        let model = musicProfile.downloadableModel
        await executeMediaToolCall(
            toolCall,
            messages: &messages,
            plan: ChatMediaToolExecutionPlan(
                functionName: "generate_music",
                toolName: "\(musicProfile.name) music generation",
                status: musicPrompt,
                icon: "music.note",
                details: musicToolCallDetails(parameters),
                model: model,
                request: ExecutionRequest(
                    backend: .music,
                    modelId: musicProfile.modelId,
                    messages: [ExecutionMessage(role: .user, content: musicPrompt)],
                    outputDirectory: generatedMusicDirectory,
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
        )
    }

    private func normalizedMusicNumber(_ value: Any) -> Any {
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

    private func normalizedMusicBool(_ value: Any) -> Bool? {
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

    private func musicToolCallDetails(_ parameters: [String: Any]) -> [ToolCallDetail] {
        let userFacingKeys = [
            "caption",
            "lyrics",
            "duration",
            "instrumental"
        ]

        var details: [ToolCallDetail] = []

        for key in userFacingKeys {
            if let value = parameters[key],
               let displayValue = musicParameterDisplayValue(value) {
                details.append(ToolCallDetail(label: musicParameterLabel(key), value: displayValue))
            }
        }

        return details
    }

    private func musicParameterDisplayValue(_ value: Any) -> String? {
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

    private func musicParameterLabel(_ key: String) -> String {
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

    private func loadModel(_ modelId: String) async throws {
        // The executor handles lazy loading, we just need to trigger it
        // by sending a request
    }

    private func processStream(
        _ stream: AsyncStream<ExecutionEvent>,
        forMessage messageId: UUID,
        messages: [ExecutionMessage]? = nil,
        images: [URL]? = nil,
        prompt: String? = nil,
        toolDepth: Int = 0,
        hasTools: Bool = false,
        allowedToolNames: Set<String> = [],
        isImageGeneration: Bool = false,
        isSpeechGeneration: Bool = false,
        isMusicGeneration: Bool = false
    ) async {
        var fullResponse = ""
        var renderedResponse = ""
        var lastRenderTime = Date.distantPast
        let minimumRenderInterval: TimeInterval = 1.0 / 30.0
#if DEBUG
        var tokenIndex = 0
#endif

        func renderStreamingResponse(force: Bool = false, tokenIndex: Int? = nil, tokenReceivedAt: TimeInterval? = nil) {
            guard fullResponse != renderedResponse else { return }

            let now = Date()
            guard force || renderedResponse.isEmpty || now.timeIntervalSince(lastRenderTime) >= minimumRenderInterval else {
                return
            }

            updateStreamingMessage(messageId, content: fullResponse)
            renderedResponse = fullResponse
            lastRenderTime = now

#if DEBUG
            if let tokenIndex, let tokenReceivedAt {
                let updateFinishedAt = ChatStreamDiagnostics.now()
                ChatStreamDiagnostics.log("message.rendered index=\(tokenIndex) responseChars=\(fullResponse.count) elapsedMs=\(String(format: "%.2f", (updateFinishedAt - tokenReceivedAt) * 1000))")
            }
#endif
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

                fullResponse += token
                if hasTools && shouldBufferToolEnabledOutput(fullResponse) {
                    loadingMessage = "Thinking..."
#if DEBUG
                    ChatStreamDiagnostics.log("token.buffered index=\(tokenIndex) responseChars=\(fullResponse.count)")
#endif
                } else {
#if DEBUG
                    renderStreamingResponse(force: renderedResponse.isEmpty, tokenIndex: tokenIndex, tokenReceivedAt: tokenReceivedAt)
#else
                    renderStreamingResponse(force: renderedResponse.isEmpty)
#endif
                }

            case .image(let imageURL):
                appendGeneratedImage(imageURL, toMessage: messageId)

            case .audio(let audioURL):
                appendGeneratedAudio(audioURL, toMessage: messageId)
                
            case .complete(let response, let usage):
#if DEBUG
                ChatStreamDiagnostics.log("stream.complete responseChars=\(response.count)")
#endif
                fullResponse = response
                if hasTools,
                   let plainTextToolCall = plainTextToolCall(from: response, prompt: prompt),
                   var currentMessages = messages,
                   let currentImages = images,
                   let currentPrompt = prompt {
                    guard allowedToolNames.contains(plainTextToolCall.function.name) else {
                        finalizeMessage(
                            messageId,
                            content: "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it.",
                            usage: usage,
                            clearToolCall: false
                        )
                        isGenerating = false
                        isModelLoading = false
                        streamingMessageId = nil
                        generationTask = nil
                        loadingMessage = ""
                        return
                    }

                    updateStreamingMessage(messageId, content: "")
                    currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [plainTextToolCall]))
                    await executeToolCall(plainTextToolCall, messages: &currentMessages, images: currentImages, prompt: currentPrompt)

                    if isTerminalMediaTool(plainTextToolCall.function.name) {
                        if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                           !isModelDownloadRequiredMessage(toolContent),
                           !toolContent.contains("already displayed") {
                            updateStreamingMessage(messageId, content: toolContent)
                        }
                        if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                           isModelDownloadRequiredMessage(toolContent) {
                            removeAssistantMessage(messageId)
                        } else {
                            markMessageStopped(messageId)
                        }
                        isGenerating = false
                        isModelLoading = false
                        if isMusicGeneration {
                            activeMusicGenerationDraft = nil
                        }
                        streamingMessageId = nil
                        generationTask = nil
                        loadingMessage = ""
                        return
                    }

                    await generateResponse(for: currentPrompt, images: currentImages, toolMessages: currentMessages, toolDepth: toolDepth + 1)
                    return
                }

                finalizeMessage(
                    messageId,
                    content: (isImageGeneration || isSpeechGeneration) ? "" : fullResponse,
                    usage: usage,
                    clearToolCall: isImageGeneration || isSpeechGeneration
                )
                if isMusicGeneration {
                    activeMusicGenerationDraft = nil
                }
                isGenerating = false
                streamingMessageId = nil
                generationTask = nil
                loadingMessage = ""
                
            case .toolCalls(let toolCalls):
                guard var currentMessages = messages, let currentImages = images, let currentPrompt = prompt else { break }
                let executableToolCalls = toolCalls.filter { allowedToolNames.contains($0.function.name) }
                guard !executableToolCalls.isEmpty else {
                    finalizeMessage(
                        messageId,
                        content: "That tool is not available in this mode. Switch to Auto or the matching generation mode to use it.",
                        usage: TokenUsage(promptTokens: 0, completionTokens: 0),
                        clearToolCall: false
                    )
                    isGenerating = false
                    isModelLoading = false
                    streamingMessageId = nil
                    generationTask = nil
                    loadingMessage = ""
                    return
                }
                guard toolDepth < maxAutoToolDepth else {
                    // Max tool depth reached, skip recursive tool execution
                    currentMessages.append(ExecutionMessage(role: .assistant, content: "Maximum tool call depth reached. Cannot execute more tool calls."))
                    return
                }
                let hasTerminalMediaTool = executableToolCalls.contains { isTerminalMediaTool($0.function.name) }
                for toolCall in executableToolCalls {
                    currentMessages.append(ExecutionMessage(role: .assistant, toolCalls: [toolCall]))
                    await executeToolCall(toolCall, messages: &currentMessages, images: currentImages, prompt: currentPrompt)
                }
                if hasTerminalMediaTool {
                    if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                       !isModelDownloadRequiredMessage(toolContent),
                       !toolContent.contains("already displayed") {
                        updateStreamingMessage(messageId, content: toolContent)
                    }
                    if let toolContent = currentMessages.last(where: { $0.role == .tool })?.content,
                       isModelDownloadRequiredMessage(toolContent) {
                        removeAssistantMessage(messageId)
                    } else {
                        markMessageStopped(messageId)
                    }
                    isGenerating = false
                    isModelLoading = false
                    if isMusicGeneration {
                        activeMusicGenerationDraft = nil
                    }
                    streamingMessageId = nil
                    generationTask = nil
                    loadingMessage = ""
                    return
                }
                await generateResponse(for: currentPrompt, images: currentImages, toolMessages: currentMessages, toolDepth: toolDepth + 1)
                return

            case .error(let error):
                if isMusicGeneration {
                    activeMusicGenerationDraft = nil
                }
                handleGenerationError(error, replacingMessageId: messageId)
                isGenerating = false
                streamingMessageId = nil
                generationTask = nil
                
            case .progress(let message):
                loadingMessage = message
            }
        }

        if Task.isCancelled {
            if isMusicGeneration {
                activeMusicGenerationDraft = nil
            }
            isGenerating = false
            streamingMessageId = nil
            generationTask = nil
        }
    }

    private func isModelDownloadRequiredMessage(_ content: String) -> Bool {
        content.hasPrefix("Model download required:")
    }

    private func shouldBufferToolEnabledOutput(_ output: String) -> Bool {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return true }

        let toolPrefixes = ["<tool_call>", "<function=", "<|tool_call|>", "<|tool_call>"]
        return toolPrefixes.contains { prefix in
            prefix.hasPrefix(trimmedOutput) || trimmedOutput.hasPrefix(prefix)
        }
    }

    private func isTerminalMediaTool(_ name: String) -> Bool {
        name == "generate_image" || name == "create_speech" || name == "generate_music" || name == "create_music"
    }

    private func decodeToolArguments(_ toolCall: ExecutionToolCall) -> [String: Any]? {
        guard let data = toolCall.function.arguments.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func plainTextToolCall(from response: String, prompt: String?) -> ExecutionToolCall? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedNames = ["generate_music", "create_music", "generate_image", "create_speech"]

        for name in supportedNames where trimmed.hasPrefix("\(name)(") && trimmed.hasSuffix(")") {
            let openParenIndex = trimmed.index(trimmed.startIndex, offsetBy: name.count)
            let argumentsStart = trimmed.index(after: openParenIndex)
            let argumentsEnd = trimmed.index(before: trimmed.endIndex)
            let rawArguments = String(trimmed[argumentsStart..<argumentsEnd])
            guard var arguments = parsePlainTextToolArguments(rawArguments) else {
                return nil
            }

            let normalizedName = name == "create_music" ? "generate_music" : name
            if normalizedName == "generate_music",
               (arguments["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                arguments["caption"] = musicCaptionFallback(currentPrompt: prompt ?? "")
            }
            return ExecutionToolCall(
                id: "plain-text-\(normalizedName)-\(UUID().uuidString)",
                function: ExecutionToolCallFunction(
                    name: normalizedName,
                    arguments: jsonArguments(arguments)
                )
            )
        }

        return nil
    }

    private func musicCaptionFallback(currentPrompt: String) -> String {
        let trimmedCurrentPrompt = currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isMusicApprovalOnly(trimmedCurrentPrompt), !trimmedCurrentPrompt.isEmpty {
            return trimmedCurrentPrompt
        }

        if let chat = selectedChat {
            for message in chat.messages.reversed() where message.isUser {
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty,
                      content != trimmedCurrentPrompt,
                      !isMusicApprovalOnly(content),
                      containsMusicIntentLanguage(content) else {
                    continue
                }
                return content
            }
        }

        return trimmedCurrentPrompt.isEmpty ? "Create a song with the approved lyrics." : trimmedCurrentPrompt
    }

    private func isMusicApprovalOnly(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let approvalWords = ["yes", "yep", "yeah", "ok", "okay", "approved", "go ahead", "generate", "create it", "looks good"]
        return normalized.count <= 40 && approvalWords.contains { normalized == $0 || normalized.contains($0) }
    }

    private func containsMusicIntentLanguage(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return [
            "music",
            "song",
            "track",
            "beat",
            "loop",
            "soundtrack",
            "instrumental",
            "vocals",
            "lyrics"
        ].contains { normalized.contains($0) }
    }

    private func parsePlainTextToolArguments(_ rawArguments: String) -> [String: Any]? {
        var result: [String: Any] = [:]
        var index = rawArguments.startIndex

        func skipWhitespaceAndCommas() {
            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                if character.isWhitespace || character == "," {
                    index = rawArguments.index(after: index)
                } else {
                    break
                }
            }
        }

        func parseKey() -> String? {
            let start = index
            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                if character.isLetter || character.isNumber || character == "_" {
                    index = rawArguments.index(after: index)
                } else {
                    break
                }
            }
            guard start < index else { return nil }
            return String(rawArguments[start..<index])
        }

        func parseQuotedString(quote: Character) -> String? {
            index = rawArguments.index(after: index)
            var value = ""
            var isEscaping = false

            while index < rawArguments.endIndex {
                let character = rawArguments[index]
                index = rawArguments.index(after: index)

                if isEscaping {
                    switch character {
                    case "n":
                        value.append("\n")
                    case "t":
                        value.append("\t")
                    case "r":
                        value.append("\r")
                    case "\\", "\"", "'":
                        value.append(character)
                    default:
                        value.append(character)
                    }
                    isEscaping = false
                    continue
                }

                if character == "\\" {
                    isEscaping = true
                    continue
                }

                if character == quote {
                    return value
                }

                value.append(character)
            }

            return nil
        }

        func parseBareValue() -> Any {
            let start = index
            while index < rawArguments.endIndex, rawArguments[index] != "," {
                index = rawArguments.index(after: index)
            }
            let value = String(rawArguments[start..<index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch value.lowercased() {
            case "true":
                return true
            case "false":
                return false
            case "none", "null":
                return NSNull()
            default:
                if let intValue = Int(value) {
                    return intValue
                }
                if let doubleValue = Double(value) {
                    return doubleValue
                }
                return value
            }
        }

        while index < rawArguments.endIndex {
            skipWhitespaceAndCommas()
            guard index < rawArguments.endIndex else { break }
            guard let key = parseKey() else { return nil }

            while index < rawArguments.endIndex, rawArguments[index].isWhitespace {
                index = rawArguments.index(after: index)
            }
            guard index < rawArguments.endIndex, rawArguments[index] == "=" else {
                return nil
            }
            index = rawArguments.index(after: index)

            while index < rawArguments.endIndex, rawArguments[index].isWhitespace {
                index = rawArguments.index(after: index)
            }
            guard index < rawArguments.endIndex else { return nil }

            let value: Any
            if rawArguments[index] == "\"" || rawArguments[index] == "'" {
                guard let stringValue = parseQuotedString(quote: rawArguments[index]) else {
                    return nil
                }
                value = stringValue
            } else {
                value = parseBareValue()
            }

            result[key] = value
        }

        return result.isEmpty ? nil : result
    }

    private func beginToolCallProgress(toolName: String, status: String, icon: String, details: [ToolCallDetail] = []) {
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

    private func executeMediaToolCall(_ toolCall: ExecutionToolCall, messages: inout [ExecutionMessage], plan: ChatMediaToolExecutionPlan) async {
        loadingMessage = plan.loadingStatus
        setActiveEngineModel(name: plan.model.name, role: localEngineModelRole(for: plan))
        beginToolCallProgress(
            toolName: plan.toolName,
            status: plan.status,
            icon: plan.icon,
            details: plan.details
        )

        let outcome = await toolExecutor.executeMediaTool(plan: plan) { [weak self] update in
            guard let self else { return }

            switch update {
            case .progress(let message):
                self.loadingMessage = message
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
        case .toolMessage(let content):
            messages.append(ExecutionMessage(
                role: .tool,
                content: content,
                toolCallId: toolCall.id,
                name: plan.functionName
            ))
        }
    }

    private func attachGeneratedAsset(_ url: URL, kind: ChatGeneratedAssetKind, toMessage messageId: UUID) {
        switch kind {
        case .image:
            appendGeneratedImage(url, toMessage: messageId)
        case .audio:
            appendGeneratedAudio(url, toMessage: messageId)
        }
    }

    private func clearMessageContent(_ messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            chats[chatIndex].messages[messageIndex].content = ""
        }
    }

    private func updateStreamingMessage(_ messageId: UUID, content: String) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            // Create new array reference to trigger ObservableObject update
            var updatedMessages = chats[chatIndex].messages
            updatedMessages[messageIndex].content = content
            chats[chatIndex].messages = updatedMessages
        }
    }

    private func appendGeneratedImage(_ imageURL: URL, toMessage messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            var updatedMessages = chats[chatIndex].messages
            if !updatedMessages[messageIndex].imageURLs.contains(imageURL) {
                updatedMessages[messageIndex].imageURLs.append(imageURL)
            }
            chats[chatIndex].messages = updatedMessages
        }
    }

    private func appendGeneratedAudio(_ audioURL: URL, toMessage messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            var updatedMessages = chats[chatIndex].messages
            if !updatedMessages[messageIndex].audioURLs.contains(audioURL) {
                updatedMessages[messageIndex].audioURLs.append(audioURL)
            }
            chats[chatIndex].messages = updatedMessages
        }
    }

    private func appendToolCall(_ toolCall: ToolCall, toMessage messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            var updatedMessages = chats[chatIndex].messages
            updatedMessages[messageIndex].toolCalls.append(toolCall)
            chats[chatIndex].messages = updatedMessages
        }
    }

    private func finalizeMessage(_ messageId: UUID, content: String, usage: TokenUsage, clearToolCall: Bool = false) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            chats[chatIndex].messages[messageIndex].content = content
            chats[chatIndex].messages[messageIndex].isStreaming = false
            if clearToolCall {
                chats[chatIndex].messages[messageIndex].toolCalls = []
            }
            chats[chatIndex].timestamp = Date()
            // Store token usage if needed
            persistConversationHistory()
        }
    }

    private func markMessageStopped(_ messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }) {
            chats[chatIndex].messages[messageIndex].isStreaming = false
            persistConversationHistory()
        }
    }

    private func removeAssistantMessage(_ messageId: UUID) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }),
           !chats[chatIndex].messages[messageIndex].isUser {
            chats[chatIndex].messages.remove(at: messageIndex)
            chats[chatIndex].timestamp = Date()
            persistConversationHistory()
        }
    }

    private func updateMessageToolCall(_ messageId: UUID, status: String) {
        if let chatIndex = chats.firstIndex(where: { $0.id == selectedChatId }),
           let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == messageId }),
           var toolCall = chats[chatIndex].messages[messageIndex].toolCalls.last {
            toolCall.status = status
            chats[chatIndex].messages[messageIndex].toolCalls[chats[chatIndex].messages[messageIndex].toolCalls.count - 1] = toolCall
        }
    }

    private func contextMessages(from chat: Chat, excluding excludedMessageId: UUID) -> [Message] {
        let completedMessages = chat.messages.filter { message in
            message.id != excludedMessageId && !message.isStreaming
        }

        return Array(completedMessages.suffix(20))
    }

    @MainActor
    private func handleGenerationError(_ error: Error, replacingMessageId messageId: UUID? = nil) {
        let errorDesc = String(describing: error)
        if error is CancellationError || errorDesc.contains("CancellationError") || (error as NSError).code == NSUserCancelledError {
            print("[ChatVM] Ignoring cancellation error: \(errorDesc)")
            return
        }

        print("Generation error: \(error)")
        localEngineErrorMessage = localEngineStatusMessage(for: error)

        let errorContent = userFacingErrorMessage(for: error)

        if let index = chats.firstIndex(where: { $0.id == selectedChatId }) {
            if let messageId,
               let messageIndex = chats[index].messages.firstIndex(where: { $0.id == messageId }) {
                chats[index].messages[messageIndex].content = errorContent
                chats[index].messages[messageIndex].isStreaming = false
            } else {
                let errorMessage = Message(
                    content: errorContent,
                    isUser: false,
                    timestamp: Date()
                )
                chats[index].messages.append(errorMessage)
            }
            chats[index].timestamp = Date()
            persistConversationHistory()
        }

        isGenerating = false
        isModelLoading = false
        streamingMessageId = nil
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

    private func setActiveEngineModel(name: String, role: LocalEngineModelRole) {
        activeEngineModelName = name
        activeEngineModelRole = role
        freedEngineModelName = nil
        localEngineErrorMessage = nil
    }

    private func localEngineModelRole(for plan: ChatMediaToolExecutionPlan) -> LocalEngineModelRole {
        switch plan.functionName {
        case "generate_image":
            return .image
        case "create_speech":
            return .speech
        case "generate_music":
            return .music
        default:
            return plan.attachmentKind == .image ? .image : .speech
        }
    }

    private var loadedEngineModelName: String? {
        guard vlmExecutor.isModelLoaded,
              let modelId = vlmExecutor.currentModelId else {
            return nil
        }

        return downloadableModelName(modelId: modelId)
    }

    private var loadedEngineModelRole: LocalEngineModelRole? {
        guard vlmExecutor.isModelLoaded,
              let backend = vlmExecutor.currentModelBackend else {
            return nil
        }

        return localEngineModelRole(for: backend)
    }

    private func isLoadedEngineModel(modelId: String, backend: RuntimeBackend) -> Bool {
        vlmExecutor.isModelLoaded
            && vlmExecutor.currentModelId == modelId
            && vlmExecutor.currentModelBackend == backend
    }

    private func downloadableModelName(modelId: String) -> String {
        DownloadableModel.embeddedModel(modelId: modelId)?.name
            ?? AIModel.allCases.first { $0.modelId == modelId }?.displayName
            ?? modelId
    }

    private func localEngineModelRole(for backend: RuntimeBackend) -> LocalEngineModelRole {
        switch backend {
        case .image:
            return .image
        case .audio:
            return .speech
        case .music:
            return .music
        case .vlm, .llm:
            return .chat
        }
    }

    private func startPendingDownloadMonitor(for model: DownloadableModel) {
        pendingDownloadMonitorTask?.cancel()
        pendingDownloadMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.pendingEngineDownloadModel?.modelId == model.modelId else {
                    return
                }

                if await self.isModelDownloadedOffMain(modelId: model.modelId) {
                    self.clearPendingEngineDownloadModel(matching: model.modelId)
                    return
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func clearPendingEngineDownloadModel(matching modelId: String) {
        guard pendingEngineDownloadModel?.modelId == modelId else { return }
        clearPendingEngineDownloadModel()
    }

    func selectTool(_ tool: Tool) {
        selectedTool = tool
        if tool == .music {
            musicIntentState = .needsInstrumentalOrVocals
            musicVocalMode = .auto
            refreshMusicDraftGuidance()
        } else {
            activeMusicGenerationDraft = nil
            musicComposerPrompt = nil
        }
        isToolMenuOpen = false
        refreshLocalEngineDownloadStatus()
    }

    func selectModel(_ model: AIModel) {
        selectedModel = model
        modelSelectionStore.setSelectedModelId(model.modelId, for: .vision)
        modelSelectionRevision += 1
        isModelMenuOpen = false
        refreshLocalEngineDownloadStatus()
    }

    func toggleToolMenu() {
        isToolMenuOpen.toggle()
        if isToolMenuOpen {
            isModelMenuOpen = false
        }
    }

    func toggleModelMenu() {
        isModelMenuOpen.toggle()
        if isModelMenuOpen {
            isToolMenuOpen = false
        }
    }

    func closeMenus() {
        isToolMenuOpen = false
        isModelMenuOpen = false
    }
}

// MARK: - VLMExecutionDelegate
extension ChatViewModel: VLMExecutionDelegate {
    func modelLoadingStarted(modelId: String) {
        // Already handled in generateResponse
    }

    func modelLoadingCompleted(modelId: String) {
        isModelLoading = false
        loadingMessage = ""
    }

    func modelLoadingFailed(modelId: String, error: Error) {
        isModelLoading = false
        loadingMessage = ""
        // Note: handleGenerationError is called by the main task catch block
    }

    func executionWillRetry(attempt: Int) {
        loadingMessage = "Retrying (attempt \(attempt))..."
    }

    func executionDidFail(error: Error) {
        // Note: handleGenerationError is called by the main task catch block
    }
}
