import SwiftUI

struct SettingsView: View {
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""
    @AppStorage(PromptConfiguration.systemPromptKey) private var systemPrompt = PromptConfiguration.defaultSystemPrompt
    @AppStorage(PromptConfiguration.deepResearchSystemPromptKey) private var deepResearchSystemPrompt = PromptConfiguration.defaultDeepResearchSystemPrompt
    @AppStorage(PromptConfiguration.toolDefinitionsKey) private var toolDefinitionsJSON = PromptConfiguration.defaultToolDefinitionsJSON
    @AppStorage("MLXHub.showExpertSettings") private var showExpertSettings = false
    @State private var searchText = ""
    @State private var selectedFilter: ModelDownloadFilter = .all
    @State private var selectedPane: SettingsPane = .models
    @State private var showDetailedModels = false

    private var allModels: [DownloadableModel] {
        DownloadableModel.embedded
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
            downloadManager.refreshStatuses()
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
                HStack(spacing: 8) {
                    ModelSummaryBadge(
                        title: "Ready",
                        value: "\(readyCount)/\(allModels.count)",
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )

                    ModelSummaryBadge(
                        title: "Downloading",
                        value: "\(activeCount)",
                        systemImage: "arrow.down.circle.fill",
                        tint: .accentColor
                    )

                    ModelSummaryBadge(
                        title: "Size",
                        value: formatSize(totalDownloadSizeGB),
                        systemImage: "externaldrive.fill",
                        tint: .secondary
                    )

                    Button {
                        downloadManager.refreshStatuses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh model status")
                }
                .padding(.top, 2)
            }
        }
    }

    private var panePicker: some View {
        Picker("Settings", selection: $selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                Text(pane.title).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
    }

    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let pendingModel {
                RequiredDownloadCallout(
                    model: pendingModel,
                    state: downloadManager.state(for: pendingModel),
                    onDownload: {
                        downloadManager.download(pendingModel)
                    },
                    onPause: {
                        downloadManager.pause(pendingModel)
                    },
                    onCancel: {
                        downloadManager.cancel(pendingModel)
                    },
                    onDismiss: {
                        pendingDownloadModelId = ""
                    }
                )
            }

            BestForThisMacSection(
                profiles: bestProfilesForThisMac,
                downloadManager: downloadManager,
                onDownload: { model in
                    downloadManager.download(model)
                },
                onPause: { model in
                    downloadManager.pause(model)
                },
                onCancel: { model in
                    downloadManager.cancel(model)
                }
            )

            CapabilitySetupSection(
                items: capabilityItems,
                onDownload: { model in
                    downloadManager.download(model)
                },
                onPause: { model in
                    downloadManager.pause(model)
                },
                onCancel: { model in
                    downloadManager.cancel(model)
                }
            )

            DisclosureGroup(isExpanded: $showDetailedModels) {
                VStack(alignment: .leading, spacing: 14) {
                    controls

                    if modelsByModality.isEmpty {
                        EmptyModelsView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 56)
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(modelsByModality, id: \.0.id) { modality, models in
                                modelSection(modality: modality, models: models)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
                .padding(.top, 10)
            } label: {
                Label("Detailed model list", systemImage: "list.bullet.rectangle")
                    .font(.headline)
            }
        }
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
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
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
                    .background(.thinMaterial)
                    .clipShape(Capsule())

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
            .background(.thinMaterial.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
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
        selectedPane = .models
        showDetailedModels = true
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
              let model = DownloadableModel.embeddedModel(modelId: pendingDownloadModelId),
              downloadManager.state(for: model) != .downloaded else {
            return nil
        }
        return model
    }

    private var readyCount: Int {
        allModels.filter { downloadManager.state(for: $0) == .downloaded }.count
    }

    private var recommendedStarterModel: DownloadableModel {
        bestProfile(for: .vision)?.downloadableModel
            ?? allModels.first!
    }

    private var bestProfilesForThisMac: [ModelCapabilityProfile] {
        ModelModality.allCases.compactMap { bestProfile(for: $0) }
    }

    private var capabilityItems: [CapabilitySetupItem] {
        let items: [CapabilitySetupItem?] = [
            CapabilitySetupItem(
                title: "Chat",
                subtitle: "Local conversation and image understanding",
                icon: "bubble.left.and.bubble.right",
                model: recommendedStarterModel,
                fit: modelFit(for: recommendedStarterModel),
                state: downloadManager.state(for: recommendedStarterModel)
            ),
            capabilityItem(
                title: "Image",
                subtitle: "Generate or edit images",
                icon: "photo",
                modality: .image
            ),
            capabilityItem(
                title: "Speech",
                subtitle: "Create spoken audio",
                icon: "waveform",
                modality: .audio
            ),
            capabilityItem(
                title: "Music",
                subtitle: "Generate local music",
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
            fit: modelFit(for: model),
            state: downloadManager.state(for: model)
        )
    }

    private var activeCount: Int {
        allModels.filter { downloadManager.state(for: $0).isDownloading }.count
    }

    private var totalDownloadSizeGB: Double {
        allModels.reduce(0) { $0 + $1.downloadSizeGB }
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
            return "Download once, then use models locally."
        case .advanced:
            return "Tune prompts and tool behavior."
        }
    }
}

private struct CapabilitySetupItem: Identifiable {
    let title: String
    let subtitle: String
    let icon: String
    let model: DownloadableModel
    let fit: ModelFit
    let state: ModelDownloadManager.DownloadState

    var id: String { title }
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
            Text("Capabilities")
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))

                    statusLabel
                    fitLabel
                }

                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text("\(item.model.name) - \(formatSize(item.model.downloadSizeGB))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                actionView
                    .padding(.top, 3)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(.thinMaterial.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch item.state {
        case .downloaded:
            EmptyView()
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress?.fractionCompleted)
                    .frame(width: 140)
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
            .controlSize(.small)
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
            return "Missing"
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
            return "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .downloaded:
            return .green
        case .downloading:
            return .accentColor
        case .paused:
            return .orange
        case .failed:
            return item.state.failureTint
        case .notDownloaded:
            return .secondary
        }
    }

    private var fitLabel: some View {
        Label(item.fit.shortTitle, systemImage: item.fit.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(item.fit.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(item.fit.tint.opacity(0.10))
            .clipShape(Capsule())
    }
}

private struct BestForThisMacSection: View {
    let profiles: [ModelCapabilityProfile]
    @ObservedObject var downloadManager: ModelDownloadManager
    let onDownload: (DownloadableModel) -> Void
    let onPause: (DownloadableModel) -> Void
    let onCancel: (DownloadableModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Best for this Mac")
                .font(.headline)

            HStack(spacing: 10) {
                ForEach(profiles) { profile in
                    BestModelCard(
                        profile: profile,
                        state: downloadManager.state(for: profile.downloadableModel),
                        onDownload: {
                            onDownload(profile.downloadableModel)
                        },
                        onPause: {
                            onPause(profile.downloadableModel)
                        },
                        onCancel: {
                            onCancel(profile.downloadableModel)
                        }
                    )
                }
            }
        }
    }
}

private struct BestModelCard: View {
    let profile: ModelCapabilityProfile
    let state: ModelDownloadManager.DownloadState
    let onDownload: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: profile.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(profile.fit().tint)
                    .frame(width: 24, height: 24)
                    .background(profile.fit().tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(profile.modality.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(profile.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            HStack(spacing: 6) {
                Label(profile.fit().shortTitle, systemImage: profile.fit().systemImage)
                    .foregroundStyle(profile.fit().tint)
                Text(formatSize(profile.downloadSizeGB))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.medium))

            Spacer(minLength: 0)

            actionView
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(.thinMaterial.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch state {
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .downloading:
            HStack(spacing: 6) {
                Label("Downloading", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                }
                .help("Pause download")
                Button(role: .cancel, action: onCancel) {
                    Image(systemName: "xmark")
                }
                .help("Cancel download")
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
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
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .notDownloaded, .failed:
            Button {
                onDownload()
            } label: {
                Label(state.recoveryActionTitle, systemImage: state.recoveryActionIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
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
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

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
        .background(.thinMaterial.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
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
                .background(.thinMaterial.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
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
                .background(.thinMaterial.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(validationMessage == nil ? Color.primary.opacity(0.07) : Color.orange.opacity(0.45), lineWidth: 1)
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
        .accessibilityIdentifier("settings.modelRow.\(model.accessibilityIdentifierComponent)")
    }

    @ViewBuilder
    private var statusView: some View {
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
                .foregroundStyle(.green)
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

    private var storageLabel: String {
        model.modelId.hasPrefix("ACE-Step/") ? "MLXHub checkpoints" : "Hugging Face cache"
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
        .background(Color.accentColor.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
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
                .foregroundStyle(.green)
        }
    }
}

private struct ModelSummaryBadge: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
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
    var tint: Color {
        switch self {
        case .recommended: return .green
        case .compatible: return .accentColor
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
