import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @State private var isTextInputFocused = false
    @State private var isDropTargeted = false

    private var borderIsActive: Bool {
        viewModel.isPreparingMessage || viewModel.isGenerating || viewModel.isTerminatingLocalEngine || isTextInputFocused || isDropTargeted
    }

    private var canSend: Bool {
        viewModel.composerDraft.isPrimaryEnabled
    }

    private var attachmentHelp: String {
        viewModel.selectedTool == .image ? "Add reference image" : "Attach image"
    }

    private var filePickerMessage: String {
        viewModel.selectedTool == .image ? "Select a reference image" : "Select images to attach"
    }

    private var filePickerPrompt: String {
        viewModel.selectedTool == .image ? "Add Reference" : "Attach"
    }

    private let acceptedDropTypes = [
        UTType.fileURL.identifier,
        UTType.image.identifier,
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.tiff.identifier,
        UTType.gif.identifier
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.md) {
            attachmentTray
            VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.sm) {
                textInput
                modeDraftControls

                HStack(alignment: .center, spacing: MLXtraDesignSystem.Spacing.md) {
                    attachmentButton
                    ToolSelectorInline(viewModel: viewModel)
                    Spacer(minLength: MLXtraDesignSystem.Spacing.xl)
                    ComposerModelControl(
                        viewModel: viewModel,
                        onOpenModels: { openSettings() },
                        onRestart: viewModel.restartLocalEngine,
                        onFreeMemory: viewModel.freeLocalEngineMemory
                    )
                    primaryControl
                }
                .padding(.horizontal, MLXtraDesignSystem.Spacing.xxs)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(MLXtraDesignSystem.Layout.composerSurfacePadding)
        .nativeGlassSurface(cornerRadius: MLXtraDesignSystem.Radius.composer, interactive: true)
        .shadow(
            color: Color(NSColor.shadowColor).opacity(MLXtraDesignSystem.Elevation.floatingShadowOpacity),
            radius: MLXtraDesignSystem.Elevation.floatingShadowRadius,
            x: 0,
            y: MLXtraDesignSystem.Elevation.floatingShadowY
        )
        .overlay(composerBorder)
        .animation(.easeInOut(duration: MLXtraDesignSystem.Motion.focusDuration), value: borderIsActive)
        .onAppear {
            viewModel.refreshLocalEngineDownloadStatus()
        }
        .onDrop(of: acceptedDropTypes, isTargeted: $isDropTargeted, perform: handleImageDrop)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer")
    }

    @ViewBuilder
    private var attachmentTray: some View {
        if !viewModel.selectedImagePaths.isEmpty {
            HStack(spacing: 12) {
                ForEach(0..<viewModel.selectedImagePaths.count, id: \.self) { index in
                    let url = viewModel.selectedImagePaths[index]
                    ImageThumbnailView(
                        imageURL: url,
                        filename: url.lastPathComponent,
                        onRemove: { removeImage(at: index) }
                    )
                }
                Spacer()
            }
            .padding(.horizontal, MLXtraDesignSystem.Spacing.xxxl)
            .padding(.top, MLXtraDesignSystem.Spacing.xs)
            .padding(.bottom, MLXtraDesignSystem.Spacing.xxs)
        }
    }

    private var textInput: some View {
        ZStack(alignment: .topLeading) {
            MultilineTextInput(
                text: $viewModel.inputText,
                placeholder: viewModel.composerPlaceholder,
                isFocused: $isTextInputFocused,
                isEditable: !viewModel.isInputDisabled,
                focusRequest: viewModel.composerFocusRequest,
                onPasteImages: handlePasteboardImages,
                accessibilityIdentifier: "composer.input",
                accessibilityLabel: "Composer input",
                onSubmit: {
                    viewModel.performComposerPrimaryAction()
                }
            )
        }
        .frame(height: textInputHeight)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MLXtraDesignSystem.Spacing.xxl)
        .padding(.vertical, MLXtraDesignSystem.Spacing.xxs)
        .background {
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.composerField, style: .continuous)
                .fill(textInputSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.composerField, style: .continuous)
                .stroke(borderIsActive ? MLXtraDesignSystem.Surface.focusHairline : MLXtraDesignSystem.Surface.quietHairline, lineWidth: MLXtraDesignSystem.Spacing.hairline)
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                Text("Drop images to attach")
                    .font(MLXtraDesignSystem.Typography.compactBodyMedium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, MLXtraDesignSystem.Spacing.xl)
                    .padding(.vertical, MLXtraDesignSystem.Spacing.sm + 1)
                    .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.control)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("composer.inputField")
    }

    private var attachmentButton: some View {
        Button(action: showFilePicker) {
            Image(systemName: "plus")
                .font(.system(size: MLXtraDesignSystem.Icon.large, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
                .background(
                    Circle()
                        .fill(MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
                )
                .overlay {
                    Circle()
                        .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: MLXtraDesignSystem.Spacing.hairline)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(attachmentHelp)
        .disabled(viewModel.isInputDisabled)
    }

    @ViewBuilder
    private var primaryControl: some View {
        if viewModel.isPreparingMessage || viewModel.isTerminatingLocalEngine {
            ProgressView()
                .controlSize(.small)
                .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
                .background(
                    Circle()
                        .fill(MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
                )
                .overlay {
                    Circle()
                        .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: MLXtraDesignSystem.Spacing.hairline)
                }
                .help(viewModel.isTerminatingLocalEngine ? "Stopping local engine" : "Preparing attachments")
                .accessibilityIdentifier("composer.primaryAction")
                .accessibilityLabel(viewModel.isTerminatingLocalEngine ? "Stopping local engine" : "Preparing attachments")
        } else if viewModel.isGenerating {
            Button(action: {
                viewModel.cancelGeneration()
            }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: MLXtraDesignSystem.Icon.regular, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
                    .background(
                        Circle()
                            .fill(MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
                    )
                    .overlay {
                        Circle()
                            .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: MLXtraDesignSystem.Spacing.hairline)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop generating")
            .accessibilityIdentifier("composer.primaryAction")
            .accessibilityLabel("Stop generating")
        } else {
            SendActionButton(
                isEnabled: canSend,
                title: viewModel.composerPrimaryActionTitle,
                systemImage: viewModel.composerPrimaryActionSystemImage,
                help: viewModel.composerPrimaryActionHelp,
                disabledHelp: viewModel.composerPrimaryActionDisabledHelp,
                action: {
                    viewModel.performComposerPrimaryAction()
                }
            )
        }
    }

    @ViewBuilder
    private var modeDraftControls: some View {
        let draft = viewModel.composerDraft
        if draft.showsMusicControls || !draft.slots.isEmpty {
            ModeDraftControls(
                draft: draft,
                viewModel: viewModel,
                onAttachReference: showFilePicker
            )
                .padding(.top, MLXtraDesignSystem.Spacing.xs)
                .padding(.bottom, MLXtraDesignSystem.Spacing.xs)
        }
    }

    @ViewBuilder
    private var composerBorder: some View {
        RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.composer, style: .continuous)
            .stroke(
                borderIsActive ? MLXtraDesignSystem.Surface.focusHairline : MLXtraDesignSystem.Surface.quietHairline,
                lineWidth: MLXtraDesignSystem.Spacing.hairline
            )
            .allowsHitTesting(false)
    }

    private var textInputSurface: Color {
        MLXtraDesignSystem.Surface.fieldFill(colorScheme: colorScheme)
    }

    private var textInputHeight: CGFloat {
        guard !viewModel.inputText.isEmpty else {
            return MLXtraDesignSystem.Layout.composerMinTextHeight
        }

        let explicitLineCount = viewModel.inputText
            .components(separatedBy: .newlines)
            .count
        let minimumVisibleLines = MLXtraDesignSystem.Layout.composerMinimumVisibleInputLines
        guard explicitLineCount > minimumVisibleLines else {
            return MLXtraDesignSystem.Layout.composerMinTextHeight
        }

        let visibleLines = min(explicitLineCount, MLXtraDesignSystem.Layout.composerMaxVisibleInputLines)
        let addedLines = max(visibleLines - minimumVisibleLines, 0)
        return min(
            MLXtraDesignSystem.Layout.composerMinTextHeight
                + CGFloat(addedLines) * MLXtraDesignSystem.Layout.composerTextLineHeight,
            MLXtraDesignSystem.Layout.composerMaxTextHeight
        )
    }

    private func showFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .gif, .bmp]
        openPanel.message = filePickerMessage
        openPanel.prompt = filePickerPrompt

        if openPanel.runModal() == .OK {
            appendImageAttachments(openPanel.urls)
        }
    }

    private func removeImage(at index: Int) {
        if index < viewModel.selectedImagePaths.count {
            viewModel.selectedImagePaths.remove(at: index)
        }
    }

    private func appendImageAttachments(_ urls: [URL]) {
        let existingPaths = Set(viewModel.selectedImagePaths.map(\.standardizedFileURL.path))
        let newURLs = urls.filter { !existingPaths.contains($0.standardizedFileURL.path) }
        viewModel.selectedImagePaths.append(contentsOf: newURLs)
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !viewModel.isInputDisabled else { return false }

        var didAcceptProvider = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didAcceptProvider = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = fileURL(from: item), isSupportedImageURL(url) else { return }

                    DispatchQueue.main.async {
                        appendImageAttachments([url])
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                didAcceptProvider = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task {
                        guard let url = await saveTemporaryImageData(data) else { return }
                        await MainActor.run {
                            appendImageAttachments([url])
                        }
                    }
                }
            }
        }

        return didAcceptProvider
    }

    private func handlePasteboardImages() -> Bool {
        guard !viewModel.isInputDisabled else { return false }

        let pasteboard = NSPasteboard.general
        var imageURLs: [URL] = []

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            imageURLs.append(contentsOf: urls.filter(isSupportedImageURL))
        }

        if imageURLs.isEmpty,
           let imageData = imageData(from: pasteboard) {
            Task {
                guard let url = await saveTemporaryImageData(imageData) else { return }
                await MainActor.run {
                    appendImageAttachments([url])
                }
            }
            return true
        }

        guard !imageURLs.isEmpty else { return false }

        appendImageAttachments(imageURLs)
        return true
    }

    private func imageData(from pasteboard: NSPasteboard) -> Data? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) {
                return data
            }
        }
        return nil
    }
}
