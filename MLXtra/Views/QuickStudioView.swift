import AppKit
import SwiftUI

struct QuickStudioView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftText = ""

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedDraft.isEmpty && !viewModel.isInputDisabled
    }

    private var sendHelp: String {
        if trimmedDraft.isEmpty { return "Type a prompt" }
        if viewModel.isInputDisabled { return "MLXtra is busy" }
        return "Start a new chat"
    }

    private var status: QuickStudioEngineStatus {
        if viewModel.isGenerating {
            return QuickStudioEngineStatus(
                title: "Generating",
                detail: statusDetailFallback("Working locally"),
                systemImage: "waveform",
                tint: MLXtraDesignSystem.Palette.accent
            )
        }

        if viewModel.isPythonLoading || viewModel.isModelLoading || viewModel.isDraftingMusicLyrics {
            return QuickStudioEngineStatus(
                title: "Loading",
                detail: statusDetailFallback("Preparing local engine"),
                systemImage: "progress.indicator",
                tint: MLXtraDesignSystem.Palette.warning
            )
        }

        if let pendingModel = viewModel.pendingEngineDownloadModel {
            return QuickStudioEngineStatus(
                title: "Needs model",
                detail: ChatDisplayText.singleLine(pendingModel.name, fallback: "Download required", maxLength: 34),
                systemImage: "arrow.down.circle",
                tint: MLXtraDesignSystem.Palette.warning
            )
        }

        if viewModel.localEngineErrorMessage != nil {
            return QuickStudioEngineStatus(
                title: "Needs attention",
                detail: "Restart local engine",
                systemImage: "exclamationmark.circle",
                tint: MLXtraDesignSystem.Palette.danger
            )
        }

        return QuickStudioEngineStatus(
            title: "Ready",
            detail: "Auto chat",
            systemImage: "checkmark.circle",
            tint: MLXtraDesignSystem.Palette.success
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xxxl) {
            header
            promptSurface
            Divider()
            appActions
        }
        .frame(width: 340)
        .padding(MLXtraDesignSystem.Spacing.section)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: MLXtraDesignSystem.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(status.tint.opacity(0.13))
                Image(systemName: status.systemImage)
                    .font(.system(size: MLXtraDesignSystem.Icon.large, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xxs) {
                Text("Quick Studio")
                    .font(MLXtraDesignSystem.Typography.sectionTitle)
                Text("\(status.title) - \(status.detail)")
                    .font(MLXtraDesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: MLXtraDesignSystem.Spacing.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quickStudio.header")
    }

    private var promptSurface: some View {
        HStack(alignment: .bottom, spacing: MLXtraDesignSystem.Spacing.lg) {
            TextField("Start a new chat", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MLXtraDesignSystem.Typography.messageBody)
                .lineLimit(2...5)
                .disabled(viewModel.isInputDisabled)
                .onSubmit(sendDraft)
                .accessibilityIdentifier("quickStudio.input")

            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: MLXtraDesignSystem.Icon.medium, weight: .semibold))
                    .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSubmit ? .white : .secondary)
            .background(
                Circle()
                    .fill(canSubmit ? MLXtraDesignSystem.Palette.accent : MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
            )
            .overlay {
                Circle()
                    .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: MLXtraDesignSystem.Spacing.hairline)
            }
            .disabled(!canSubmit)
            .help(sendHelp)
            .accessibilityLabel("Start new chat")
            .accessibilityIdentifier("quickStudio.send")
        }
        .padding(MLXtraDesignSystem.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                .fill(MLXtraDesignSystem.Surface.fieldFill(colorScheme: colorScheme))
        )
        .overlay {
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: MLXtraDesignSystem.Spacing.hairline)
        }
    }

    private var appActions: some View {
        VStack(spacing: MLXtraDesignSystem.Spacing.sm) {
            HStack(spacing: MLXtraDesignSystem.Spacing.sm) {
                quickActionButton(title: "Open MLXtra", systemImage: "macwindow", action: openMainWindow)
                quickActionButton(title: "New Chat", systemImage: "square.and.pencil") {
                    guard !viewModel.isInputDisabled else { return }
                    viewModel.createNewChat()
                    openMainWindow()
                    dismiss()
                }
                .disabled(viewModel.isInputDisabled)
            }

            HStack(spacing: MLXtraDesignSystem.Spacing.sm) {
                quickActionButton(title: "Settings", systemImage: "gearshape") {
                    openSettings()
                    activateApp()
                }

                quickActionButton(title: "Quit", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func quickActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(MLXtraDesignSystem.Typography.captionMedium)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                .fill(MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
        )
        .overlay {
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: MLXtraDesignSystem.Spacing.hairline)
        }
        .help(title)
    }

    private func sendDraft() {
        guard viewModel.submitQuickPrompt(draftText) else { return }
        draftText = ""
        openMainWindow()
        dismiss()
    }

    private func statusDetailFallback(_ fallback: String) -> String {
        ChatDisplayText.singleLine(viewModel.loadingMessage, fallback: fallback, maxLength: 34)
    }

    private func openMainWindow() {
        if let window = mainWindow() {
            activateApp()
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: "main")
        activateApp()

        DispatchQueue.main.async {
            mainWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    private func activateApp() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func mainWindow() -> NSWindow? {
        NSApplication.shared.windows.first { window in
            window.title != "MLXtra Settings"
                && !window.title.isEmpty
                && window.styleMask.contains(.titled)
        }
    }
}

private struct QuickStudioEngineStatus {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
}

#Preview {
    QuickStudioView(viewModel: ChatViewModel())
}
