import AppKit
import SwiftUI

struct PerformanceSettingsSection: View {
    @Binding var preloadLocalChatModelOnLaunch: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)

            VStack(alignment: .leading, spacing: 6) {
                Text("Performance")
                    .font(.headline)

                Text("Prepare the selected downloaded chat model shortly after launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Toggle("Prepare chat model at launch", isOn: $preloadLocalChatModelOnLaunch)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Prepare the selected downloaded chat model after launch. Downloads never start automatically.")
                .accessibilityIdentifier("settings.performance.preloadChatModel")
        }
        .padding(14)
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
    }
}

struct DiagnosticsSettingsSection: View {
    @ObservedObject private var logStore = DiagnosticsLogStore.shared
    @State private var copyStatus: String?

    private var recentEntries: [DiagnosticsLogEntry] {
        Array(logStore.entries.suffix(80).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Diagnostics")
                        .font(.headline)

                    Text("Capture local runtime, bridge, and generation events for troubleshooting.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("Capture logs", isOn: $logStore.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Records normal diagnostic events. Warnings and errors are kept even when this is off.")

                    Toggle("Verbose bridge logs", isOn: $logStore.verboseBridgeLoggingEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Records Python bridge stderr and enables bridge debug output for newly started local engines.")
                }
                .frame(width: 190, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Button {
                    copyLogs()
                } label: {
                    Label("Copy Logs", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    revealLogs()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    logStore.clear()
                    copyStatus = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                if let copyStatus {
                    Text(copyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(logStore.logFileURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(logStore.logFileURL.path)
            }

            Divider()

            HStack {
                Text("Recent Events")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(logStore.entries.count) captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if recentEntries.isEmpty {
                Text("No diagnostics captured yet. Enable Capture logs, then reproduce the issue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    .background(MLXtraDesignSystem.Surface.panelFill, in: RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(recentEntries) { entry in
                            DiagnosticsLogEntryRow(entry: entry)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 220)
                .background(MLXtraDesignSystem.Surface.panelFill, in: RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                        .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
                }
            }
        }
        .padding(14)
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
        .accessibilityIdentifier("settings.diagnostics")
    }

    private func copyLogs() {
        Task {
            let text = await logStore.exportText()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copyStatus = "Copied"
        }
    }

    private func revealLogs() {
        Task {
            await logStore.prepareLogFile()
            NSWorkspace.shared.activateFileViewerSelecting([logStore.logFileURL])
        }
    }
}

private struct DiagnosticsLogEntryRow: View {
    let entry: DiagnosticsLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(entry.level.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.12), in: Capsule())

                Text(entry.category.rawValue)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(entry.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .help(entry.message)

            if let details = trimmedDetails {
                Text(details)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(details)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tint: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var trimmedDetails: String? {
        let details = entry.details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return details.isEmpty ? nil : details
    }
}

struct AdvancedQuickControls: View {
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
                    .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)

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
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
    }
}

struct PromptEditorSection: View {
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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
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

struct ToolDefinitionsEditorSection: View {
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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                        .stroke(validationMessage == nil ? MLXtraDesignSystem.Surface.quietHairline : Color.orange.opacity(0.45), lineWidth: 1)
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

struct ModelDownloadRow: View {
    let model: DownloadableModel
    @ObservedObject var downloadManager: ModelDownloadManager
    @ObservedObject var runtimeUpdateManager: RuntimeUpdateManager
    @AppStorage("MLXtra.pendingDownloadModelId") private var pendingDownloadModelId = ""

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

                Text("\(formatSize(model.totalDownloadSizeGB)) - \(storageLabel)")
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
                Label("Setup required", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)

                Text("Requires \(model.runtime.component.displayName) \(model.runtime.minVersion)+ before download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)

                if isPendingDownload {
                    VStack(alignment: .trailing, spacing: 6) {
                        Label("Queued", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .cancel) {
                            pendingDownloadModelId = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .help("Remove from Queue")
                        .accessibilityLabel("Remove from Queue")
                    }
                } else {
                    Button {
                        requestDownload()
                    } label: {
                        Label("Queue Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
                        requestDownload()
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

                    Text(failedState.failureSummaryTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .help(message)
                        .accessibilityLabel(message)

                    Button {
                        requestDownload()
                    } label: {
                        Label(failedState.recoveryActionTitle, systemImage: failedState.recoveryActionIcon)
                    }
                    .accessibilityIdentifier(
                        "settings.modelState.\(failedState.accessibilityKey)"
                    )
                }
                .accessibilityIdentifier(
                    "settings.modelState.\(failedState.accessibilityKey)"
                )
            }
        }
    }

    private var storageLabel: String {
        model.source.usesComponentBundle ? "MLXtra checkpoints" : "Hugging Face cache"
    }

    private var modelFit: ModelFit {
        ModelCapabilityProfile.embeddedProfile(modelId: model.modelId)?.fit()
            ?? ModelFit.classify(estimatedMemoryGB: model.estimatedMemoryGB, hardwareMemoryGB: SystemHardware.currentMemoryGB)
    }

    private func requestDownload() {
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
}

struct RequiredDownloadCallout: View {
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

                Text("\(model.name), \(formatSize(model.totalDownloadSizeGB))")
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
        .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)
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

struct EmptyModelsView: View {
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
