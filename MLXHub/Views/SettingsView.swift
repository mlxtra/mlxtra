import SwiftUI

struct SettingsView: View {
    @StateObject private var downloadManager = ModelDownloadManager()
    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""
    @AppStorage(PromptConfiguration.systemPromptKey) private var systemPrompt = PromptConfiguration.defaultSystemPrompt
    @AppStorage(PromptConfiguration.deepResearchSystemPromptKey) private var deepResearchSystemPrompt = PromptConfiguration.defaultDeepResearchSystemPrompt
    @AppStorage(PromptConfiguration.toolDefinitionsKey) private var toolDefinitionsJSON = PromptConfiguration.defaultToolDefinitionsJSON
    @State private var searchText = ""
    @State private var selectedFilter: ModelDownloadFilter = .all
    @State private var selectedPane: SettingsPane = .models

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
        VStack(alignment: .leading, spacing: 18) {
            header
            panePicker

            switch selectedPane {
            case .models:
                modelsPane
            case .advanced:
                promptsPane
            }
        }
        .padding(24)
        .frame(width: 720, height: 560)
        .onAppear {
            downloadManager.refreshStatuses()
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
                    onDismiss: {
                        pendingDownloadModelId = ""
                    }
                )
            }

            BeginnerModelSetupPanel(
                starterModel: recommendedStarterModel,
                starterState: downloadManager.state(for: recommendedStarterModel),
                toolItems: beginnerToolItems,
                onDownload: { model in
                    downloadManager.download(model)
                }
            )

            controls

            ScrollViewReader { proxy in
                ScrollView {
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
                .onAppear {
                    scrollToPendingModel(proxy)
                }
                .onChange(of: pendingDownloadModelId) { _, _ in
                    scrollToPendingModel(proxy)
                }
            }
        }
    }

    private var promptsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PromptEditorSection(
                    title: "System Prompt",
                    text: $systemPrompt,
                    defaultValue: PromptConfiguration.defaultSystemPrompt
                )

                PromptEditorSection(
                    title: "Deep Research Prompt",
                    text: $deepResearchSystemPrompt,
                    defaultValue: PromptConfiguration.defaultDeepResearchSystemPrompt
                )

                PromptEditorSection(
                    title: "Tool Definitions",
                    text: $toolDefinitionsJSON,
                    defaultValue: PromptConfiguration.defaultToolDefinitionsJSON,
                    validationMessage: PromptConfiguration.toolDefinitionsValidationMessage(toolDefinitionsJSON),
                    monospaced: true
                )
            }
            .padding(.bottom, 12)
        }
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

    private var filteredModels: [DownloadableModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return allModels.filter { model in
            selectedFilter.includes(downloadManager.state(for: model))
                && (query.isEmpty || model.matchesDownloadSearch(query))
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
        DownloadableModel.embeddedModel(modelId: AIModel.defaultForCurrentHardware.modelId)
            ?? allModels.first!
    }

    private var beginnerToolItems: [BeginnerModelSetupItem] {
        allModels
            .filter { $0.modality != .vision }
            .map { model in
                BeginnerModelSetupItem(model: model, state: downloadManager.state(for: model))
            }
    }

    private var activeCount: Int {
        allModels.filter { downloadManager.state(for: $0).isDownloading }.count
    }

    private var totalDownloadSizeGB: Double {
        allModels.reduce(0) { $0 + $1.downloadSizeGB }
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

private struct BeginnerModelSetupItem: Identifiable {
    let model: DownloadableModel
    let state: ModelDownloadManager.DownloadState

    var id: String { model.id }
}

private struct BeginnerModelSetupPanel: View {
    let starterModel: DownloadableModel
    let starterState: ModelDownloadManager.DownloadState
    let toolItems: [BeginnerModelSetupItem]
    let onDownload: (DownloadableModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: starterState == .downloaded ? "checkmark.circle.fill" : "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(starterState == .downloaded ? Color.green : Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background((starterState == .downloaded ? Color.green : Color.accentColor).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Start local AI")
                        .font(.headline)
                    Text("Download one chat model first. Add image, speech, or music only when you need those tools.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                beginnerDownloadAction(model: starterModel, state: starterState)
            }

            Divider()

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Starter model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(starterModel.name)
                        .font(.callout.weight(.medium))
                }
                .frame(width: 170, alignment: .leading)

                setupStatusLabel(state: starterState)

                Spacer()

                Text("\(formatSize(starterModel.downloadSizeGB))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(toolItems) { item in
                    ToolSetupChip(item: item, onDownload: onDownload)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func beginnerDownloadAction(model: DownloadableModel, state: ModelDownloadManager.DownloadState) -> some View {
        switch state {
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 5) {
                ProgressView(value: progress?.fractionCompleted)
                    .frame(width: 130)
                Text(progress?.displayText ?? "Downloading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notDownloaded, .failed:
            Button {
                onDownload(model)
            } label: {
                Label(state.isFailed ? "Retry" : "Download Starter", systemImage: state.isFailed ? "arrow.clockwise" : "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func setupStatusLabel(state: ModelDownloadManager.DownloadState) -> some View {
        Label(statusTitle(for: state), systemImage: statusIcon(for: state))
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor(for: state))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(for: state).opacity(0.10))
            .clipShape(Capsule())
    }

    private func statusTitle(for state: ModelDownloadManager.DownloadState) -> String {
        switch state {
        case .downloaded:
            return "Ready"
        case .downloading:
            return "Downloading"
        case .failed:
            return "Needs retry"
        case .notDownloaded:
            return "Not downloaded"
        }
    }

    private func statusIcon(for state: ModelDownloadManager.DownloadState) -> String {
        switch state {
        case .downloaded:
            return "checkmark.circle.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .notDownloaded:
            return "circle"
        }
    }

    private func statusColor(for state: ModelDownloadManager.DownloadState) -> Color {
        switch state {
        case .downloaded:
            return .green
        case .downloading:
            return .accentColor
        case .failed:
            return .red
        case .notDownloaded:
            return .secondary
        }
    }
}

private struct ToolSetupChip: View {
    let item: BeginnerModelSetupItem
    let onDownload: (DownloadableModel) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.model.modality.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.model.modality.rawValue)
                    .font(.caption.weight(.semibold))
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if item.state == .notDownloaded || item.state.isFailed {
                Button {
                    onDownload(item.model)
                } label: {
                    Image(systemName: item.state.isFailed ? "arrow.clockwise" : "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(item.state.isFailed ? "Retry download" : "Download \(item.model.name)")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
    }

    private var statusText: String {
        switch item.state {
        case .downloaded:
            return "Ready"
        case .downloading(let progress):
            return progress?.displayText ?? "Downloading"
        case .failed:
            return "Retry"
        case .notDownloaded:
            return formatSize(item.model.downloadSizeGB)
        }
    }

    private var tint: Color {
        switch item.state {
        case .downloaded:
            return .green
        case .downloading:
            return .accentColor
        case .failed:
            return .red
        case .notDownloaded:
            return .secondary
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
            }

        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)

        case .failed(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)

                Button {
                    downloadManager.download(model)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var storageLabel: String {
        model.modelId.hasPrefix("ACE-Step/") ? "MLXHub checkpoints" : "Hugging Face cache"
    }
}

private struct RequiredDownloadCallout: View {
    let model: DownloadableModel
    let state: ModelDownloadManager.DownloadState
    let onDownload: () -> Void
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
                Label(state.isFailed ? "Retry" : "Download", systemImage: state.isFailed ? "arrow.clockwise" : "arrow.down.circle")
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
            }
            .frame(width: 138, alignment: .trailing)

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
}

private extension DownloadableModel {
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
