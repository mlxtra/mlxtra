import AppKit
import SwiftUI

struct SettingsView: View {
    private let appUpdateController: AppUpdateController?

    @StateObject private var downloadManager = ModelDownloadManager.shared
    @StateObject private var catalogService = ModelCatalogService.shared
    @StateObject private var runtimeUpdateManager = RuntimeUpdateManager.shared
    @AppStorage("MLXtra.pendingDownloadModelId") private var pendingDownloadModelId = ""
    @AppStorage(PromptConfiguration.systemPromptKey) private var systemPrompt = PromptConfiguration.defaultSystemPrompt
    @AppStorage(PromptConfiguration.deepResearchSystemPromptKey) private var deepResearchSystemPrompt = PromptConfiguration.defaultDeepResearchSystemPrompt
    @AppStorage(PromptConfiguration.toolDefinitionsKey) private var toolDefinitionsJSON = PromptConfiguration.defaultToolDefinitionsJSON
    @AppStorage("MLXtra.showExpertSettings") private var showExpertSettings = false
    @AppStorage(ChatViewModel.launchModelPreloadEnabledKey) private var preloadLocalChatModelOnLaunch = true
    @State private var searchText = ""
    @State private var selectedFilter: ModelDownloadFilter = .all
    @State private var selectedPane: SettingsPane = .models
    @State private var showDetailedModels = false
    @State private var selectedModelMode: SettingsModelMode = .chat
    @State private var modelSelectionRevision = 0
    @State private var removalCandidate: DownloadableModel?

    init(appUpdateController: AppUpdateController? = nil) {
        self.appUpdateController = appUpdateController
    }

    private var allModels: [DownloadableModel] {
        catalogService.profiles
            .filter(\.isCatalogVisible)
            .map(\.downloadableModel)
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
        .frame(minWidth: 720, idealWidth: 900, maxWidth: 1100, minHeight: 560, idealHeight: 680, maxHeight: 900)
        .accessibilityIdentifier("settings.window")
        .onAppear {
            clearInitialFocus()
            downloadManager.refreshStatuses()
            startPendingDownloadIfReady()
        }
        .onChange(of: downloadManager.states) { _, _ in
            startPendingDownloadIfReady()
        }
        .onChange(of: runtimeUpdateManager.state) { _, _ in
            startPendingDownloadIfReady()
        }
        .task {
            await catalogService.refreshFromStableChannel()
            runtimeUpdateManager.bootstrapStableRuntimeInBackground(reportFailures: false)
            downloadManager.refreshStatuses()
            startPendingDownloadIfReady()
        }
        .alert(item: $removalCandidate) { model in
            Alert(
                title: Text("Remove \(model.name)?"),
                message: Text("This frees about \(formatSize(model.totalDownloadSizeGB)). You can download it again later."),
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
        case .updates:
            updatesPane
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
            .frame(width: 300, alignment: .leading)

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
                    .font(MLXtraDesignSystem.Typography.sectionTitle)

                Text("\(selectedModeModels.count)")
                    .font(MLXtraDesignSystem.Typography.microMedium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(MLXtraDesignSystem.Surface.panelFill, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
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
                                requestModelDownload(model)
                            },
                            onPause: {
                                downloadManager.pause(model)
                            },
                            onCancel: {
                                cancelModelDownload(model)
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
                    RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                        .fill(MLXtraDesignSystem.Surface.contentFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                        .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
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

    private var updatesPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let appUpdateController {
                AppUpdateSettingsSection(
                    versionText: appVersionText,
                    controller: appUpdateController
                )
            }

            RuntimeUpdateSettingsSection(manager: runtimeUpdateManager)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.bottom, 12)
    }

    private var promptsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PerformanceSettingsSection(preloadLocalChatModelOnLaunch: $preloadLocalChatModelOnLaunch)

            AdvancedQuickControls(
                systemPrompt: $systemPrompt,
                deepResearchSystemPrompt: $deepResearchSystemPrompt,
                toolDefinitionsJSON: $toolDefinitionsJSON
            )

            ClickableDisclosureSection(isExpanded: $showExpertSettings) {
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

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String).flatMap(nonPlaceholderValue) ?? "Unknown"
        let build = (info["CFBundleVersion"] as? String).flatMap(nonPlaceholderValue)

        if let build {
            return "\(version) (\(build))"
        }

        return version
    }

    private func nonPlaceholderValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
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
            .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.control)
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
                            .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
                    }

                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(models) { model in
                    ModelDownloadRow(
                        model: model,
                        downloadManager: downloadManager,
                        runtimeUpdateManager: runtimeUpdateManager
                    )
                        .id(model.modelId)

                    if model.id != models.last?.id {
                        Divider()
                    }
                }
            }
            .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
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

    private func requestModelDownload(_ model: DownloadableModel) {
        guard !model.requiresRuntimeSetupBeforeDownload() else {
            pendingDownloadModelId = model.modelId
            runtimeUpdateManager.bootstrapStableRuntimeInBackground(
                reportFailures: true,
                component: model.runtime.component
            )
            return
        }

        if pendingDownloadModelId == model.modelId {
            pendingDownloadModelId = ""
        }
        downloadManager.download(model)
    }

    private func cancelModelDownload(_ model: DownloadableModel) {
        if pendingDownloadModelId == model.modelId {
            pendingDownloadModelId = ""
            return
        }

        downloadManager.cancel(model)
    }

    private func startPendingDownloadIfReady() {
        guard !pendingDownloadModelId.isEmpty else { return }
        guard let model = catalogModels.first(where: { $0.modelId == pendingDownloadModelId })
                ?? DownloadableModel.embeddedModel(modelId: pendingDownloadModelId) else {
            pendingDownloadModelId = ""
            return
        }

        switch downloadManager.state(for: model) {
        case .downloaded:
            pendingDownloadModelId = ""
        case .notDownloaded, .failed:
            guard !model.requiresRuntimeSetupBeforeDownload() else {
                runtimeUpdateManager.bootstrapStableRuntimeInBackground(
                    reportFailures: true,
                    component: model.runtime.component
                )
                return
            }
            downloadManager.download(model)
        case .downloading, .paused:
            return
        }
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
            .reduce(0) { $0 + $1.totalDownloadSizeGB }
    }

    private func defaultModelId(for mode: SettingsModelMode) -> String? {
        _ = modelSelectionRevision
        return ModelSelectionStore().selectedAvailableProfile(for: mode.modality) { model in
            downloadManager.state(for: model) == .downloaded
        }?.modelId
    }

    private func recommendedModelId(for mode: SettingsModelMode) -> String? {
        ModelCapabilityProfile.bestProfile(for: mode.modality)?.modelId
    }

    private func setDefaultModel(_ model: DownloadableModel, for mode: SettingsModelMode) {
        ModelSelectionStore().setSelectedModelId(model.modelId, for: mode.modality)
        modelSelectionRevision += 1
    }

    private var recommendedStarterModel: DownloadableModel? {
        bestProfile(for: .vision)?.downloadableModel
            ?? allModels.first
    }

    private var capabilityItems: [CapabilitySetupItem] {
        let items: [CapabilitySetupItem?] = [
            recommendedStarterModel.map { model in
                CapabilitySetupItem(
                    title: "Chat",
                    subtitle: "Conversation and image understanding",
                    icon: "bubble.left.and.bubble.right",
                    model: model,
                    state: downloadManager.state(for: model)
                )
            },
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
        ModelSelectionStore().selectedAvailableProfile(for: modality) { model in
            downloadManager.state(for: model) == .downloaded
        }
            ?? ModelSelectionStore().selectedProfile(for: modality)
            ?? ModelCapabilityProfile.bestProfile(for: modality)
    }

    private func modelFit(for model: DownloadableModel) -> ModelFit {
        ModelCapabilityProfile.embeddedProfile(modelId: model.modelId)?.fit()
            ?? ModelFit.classify(estimatedMemoryGB: model.estimatedMemoryGB, hardwareMemoryGB: SystemHardware.currentMemoryGB)
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
