import AppKit
import SwiftUI

struct SettingsView: View {
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @StateObject private var catalogService = ModelCatalogService.shared
    @StateObject private var runtimeUpdateManager = RuntimeUpdateManager.shared
    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""
    @AppStorage(PromptConfiguration.systemPromptKey) private var systemPrompt = PromptConfiguration.defaultSystemPrompt
    @AppStorage(PromptConfiguration.deepResearchSystemPromptKey) private var deepResearchSystemPrompt = PromptConfiguration.defaultDeepResearchSystemPrompt
    @AppStorage(PromptConfiguration.toolDefinitionsKey) private var toolDefinitionsJSON = PromptConfiguration.defaultToolDefinitionsJSON
    @AppStorage("MLXHub.showExpertSettings") private var showExpertSettings = false
    @State private var searchText = ""
    @State private var selectedFilter: ModelDownloadFilter = .all
    @State private var selectedPane: SettingsPane = .models
    @State private var showDetailedModels = false
    @State private var selectedModelMode: SettingsModelMode = .chat
    @State private var modelSelectionRevision = 0
    @State private var removalCandidate: DownloadableModel?

    private var allModels: [DownloadableModel] {
        ModelCapabilityProfile.visibleProfiles().map(\.downloadableModel)
    }

    private var catalogModels: [DownloadableModel] {
        catalogService.profiles.map(\.downloadableModel)
    }

    private var modelsByModality: [(ModelModality, [DownloadableModel])] {
        ModelModality.allCases.compactMap { modality in
            let models = filteredModels.filter { $0.modality == modality }
            return models.isEmpty ? nil : (modality, models)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                panePicker
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    paneContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    revealPendingModelIfNeeded(proxy)
                }
                .onChange(of: pendingDownloadModelId) { _, _ in
                    revealPendingModelIfNeeded(proxy)
                }
            }
        }
        .frame(width: 900, height: 680)
        .accessibilityIdentifier("settings.window")
        .onAppear {
            clearInitialFocus()
            downloadManager.refreshStatuses()
            clearPendingDownloadIfReady()
        }
        .onChange(of: downloadManager.states) { _, _ in
            clearPendingDownloadIfReady()
        }
        .task {
            await catalogService.refreshFromStableChannel()
            await runtimeUpdateManager.refreshStableChannel(reportFailures: false)
            downloadManager.refreshStatuses()
            clearPendingDownloadIfReady()
        }
        .alert(item: $removalCandidate) { model in
            Alert(
                title: Text("Remove \(model.name)?"),
                message: Text("This frees about \(formatSize(model.downloadSizeGB)). You can download it again later."),
                primaryButton: .destructive(Text("Remove Model")) {
                    Task {
                        await downloadManager.remove(model)
                        downloadManager.refreshStatuses()
                        removalCandidate = nil
                    }
                },
                secondaryButton: .cancel {
                    removalCandidate = nil
                }
            )
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .models:
            modelsPane
        case .advanced:
            promptsPane
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedPane.title)
                    .font(.largeTitle.weight(.semibold))

                Text(selectedPane.subtitle)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if selectedPane == .models {
                HStack(spacing: 10) {
                    ModelHeaderBadge(
                        title: "Ready",
                        value: "\(readyCount)/\(allModels.count)",
                        icon: readyCount == allModels.count ? "checkmark.circle.fill" : "checkmark.circle",
                        tint: .secondary
                    )

                    ModelHeaderBadge(
                        title: "Storage",
                        value: formatSize(downloadedSizeGB),
                        icon: "internaldrive",
                        tint: .secondary
                    )

                    Button {
                        downloadManager.refreshStatuses()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Refresh model status")
                }
                .padding(.top, 2)
            }
        }
    }

    private var panePicker: some View {
        HStack(spacing: 0) {
            Picker(selection: $selectedPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.panePicker")
    }

    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ModelModePicker(selectedMode: $selectedModelMode)

                Spacer()

                modelSearchField
                    .frame(width: 280)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Label("\(selectedModelMode.title) Models", systemImage: selectedModelMode.icon)
                    .font(MLXHubDesignSystem.Typography.sectionTitle)

                Text("\(selectedModeModels.count)")
                    .font(MLXHubDesignSystem.Typography.microMedium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(MLXHubDesignSystem.Surface.panelFill, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(MLXHubDesignSystem.Surface.quietHairline, lineWidth: 1)
                    }

                Spacer()
            }
            .accessibilityIdentifier("settings.modelSectionHeader")

            if selectedModeModels.isEmpty {
                EmptyModelsView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 56)
            } else {
                VStack(spacing: 0) {
                    ForEach(selectedModeModels) { model in
                        ModelManagerRow(
                            model: model,
                            mode: selectedModelMode,
                            state: downloadManager.state(for: model),
                            isDefault: defaultModelId(for: selectedModelMode) == model.modelId,
                            isRecommended: recommendedModelId(for: selectedModelMode) == model.modelId,
                            isPendingDownload: pendingDownloadModelId == model.modelId,
                            runtimeUpdateManager: runtimeUpdateManager,
                            onSetDefault: {
                                setDefaultModel(model, for: selectedModelMode)
                            },
                            onDownload: {
                                downloadManager.download(model)
                            },
                            onPause: {
                                downloadManager.pause(model)
                            },
                            onCancel: {
                                downloadManager.cancel(model)
                            },
                            onRemove: {
                                removalCandidate = model
                            }
                        )
                        .id(model.modelId)

                        if model.id != selectedModeModels.last?.id {
                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.card, style: .continuous)
                        .fill(MLXHubDesignSystem.Surface.contentFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.card, style: .continuous)
                        .stroke(MLXHubDesignSystem.Surface.quietHairline, lineWidth: 1)
                }
                .accessibilityIdentifier("settings.modelList")
            }
        }
    }

    private var modelSearchField: some View {
        NativeSearchField(placeholder: "Search models", text: $searchText)
            .frame(height: 28)
            .accessibilityIdentifier("settings.modelSearch")
    }

    private var promptsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            AdvancedQuickControls(
                systemPrompt: $systemPrompt,
                deepResearchSystemPrompt: $deepResearchSystemPrompt,
                toolDefinitionsJSON: $toolDefinitionsJSON
            )

            DisclosureGroup(isExpanded: $showExpertSettings) {
                VStack(alignment: .leading, spacing: 18) {
                    PromptEditorSection(
                        title: "System Prompt",
                        text: $systemPrompt,
                        defaultValue: PromptConfiguration.defaultSystemPrompt
                    )

                    PromptEditorSection(
                        title: "Research Prompt",
                        text: $deepResearchSystemPrompt,
                        defaultValue: PromptConfiguration.defaultDeepResearchSystemPrompt
                    )

                    ToolDefinitionsEditorSection(
                        text: $toolDefinitionsJSON,
                        defaultValue: PromptConfiguration.defaultToolDefinitionsJSON
                    )
                }
                .padding(.top, 10)
            } label: {
                Label("Expert prompt and tool editing", systemImage: "slider.horizontal.3")
                    .font(.headline)
            }
        }
        .padding(.bottom, 12)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Search models", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .designPanelSurface(cornerRadius: MLXHubDesignSystem.Radius.control)
            .frame(maxWidth: .infinity)

            Picker("Filter", selection: $selectedFilter) {
                ForEach(ModelDownloadFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
    }

    private func modelSection(modality: ModelModality, models: [DownloadableModel]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(modality.rawValue, systemImage: modality.icon)
                    .font(.headline)

                Text("\(models.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(MLXHubDesignSystem.Surface.quietHairline, lineWidth: 1)
                    }

                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(models) { model in
                    ModelDownloadRow(model: model, downloadManager: downloadManager)
                        .id(model.modelId)

                    if model.id != models.last?.id {
                        Divider()
                    }
                }
            }
            .designPanelSurface(cornerRadius: MLXHubDesignSystem.Radius.card)
        }
    }

    private func scrollToPendingModel(_ proxy: ScrollViewProxy) {
        guard !pendingDownloadModelId.isEmpty else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(pendingDownloadModelId, anchor: .center)
            }
        }
    }

    private func revealPendingModelIfNeeded(_ proxy: ScrollViewProxy) {
        guard !pendingDownloadModelId.isEmpty else { return }

        guard let pendingModel else {
            pendingDownloadModelId = ""
            return
        }

        selectedPane = .models
        selectedModelMode = SettingsModelMode(modality: pendingModel.modality)
        scrollToPendingModel(proxy)
    }

    private var filteredModels: [DownloadableModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return allModels.filter { model in
            selectedFilter.includes(downloadManager.state(for: model))
                && (query.isEmpty || model.matchesDownloadSearch(query))
        }
        .sorted { lhs, rhs in
            modelSortKey(lhs) < modelSortKey(rhs)
        }
    }

    private var pendingModel: DownloadableModel? {
        guard !pendingDownloadModelId.isEmpty,
              let model = catalogModels.first(where: { $0.modelId == pendingDownloadModelId })
                ?? DownloadableModel.embeddedModel(modelId: pendingDownloadModelId),
              downloadManager.state(for: model) != .downloaded else {
            return nil
        }
        return model
    }

    private func clearPendingDownloadIfReady() {
        guard !pendingDownloadModelId.isEmpty,
              let model = catalogModels.first(where: { $0.modelId == pendingDownloadModelId })
                ?? DownloadableModel.embeddedModel(modelId: pendingDownloadModelId),
              downloadManager.state(for: model) == .downloaded else {
            return
        }
        pendingDownloadModelId = ""
    }

    private func clearInitialFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private var selectedModeModels: [DownloadableModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = selectedModelMode

        let models = allModels.filter { model in
            model.modality == mode.modality
                && (query.isEmpty || model.matchesDownloadSearch(query))
        }

        return ModelSettingsModelSorter.sorted(
            models: models,
            selectedModelId: defaultModelId(for: mode),
            recommendedModelId: recommendedModelId(for: mode),
            state: { downloadManager.state(for: $0) }
        )
    }

    private var readyCount: Int {
        allModels.filter { downloadManager.state(for: $0) == .downloaded }.count
    }

    private var downloadedSizeGB: Double {
        allModels
            .filter { downloadManager.state(for: $0) == .downloaded }
            .reduce(0) { $0 + $1.downloadSizeGB }
    }

    private func defaultModelId(for mode: SettingsModelMode) -> String? {
        _ = modelSelectionRevision
        return ModelSelectionStore().selectedProfile(for: mode.modality)?.modelId
    }

    private func recommendedModelId(for mode: SettingsModelMode) -> String? {
        ModelCapabilityProfile.bestProfile(for: mode.modality)?.modelId
    }

    private func setDefaultModel(_ model: DownloadableModel, for mode: SettingsModelMode) {
        ModelSelectionStore().setSelectedModelId(model.modelId, for: mode.modality)
        modelSelectionRevision += 1
    }

    private var recommendedStarterModel: DownloadableModel {
        bestProfile(for: .vision)?.downloadableModel
            ?? allModels.first!
    }

    private var capabilityItems: [CapabilitySetupItem] {
        let items: [CapabilitySetupItem?] = [
            CapabilitySetupItem(
                title: "Chat",
                subtitle: "Conversation and image understanding",
                icon: "bubble.left.and.bubble.right",
                model: recommendedStarterModel,
                state: downloadManager.state(for: recommendedStarterModel)
            ),
            capabilityItem(
                title: "Images",
                subtitle: "Image creation",
                icon: "photo",
                modality: .image
            ),
            capabilityItem(
                title: "Voice",
                subtitle: "Voice generation",
                icon: "waveform",
                modality: .audio
            ),
            capabilityItem(
                title: "Music",
                subtitle: "Music generation",
                icon: "music.note",
                modality: .music
            )
        ]

        return items.compactMap { $0 }
    }

    private func capabilityItem(
        title: String,
        subtitle: String,
        icon: String,
        modality: ModelModality
    ) -> CapabilitySetupItem? {
        guard let model = bestProfile(for: modality)?.downloadableModel
                ?? allModels.first(where: { $0.modality == modality }) else {
            return nil
        }

        return CapabilitySetupItem(
            title: title,
            subtitle: subtitle,
            icon: icon,
            model: model,
            state: downloadManager.state(for: model)
        )
    }

    private var activeCount: Int {
        allModels.filter { downloadManager.state(for: $0).isDownloading }.count
    }

    private var modelSetupStatus: ModelSetupStatus {
        if activeCount > 0 {
            return .downloading
        }

        let items = capabilityItems
        if !items.isEmpty,
           items.allSatisfy({ $0.model.isRuntimeCompatible && $0.state == .downloaded }) {
            return .ready
        }

        return .needsSetup
    }

    private func bestProfile(for modality: ModelModality) -> ModelCapabilityProfile? {
        ModelSelectionStore().selectedProfile(for: modality)
            ?? ModelCapabilityProfile.bestProfile(for: modality)
    }

    private func modelFit(for model: DownloadableModel) -> ModelFit {
        ModelCapabilityProfile.embeddedProfile(modelId: model.modelId)?.fit()
            ?? ModelFit.classify(estimatedMemoryGB: model.estimatedMemoryGB, hardwareMemoryGB: AIModel.currentHardwareMemoryGB)
    }

    private func modelSortKey(_ model: DownloadableModel) -> ModelListSortKey {
        let fit = modelFit(for: model)
        let state = downloadManager.state(for: model)
        let stateRank: Int
        switch state {
        case .downloaded:
            stateRank = 0
        case .downloading, .paused:
            stateRank = 1
        case .notDownloaded:
            stateRank = 2
        case .failed:
            stateRank = 3
        }
        return ModelListSortKey(
            fitRank: fit.sortRank,
            stateRank: stateRank,
            memoryRank: -(model.estimatedMemoryGB ?? 0),
            name: model.name
        )
    }
}

private struct ModelListSortKey: Comparable {
    let fitRank: Int
    let stateRank: Int
    let memoryRank: Double
    let name: String

    static func < (lhs: ModelListSortKey, rhs: ModelListSortKey) -> Bool {
        if lhs.fitRank != rhs.fitRank {
            return lhs.fitRank < rhs.fitRank
        }
        if lhs.stateRank != rhs.stateRank {
            return lhs.stateRank < rhs.stateRank
        }
        if lhs.memoryRank != rhs.memoryRank {
            return lhs.memoryRank < rhs.memoryRank
        }
        return lhs.name < rhs.name
    }
}

struct ModelSettingsModelSorter {
    static func sorted(
        models: [DownloadableModel],
        selectedModelId: String?,
        recommendedModelId: String?,
        state: (DownloadableModel) -> ModelDownloadManager.DownloadState,
        hardwareMemoryGB: Double = AIModel.currentHardwareMemoryGB,
        runtimeManifest: RuntimeManifest? = RuntimeManager.activeRuntimeManifest()
    ) -> [DownloadableModel] {
        models.sorted { lhs, rhs in
            sortKey(
                for: lhs,
                selectedModelId: selectedModelId,
                recommendedModelId: recommendedModelId,
                state: state(lhs),
                hardwareMemoryGB: hardwareMemoryGB,
                runtimeManifest: runtimeManifest
            ) < sortKey(
                for: rhs,
                selectedModelId: selectedModelId,
                recommendedModelId: recommendedModelId,
                state: state(rhs),
                hardwareMemoryGB: hardwareMemoryGB,
                runtimeManifest: runtimeManifest
            )
        }
    }

    private static func sortKey(
        for model: DownloadableModel,
        selectedModelId: String?,
        recommendedModelId: String?,
        state: ModelDownloadManager.DownloadState,
        hardwareMemoryGB: Double,
        runtimeManifest: RuntimeManifest?
    ) -> ModelSettingsSortKey {
        ModelSettingsSortKey(
            defaultRank: selectedModelId == model.modelId ? 0 : 1,
            recommendedRank: recommendedModelId == model.modelId ? 0 : 1,
            runtimeRank: isRuntimeCompatible(model, manifest: runtimeManifest) ? 0 : 1,
            stateRank: state.sortRank,
            fitRank: ModelFit
                .classify(estimatedMemoryGB: model.estimatedMemoryGB, hardwareMemoryGB: hardwareMemoryGB)
                .settingsSortRank,
            sizeRank: model.downloadSizeGB,
            name: model.name
        )
    }

    private static func isRuntimeCompatible(_ model: DownloadableModel, manifest: RuntimeManifest?) -> Bool {
        model.runtime.isSatisfied(by: manifest) && (manifest?.supports(backend: model.backend) ?? true)
    }
}

struct ModelSettingsSortKey: Comparable {
    let defaultRank: Int
    let recommendedRank: Int
    let runtimeRank: Int
    let stateRank: Int
    let fitRank: Int
    let sizeRank: Double
    let name: String

    static func < (lhs: ModelSettingsSortKey, rhs: ModelSettingsSortKey) -> Bool {
        if lhs.defaultRank != rhs.defaultRank { return lhs.defaultRank < rhs.defaultRank }
        if lhs.recommendedRank != rhs.recommendedRank { return lhs.recommendedRank < rhs.recommendedRank }
        if lhs.runtimeRank != rhs.runtimeRank { return lhs.runtimeRank < rhs.runtimeRank }
        if lhs.stateRank != rhs.stateRank { return lhs.stateRank < rhs.stateRank }
        if lhs.fitRank != rhs.fitRank { return lhs.fitRank < rhs.fitRank }
        if lhs.sizeRank != rhs.sizeRank { return lhs.sizeRank < rhs.sizeRank }
        return lhs.name < rhs.name
    }
}

private enum SettingsModelMode: String, CaseIterable, Identifiable {
    case chat
    case images
    case voice
    case music

    var id: String { rawValue }

    init(modality: ModelModality) {
        switch modality {
        case .vision:
            self = .chat
        case .image:
            self = .images
        case .audio:
            self = .voice
        case .music:
            self = .music
        }
    }

    var modality: ModelModality {
        switch self {
        case .chat: return .vision
        case .images: return .image
        case .voice: return .audio
        case .music: return .music
        }
    }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .images: return "Images"
        case .voice: return "Voice"
        case .music: return "Music"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .images: return "photo"
        case .voice: return "waveform"
        case .music: return "music.note"
        }
    }

    var defaultTitle: String {
        "Default for \(title)"
    }

    var purpose: String {
        switch self {
        case .chat: return "Conversation and image understanding"
        case .images: return "Image creation"
        case .voice: return "Voice generation"
        case .music: return "Music generation"
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case models
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Models"
        case .advanced: return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .models:
            return "Choose what runs locally on this Mac."
        case .advanced:
            return "Tune prompts and tool behavior."
        }
    }
}

private enum ModelSetupStatus {
    case ready
    case downloading
    case needsSetup

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .downloading: return "Downloading"
        case .needsSetup: return "Needs setup"
        }
    }

    var icon: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .needsSetup: return "arrow.down.circle"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .secondary
        case .downloading: return .accentColor
        case .needsSetup: return .orange
        }
    }
}

private struct ModelSetupBadge: View {
    let status: ModelSetupStatus

    var body: some View {
        Label(status.title, systemImage: status.icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(status.tint.opacity(0.10))
            .clipShape(Capsule())
    }
}

private struct ModelHeaderBadge: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(value)
                    .fontWeight(.semibold)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(MLXHubDesignSystem.Surface.quietHairline, lineWidth: 1)
        }
    }
}

private struct ModelModePicker: View {
    @Binding var selectedMode: SettingsModelMode

    var body: some View {
        Picker(selection: $selectedMode) {
            ForEach(SettingsModelMode.allCases) { mode in
                Label(mode.title, systemImage: mode.icon)
                    .tag(mode)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300, alignment: .leading)
        .accessibilityIdentifier("settings.modelModePicker")
    }
}

private struct CapabilitySetupItem: Identifiable {
    let title: String
    let subtitle: String
    let icon: String
    let model: DownloadableModel
    let state: ModelDownloadManager.DownloadState

    var id: String { title }
}

private struct RuntimeUpdateSection: View {
    @ObservedObject var manager: RuntimeUpdateManager

    var body: some View {
        switch manager.state {
        case .available(let asset):
            updateCard(
                title: "Runtime update available",
                detail: "Runtime \(asset.version), \(formatBytes(asset.sizeBytes))",
                icon: "arrow.triangle.2.circlepath.circle.fill",
                tint: .accentColor
            ) {
                Button {
                    Task {
                        await manager.installRuntime(asset)
                    }
                } label: {
                    Label("Install Runtime", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        case .installing:
            updateCard(
                title: "Installing runtime",
                detail: "Verifying and activating the downloaded runtime.",
                icon: "gearshape.2.fill",
                tint: .accentColor
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .installed(let version):
            updateCard(
                title: "Runtime installed",
                detail: "Runtime \(version) is ready for compatible models.",
                icon: "checkmark.circle.fill",
                tint: .secondary
            ) {
                EmptyView()
            }
        case .failed(let message):
            updateCard(
                title: "Runtime update unavailable",
                detail: message,
                icon: "exclamationmark.triangle.fill",
                tint: .orange
            ) {
                Button {
                    Task {
                        await manager.refreshStableChannel()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        case .checking, .idle:
            EmptyView()
        }
    }

    private func updateCard<Action: View>(
        title: String,
        detail: String,
        icon: String,
        tint: Color,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .designTintSurface(tint, cornerRadius: MLXHubDesignSystem.Radius.control)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
            action()
        }
        .padding(12)
        .designTintSurface(tint, cornerRadius: MLXHubDesignSystem.Radius.card)
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "size unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct CapabilitySetupSection: View {
    let items: [CapabilitySetupItem]
    let onDownload: (DownloadableModel) -> Void
    let onPause: (DownloadableModel) -> Void
    let onCancel: (DownloadableModel) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 280), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready for this Mac")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    CapabilitySetupCard(
                        item: item,
                        onDownload: onDownload,
                        onPause: onPause,
                        onCancel: onCancel
                    )
                }
            }
        }
    }
}

private struct CapabilitySetupCard: View {
    let item: CapabilitySetupItem
    let onDownload: (DownloadableModel) -> Void
    let onPause: (DownloadableModel) -> Void
    let onCancel: (DownloadableModel) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .designTintSurface(tint, cornerRadius: MLXHubDesignSystem.Radius.control)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.title3.weight(.semibold))

                    Spacer(minLength: 8)
                    statusLabel
                }

                Text(item.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.model.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                actionView
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .designTintSurface(tint, cornerRadius: MLXHubDesignSystem.Radius.card)
    }

    @ViewBuilder
    private var actionView: some View {
        if !item.model.isRuntimeCompatible {
            Label("Update needed", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        } else {
            switch item.state {
            case .downloaded:
                EmptyView()
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress?.fractionCompleted)
                        .frame(maxWidth: 180)
                    Text(progress?.displayText ?? "Downloading")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button {
                            onPause(item.model)
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        Button(role: .cancel) {
                            onCancel(item.model)
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .paused:
                HStack(spacing: 6) {
                    Button {
                        onDownload(item.model)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .cancel) {
                        onCancel(item.model)
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
                .controlSize(.small)
            case .notDownloaded, .failed:
                Button {
                    onDownload(item.model)
                } label: {
                    Label(item.state.recoveryActionTitle, systemImage: item.state.recoveryActionIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    private var statusLabel: some View {
        Label(statusText, systemImage: statusIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    private var statusText: String {
        switch item.state {
        case .downloaded:
            return "Ready"
        case .downloading:
            return "Downloading"
        case .paused:
            return "Paused"
        case .failed:
            return item.state.failureStatusTitle
        case .notDownloaded:
            return "Needs setup"
        }
    }

    private var statusIcon: String {
        switch item.state {
        case .downloaded:
            return "checkmark.circle.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .failed:
            return item.state.failureStatusIcon
        case .notDownloaded:
            return "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        switch item.state {
        case .downloaded:
            return .secondary
        case .downloading:
            return .accentColor
        case .paused:
            return .orange
        case .failed:
            return item.state.failureTint
        case .notDownloaded:
            return .orange
        }
    }
}

private struct ModelManagerRow: View {
    let model: DownloadableModel
    let mode: SettingsModelMode
    let state: ModelDownloadManager.DownloadState
    let isDefault: Bool
    let isRecommended: Bool
    let isPendingDownload: Bool
    @ObservedObject var runtimeUpdateManager: RuntimeUpdateManager
    let onSetDefault: () -> Void
    let onDownload: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            rowIcon

            VStack(alignment: .leading, spacing: 10) {
                rowMainLine
                detailsDisclosure
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(isPendingDownload ? Color.accentColor.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if isPendingDownload {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .accessibilityIdentifier("settings.modelRow.\(model.accessibilityIdentifierComponent)")
    }

    private var rowIcon: some View {
        Image(systemName: mode.icon)
            .font(.system(size: MLXHubDesignSystem.Icon.medium, weight: .semibold))
            .foregroundStyle(rowTint)
            .frame(width: 36, height: 36)
            .designTintSurface(rowTint, cornerRadius: MLXHubDesignSystem.Radius.control)
            .accessibilityIdentifier("settings.modelRow.icon")
    }

    private var rowMainLine: some View {
        HStack(alignment: .top, spacing: 16) {
            modelTextBlock
                .frame(maxWidth: .infinity, alignment: .leading)

            actionCluster
        }
    }

    private var modelTextBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.name)
                    .font(MLXHubDesignSystem.Typography.compactBodySemibold)

                if isDefault {
                    Label(mode.defaultTitle, systemImage: "checkmark.circle.fill")
                        .font(MLXHubDesignSystem.Typography.captionMedium)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }

            Text(mode.purpose)
                .font(MLXHubDesignSystem.Typography.compactBody)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 7) {
                readinessBadge
                recommendationBadge
                Text(formatSize(model.downloadSizeGB))
                    .font(MLXHubDesignSystem.Typography.microMedium)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.modelRow.textColumn")
    }

    private var actionCluster: some View {
        HStack(alignment: .top, spacing: 8) {
            actionView
                .frame(width: 176, alignment: .trailing)

            secondaryActionsMenu
                .frame(width: 28, height: 28, alignment: .topTrailing)
        }
        .frame(width: 212, alignment: .trailing)
        .padding(.top, 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.modelRow.actionColumn")
    }

    private var detailsDisclosure: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 6) {
                ModelDetailLine(label: "Source", value: model.source.downloadRepository ?? model.modelId)
                ModelDetailLine(label: "Model ID", value: model.modelId)
                ModelDetailLine(label: "Backend", value: model.backend.displayName)
                ModelDetailLine(label: "Runtime", value: "Runtime \(model.runtime.minVersion)+")
                ModelDetailLine(label: "Memory", value: model.estimatedMemoryGB.map(formatSize) ?? "Unknown")
                ModelDetailLine(label: "Storage", value: storageLabel)
            }
            .padding(.top, 6)
        } label: {
            Text("Details")
                .font(MLXHubDesignSystem.Typography.captionMedium)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.modelRow.details")
    }

    @ViewBuilder
    private var actionView: some View {
        if !model.isRuntimeCompatible {
            VStack(alignment: .trailing, spacing: 6) {
                Label("Runtime update required", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)

                runtimeAction
            }
            .accessibilityIdentifier("settings.modelState.runtimeRequired")
        } else {
            stateAction
        }
    }

    @ViewBuilder
    private var runtimeAction: some View {
        switch runtimeUpdateManager.state {
        case .available(let asset):
            Button {
                Task {
                    await runtimeUpdateManager.installRuntime(asset)
                }
            } label: {
                Label("Install Runtime", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed:
            Button {
                Task {
                    await runtimeUpdateManager.refreshStableChannel()
                }
            } label: {
                Label("Retry Runtime", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .idle, .installed:
            Button {
                Task {
                    await runtimeUpdateManager.refreshStableChannel()
                }
            } label: {
                Label("Check Runtime", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var stateAction: some View {
        switch state {
        case .notDownloaded:
            Button {
                onDownload()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .frame(width: primaryActionWidth)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("settings.modelState.missing")

        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 6) {
                if let fractionCompleted = progress?.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .frame(width: 150)
                    Text(progress?.displayText ?? "Downloading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    compactActionButton("Pause", systemImage: "pause.fill", action: onPause)
                    compactActionButton("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
                }
            }
            .accessibilityIdentifier("settings.modelState.downloading")

        case .paused:
            HStack(spacing: 6) {
                Button(action: onDownload) {
                    Label("Resume", systemImage: "play.fill")
                        .frame(width: primaryActionWidth)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                compactActionButton("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
            }
            .accessibilityIdentifier("settings.modelState.paused")

        case .downloaded:
            if !isDefault {
                Button {
                    onSetDefault()
                } label: {
                    Label("Use for \(mode.title)", systemImage: "checkmark.circle")
                        .frame(width: primaryActionWidth)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("settings.modelState.ready")
            }

        case .failed(let message):
            let failedState = ModelDownloadManager.DownloadState.failed(message)
            VStack(alignment: .trailing, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)

                Button(action: onDownload) {
                    Label(failedState.recoveryActionTitle, systemImage: failedState.recoveryActionIcon)
                        .frame(width: primaryActionWidth)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .accessibilityIdentifier(
                failedState.isRepairableFailure ? "settings.modelState.repair" : "settings.modelState.failed"
            )
        }
    }

    @ViewBuilder
    private var secondaryActionsMenu: some View {
        if hasSecondaryActions {
            Menu {
                if canSetDefaultFromMenu {
                    Button {
                        onSetDefault()
                    } label: {
                        Label("Set as Default", systemImage: "checkmark.circle")
                    }
                }

                if canSetDefaultFromMenu && canRemoveFromMenu {
                    Divider()
                }

                if canRemoveFromMenu {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove Model...", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityIdentifier("settings.modelState.moreActions")
        }
    }

    private func compactActionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }

    private var hasSecondaryActions: Bool {
        canSetDefaultFromMenu || canRemoveFromMenu
    }

    private var canSetDefaultFromMenu: Bool {
        guard !isDefault else { return false }

        switch state {
        case .downloaded:
            return false
        case .notDownloaded, .downloading, .paused, .failed:
            return true
        }
    }

    private var canRemoveFromMenu: Bool {
        state == .downloaded
    }

    private var primaryActionWidth: CGFloat {
        112
    }

    private var readinessBadge: some View {
        Label(state.shortStatusTitle, systemImage: state.shortStatusIcon)
            .font(MLXHubDesignSystem.Typography.microMedium)
            .foregroundStyle(state.statusTint)
            .accessibilityIdentifier("settings.modelState.\(state.accessibilityKey)")
    }

    @ViewBuilder
    private var recommendationBadge: some View {
        if isRecommended {
            Label("Best for this Mac", systemImage: "star.circle.fill")
                .font(MLXHubDesignSystem.Typography.microMedium)
                .foregroundStyle(.secondary)
        } else {
            Label(modelFit.alternativeTitle, systemImage: modelFit.systemImage)
                .font(MLXHubDesignSystem.Typography.microMedium)
                .foregroundStyle(modelFit.tint)
        }
    }

    private var modelFit: ModelFit {
        ModelFit.classify(
            estimatedMemoryGB: model.estimatedMemoryGB,
            hardwareMemoryGB: AIModel.currentHardwareMemoryGB
        )
    }

    private var rowTint: Color {
        isDefault ? .accentColor : .secondary
    }

    private var storageLabel: String {
        model.source.usesComponentBundle ? "MLXHub checkpoints" : "Hugging Face cache"
    }
}

private struct ModelDetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct AdvancedQuickControls: View {
    @Binding var systemPrompt: String
    @Binding var deepResearchSystemPrompt: String
    @Binding var toolDefinitionsJSON: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checklist")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .designTintSurface(Color.accentColor, cornerRadius: MLXHubDesignSystem.Radius.control)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt controls")
                        .font(.headline)
                    Text("Use these resets for normal setup. Raw prompt and tool JSON editing is available in Expert.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    systemPrompt = PromptConfiguration.defaultSystemPrompt
                } label: {
                    Label("Reset System", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    deepResearchSystemPrompt = PromptConfiguration.defaultDeepResearchSystemPrompt
                } label: {
                    Label("Reset Research", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)

                Button {
                    toolDefinitionsJSON = PromptConfiguration.defaultToolDefinitionsJSON
                } label: {
                    Label("Restore Tools", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .designPanelSurface(cornerRadius: MLXHubDesignSystem.Radius.card)
    }
}

private struct PromptEditorSection: View {
    let title: String
    @Binding var text: String
    let defaultValue: String
    var validationMessage: String?
    var monospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                Button("Reset") {
                    text = defaultValue
                }
                .buttonStyle(.borderless)
                .disabled(text == defaultValue)
            }

            TextEditor(text: $text)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: title == "Tool Definitions" ? 180 : 120)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.control, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var borderColor: Color {
        validationMessage == nil ? Color.primary.opacity(0.07) : Color.orange.opacity(0.45)
    }
}

private struct ToolDefinitionsEditorSection: View {
    @Binding var text: String
    let defaultValue: String
    @State private var draftText = ""

    private var validationMessage: String? {
        PromptConfiguration.toolDefinitionsValidationMessage(draftText)
    }

    private var hasChanges: Bool {
        draftText != text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tool Definitions")
                    .font(.headline)

                Spacer()

                Button("Revert") {
                    draftText = text
                }
                .buttonStyle(.borderless)
                .disabled(!hasChanges)

                Button("Restore") {
                    draftText = defaultValue
                    text = defaultValue
                }
                .buttonStyle(.borderless)

                Button("Save") {
                    guard validationMessage == nil else { return }
                    text = draftText
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasChanges || validationMessage != nil)
            }

            TextEditor(text: $draftText)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 180)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MLXHubDesignSystem.Radius.control, style: .continuous)
                        .stroke(validationMessage == nil ? MLXHubDesignSystem.Surface.quietHairline : Color.orange.opacity(0.45), lineWidth: 1)
                }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if hasChanges {
                Label("Unsaved tool changes", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if draftText.isEmpty {
                draftText = text
            }
        }
        .onChange(of: text) { _, newValue in
            if !hasChanges {
                draftText = newValue
            }
        }
    }
}

private struct ModelDownloadRow: View {
    let model: DownloadableModel
    @ObservedObject var downloadManager: ModelDownloadManager
    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""

    private var isPendingDownload: Bool {
        pendingDownloadModelId == model.modelId
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name)
                    .font(.body.weight(.medium))

                Text(model.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(model.modelId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text("\(formatSize(model.downloadSizeGB)) - \(storageLabel)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Label(modelFit.shortTitle, systemImage: modelFit.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(modelFit.tint)
            }

            Spacer(minLength: 16)

            statusView
                .frame(minWidth: 178, alignment: .trailing)
        }
        .padding(14)
        .background(isPendingDownload ? Color.accentColor.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if isPendingDownload {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .onChange(of: downloadManager.state(for: model)) { _, state in
            if isPendingDownload, state == .downloaded {
                pendingDownloadModelId = ""
            }
        }
        .onAppear {
            if isPendingDownload, downloadManager.state(for: model) == .downloaded {
                pendingDownloadModelId = ""
            }
        }
        .accessibilityIdentifier("settings.modelRow.\(model.accessibilityIdentifierComponent)")
    }

    @ViewBuilder
    private var statusView: some View {
        if !model.isRuntimeCompatible {
            VStack(alignment: .trailing, spacing: 6) {
                Label("Runtime update required", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                Text("Requires runtime \(model.runtime.minVersion)+")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settings.modelState.runtimeRequired")
        } else {
            switch downloadManager.state(for: model) {
            case .notDownloaded:
                VStack(alignment: .trailing, spacing: 6) {
                    if isPendingDownload {
                        Label("Required", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        downloadManager.download(model)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.modelState.missing")
                }

            case .downloading(let progress):
                VStack(alignment: .trailing, spacing: 6) {
                    if let fractionCompleted = progress?.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                            .frame(width: 160)

                        HStack(spacing: 6) {
                            Text(progress?.status ?? "Downloading")

                            Text(progress?.displayText ?? "")
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(progress?.displayText ?? "Downloading")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let detailText = progress?.detailText {
                        Text(detailText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Button {
                            downloadManager.pause(model)
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }

                        Button(role: .cancel) {
                            downloadManager.cancel(model)
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .accessibilityIdentifier("settings.modelState.downloading")

            case .paused(let progress):
                VStack(alignment: .trailing, spacing: 6) {
                    Label("Paused", systemImage: "pause.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)

                    if let detailText = progress?.detailText {
                        Text(detailText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Button {
                            downloadManager.resume(model)
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .cancel) {
                            downloadManager.cancel(model)
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    }
                    .controlSize(.small)
                }
                .accessibilityIdentifier("settings.modelState.paused")

            case .downloaded:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.modelState.ready")

            case .failed(let message):
                let failedState = ModelDownloadManager.DownloadState.failed(message)
                VStack(alignment: .trailing, spacing: 6) {
                    Label(failedState.failureStatusTitle, systemImage: failedState.failureStatusIcon)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(failedState.failureTint)

                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)

                    Button {
                        downloadManager.download(model)
                    } label: {
                        Label(failedState.recoveryActionTitle, systemImage: failedState.recoveryActionIcon)
                    }
                    .accessibilityIdentifier(
                        failedState.isRepairableFailure ? "settings.modelState.repair" : "settings.modelState.failed"
                    )
                }
                .accessibilityIdentifier(
                    failedState.isRepairableFailure ? "settings.modelState.repair" : "settings.modelState.failed"
                )
            }
        }
    }

    private var storageLabel: String {
        model.source.usesComponentBundle ? "MLXHub checkpoints" : "Hugging Face cache"
    }

    private var modelFit: ModelFit {
        ModelCapabilityProfile.embeddedProfile(modelId: model.modelId)?.fit()
            ?? ModelFit.classify(estimatedMemoryGB: model.estimatedMemoryGB, hardwareMemoryGB: AIModel.currentHardwareMemoryGB)
    }
}

private struct RequiredDownloadCallout: View {
    let model: DownloadableModel
    let state: ModelDownloadManager.DownloadState
    let onDownload: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("Download needed")
                    .font(.headline)

                Text("\(model.name), \(formatSize(model.downloadSizeGB))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            actionView

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(14)
        .designTintSurface(Color.accentColor, cornerRadius: MLXHubDesignSystem.Radius.control)
    }

    @ViewBuilder
    private var actionView: some View {
        switch state {
        case .notDownloaded, .failed:
            Button {
                onDownload()
            } label: {
                Label(state.recoveryActionTitle, systemImage: state.recoveryActionIcon)
            }
            .buttonStyle(.borderedProminent)

        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 5) {
                if let fractionCompleted = progress?.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .frame(width: 132)
                    Text(progress?.displayText ?? "Downloading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Button(action: onPause) {
                        Image(systemName: "pause.fill")
                    }
                    .help("Pause download")
                    Button(role: .cancel, action: onCancel) {
                        Image(systemName: "xmark")
                    }
                    .help("Cancel download")
                }
                .buttonStyle(.borderless)
            }
            .frame(width: 138, alignment: .trailing)

        case .paused:
            HStack(spacing: 6) {
                Button(action: onDownload) {
                    Label("Resume", systemImage: "play.fill")
                }
                Button(role: .cancel, action: onCancel) {
                    Image(systemName: "xmark")
                }
                .help("Cancel download")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyModelsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)

            Text("No models found")
                .font(.headline)

            Text("Try a different search or filter.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private enum ModelDownloadFilter: String, CaseIterable, Identifiable {
    case all
    case missing
    case ready

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .missing: return "Missing"
        case .ready: return "Ready"
        }
    }

    func includes(_ state: ModelDownloadManager.DownloadState) -> Bool {
        switch self {
        case .all:
            return true
        case .missing:
            return state != .downloaded
        case .ready:
            return state == .downloaded
        }
    }
}

private extension ModelDownloadManager.DownloadState {
    var sortRank: Int {
        switch self {
        case .downloaded:
            return 0
        case .downloading, .paused:
            return 1
        case .notDownloaded:
            return 2
        case .failed:
            return 3
        }
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var recoveryActionTitle: String {
        switch self {
        case .failed:
            return isRepairableFailure ? "Repair" : "Retry"
        case .notDownloaded:
            return "Download"
        case .paused:
            return "Resume"
        case .downloaded, .downloading:
            return ""
        }
    }

    var recoveryActionIcon: String {
        switch self {
        case .failed:
            return isRepairableFailure ? "wrench.and.screwdriver" : "arrow.clockwise"
        case .notDownloaded:
            return "arrow.down.circle"
        case .paused:
            return "play.fill"
        case .downloaded, .downloading:
            return "checkmark.circle.fill"
        }
    }

    var failureStatusTitle: String {
        isRepairableFailure ? "Needs repair" : "Failed"
    }

    var failureStatusIcon: String {
        isRepairableFailure ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill"
    }

    var failureTint: Color {
        isRepairableFailure ? .orange : .red
    }

    var shortStatusTitle: String {
        switch self {
        case .downloaded:
            return "Ready"
        case .downloading:
            return "Downloading"
        case .paused:
            return "Paused"
        case .notDownloaded:
            return "Missing"
        case .failed:
            return failureStatusTitle
        }
    }

    var shortStatusIcon: String {
        switch self {
        case .downloaded:
            return "checkmark.circle.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .notDownloaded:
            return "arrow.down.circle"
        case .failed:
            return failureStatusIcon
        }
    }

    var statusTint: Color {
        switch self {
        case .downloaded:
            return .secondary
        case .downloading:
            return .accentColor
        case .paused, .notDownloaded:
            return .orange
        case .failed:
            return failureTint
        }
    }

    var accessibilityKey: String {
        switch self {
        case .downloaded:
            return "ready"
        case .downloading:
            return "downloading"
        case .paused:
            return "paused"
        case .notDownloaded:
            return "missing"
        case .failed:
            return isRepairableFailure ? "repair" : "failed"
        }
    }
}

private extension ModelModality {
    var displayName: String {
        switch self {
        case .vision: return "Chat"
        case .image: return "Image"
        case .audio: return "Speech"
        case .music: return "Music"
        }
    }
}

private extension ModelFit {
    var alternativeTitle: String {
        switch self {
        case .recommended: return "Works well"
        case .compatible: return "Works"
        case .heavy: return "Too large"
        case .unknown: return "Unknown fit"
        }
    }

    var settingsSortRank: Int {
        switch self {
        case .recommended: return 0
        case .compatible: return 1
        case .heavy: return 2
        case .unknown: return 3
        }
    }

    var tint: Color {
        switch self {
        case .recommended, .compatible: return .secondary
        case .heavy: return .orange
        case .unknown: return .secondary
        }
    }
}

private extension DownloadableModel {
    var accessibilityIdentifierComponent: String {
        id.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
    }

    func matchesDownloadSearch(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || subtitle.localizedCaseInsensitiveContains(query)
            || modelId.localizedCaseInsensitiveContains(query)
            || modality.rawValue.localizedCaseInsensitiveContains(query)
    }
}

private func formatSize(_ gigabytes: Double) -> String {
    "\(String(format: "%.1f", gigabytes)) GB"
}

#Preview {
    SettingsView()
}
