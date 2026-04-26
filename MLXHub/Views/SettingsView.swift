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
            case .prompts:
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
                        title: "Active",
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

    private var activeCount: Int {
        allModels.filter { downloadManager.state(for: $0).isDownloading }.count
    }

    private var totalDownloadSizeGB: Double {
        allModels.reduce(0) { $0 + $1.downloadSizeGB }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case models
    case prompts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Models"
        case .prompts: return "Prompts"
        }
    }

    var subtitle: String {
        switch self {
        case .models:
            return "Download local models before first use."
        case .prompts:
            return "Tune chat, research, and tool behavior."
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
                Text("Required for your last request")
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
