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
        viewModel.isGenerating || isTextInputFocused || isDropTargeted
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
        if viewModel.isGenerating {
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
                    guard
                        let data,
                        let image = NSImage(data: data),
                        let url = saveTemporaryImage(image)
                    else {
                        return
                    }

                    DispatchQueue.main.async {
                        appendImageAttachments([url])
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
           let image = NSImage(pasteboard: pasteboard),
           let url = saveTemporaryImage(image) {
            imageURLs.append(url)
        }

        guard !imageURLs.isEmpty else { return false }

        appendImageAttachments(imageURLs)
        return true
    }
}

private struct ModeDraftControls: View {
    let draft: ComposerDraft
    @ObservedObject var viewModel: ChatViewModel
    let onAttachReference: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isLyricsFocused = false

    private let controlTextRailInset = MLXtraDesignSystem.Spacing.xxl

    private var promptIsEmpty: Bool {
        !viewModel.hasMusicDraftPrompt
    }

    private var lyricsAreEmpty: Bool {
        viewModel.musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowLyricsEditor: Bool {
        draft.showsMusicControls
            && viewModel.musicVocalMode != .instrumental
            && (
                viewModel.musicVocalMode == .vocals
                    || !lyricsAreEmpty
                    || viewModel.isMusicLyricsEditorVisible
                    || viewModel.musicComposerPrompt == .needsLyrics
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.showsMusicControls {
                musicSetupRow
                    .padding(.horizontal, controlTextRailInset)
            }

            ForEach(draft.slots) { slot in
                ComposerDraftSlotRow(slot: slot) { action in
                    perform(slotAction: action)
                }
                .padding(.horizontal, controlTextRailInset)
            }

            if shouldShowLyricsEditor {
                lyricsEditor
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var musicSetupRow: some View {
        HStack(spacing: 10) {
            Text("Vocals")
                .font(MLXtraDesignSystem.Typography.captionMedium)
                .foregroundStyle(.secondary)

            Picker("", selection: vocalModeBinding) {
                ForEach(MusicVocalMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            Spacer(minLength: 0)
        }
    }

    private var vocalModeBinding: Binding<MusicVocalMode> {
        Binding(
            get: { viewModel.musicVocalMode },
            set: { viewModel.selectMusicVocalMode($0) }
        )
    }

    private func perform(slotAction: ComposerDraftSlotAction) {
        if slotAction == .attachReference {
            onAttachReference()
        } else {
            viewModel.performComposerSlotAction(slotAction)
        }
    }

    private var lyricsEditor: some View {
        VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.sm) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    viewModel.rewriteMusicLyrics()
                } label: {
                    Label(lyricsButtonTitle, systemImage: "sparkles")
                }
                .font(MLXtraDesignSystem.Typography.captionMedium)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(promptIsEmpty || viewModel.isDraftingMusicLyrics)
            }
            .padding(.horizontal, controlTextRailInset)

            MultilineTextInput(
                text: $viewModel.musicLyricsText,
                placeholder: "Add lyrics...",
                isFocused: $isLyricsFocused,
                isEditable: !viewModel.isInputDisabled,
                submitsOnReturn: false,
                accessibilityIdentifier: "composer.musicLyricsInput",
                accessibilityLabel: "Music lyrics"
            )
            .frame(height: MLXtraDesignSystem.Layout.musicLyricsTextHeight)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, MLXtraDesignSystem.Spacing.xxl)
            .padding(.vertical, MLXtraDesignSystem.Spacing.xxs)
            .background {
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.composerField, style: .continuous)
                    .fill(MLXtraDesignSystem.Surface.fieldFill(colorScheme: colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.composerField, style: .continuous)
                    .stroke(
                        isLyricsFocused ? MLXtraDesignSystem.Surface.focusHairline : MLXtraDesignSystem.Surface.quietHairline,
                        lineWidth: MLXtraDesignSystem.Spacing.hairline
                    )
            }
        }
        .accessibilityIdentifier("composer.musicLyricsEditor")
    }

    private var lyricsButtonTitle: String {
        if viewModel.isDraftingMusicLyrics {
            return "Generating..."
        }
        return lyricsAreEmpty ? "Draft lyrics" : "Refresh lyrics"
    }
}

private struct ComposerDraftSlotRow: View {
    let slot: ComposerDraftSlot
    let perform: (ComposerDraftSlotAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: slot.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .designTintSurface(iconColor, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(MLXtraDesignSystem.Typography.captionMedium)

                if let subtitle = slot.subtitle {
                    Text(subtitle)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            ForEach(slot.actions) { item in
                Button {
                    perform(item.action)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var iconColor: Color {
        slot.tone == .needed ? Color.accentColor : Color.secondary
    }

    private var backgroundColor: Color {
        switch slot.tone {
        case .needed:
            return Color.accentColor.opacity(0.07)
        case .neutral:
            return Color.primary.opacity(0.035)
        }
    }

    private var borderColor: Color {
        switch slot.tone {
        case .needed:
            return Color.accentColor.opacity(0.14)
        case .neutral:
            return Color.primary.opacity(0.07)
        }
    }
}

private struct SendActionButton: View {
    let isEnabled: Bool
    var title: String? = nil
    var systemImage: String = "arrow.up"
    var help: String = "Send message"
    var disabledHelp: String = "Type a message to send"
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: MLXtraDesignSystem.Icon.medium + 1, weight: .bold))
                .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.65))
            .background {
                Circle()
                    .fill(background)
                    .overlay {
                        Circle()
                            .strokeBorder(borderColor, lineWidth: MLXtraDesignSystem.Spacing.hairline)
                    }
            }
            .shadow(
                color: shadowColor,
                radius: isEnabled ? (isHovered ? 7 : 4) : 0,
                x: 0,
                y: isHovered ? MLXtraDesignSystem.Spacing.xxs + 1 : MLXtraDesignSystem.Spacing.hairline
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? help : disabledHelp)
        .accessibilityIdentifier("composer.primaryAction")
        .accessibilityLabel(help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: MLXtraDesignSystem.Motion.controlDuration)) {
                isHovered = hovering
            }
        }
    }

    private var background: AnyShapeStyle {
        if isEnabled {
            return AnyShapeStyle(Color.accentColor)
        }

        return AnyShapeStyle(Color.primary.opacity(0.06))
    }

    private var borderColor: Color {
        isEnabled ? Color.white.opacity(0.18) : MLXtraDesignSystem.Palette.separator.opacity(0.28)
    }

    private var shadowColor: Color {
        isEnabled ? MLXtraDesignSystem.Palette.accent.opacity(0.16) : Color.clear
    }
}

private struct LocalEngineStatusPopover: View {
    let status: LocalEngineStatus
    let canFreeMemory: Bool
    let onOpenModels: () -> Void
    let onRestart: () -> Void
    let onFreeMemory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(status.title)
                        .font(MLXtraDesignSystem.Typography.compactBodySemibold)

                    Text(status.detail)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if status.primaryAction != nil || canFreeMemory {
                Divider()
            }

            if status.primaryAction == .openModels {
                Button {
                    onOpenModels()
                } label: {
                    Label("Open Models", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderedProminent)
            }

            if status.primaryAction == .restart {
                Button {
                    onRestart()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }

            if canFreeMemory {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        onFreeMemory()
                    } label: {
                        Label("Free Memory", systemImage: "memorychip")
                    }
                    .buttonStyle(.bordered)

                    Text("The model will load again when needed.")
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private var iconTint: Color {
        status.state == .ready ? MLXtraDesignSystem.Palette.secondaryLabel : status.tone.color
    }
}

struct ComposerModelControl: View {
    @ObservedObject var viewModel: ChatViewModel
    let onOpenModels: () -> Void
    let onRestart: () -> Void
    let onFreeMemory: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @State private var isModelPickerPresented = false
    @State private var isSettingsPresented = false
    @State private var isStatusPresented = false
    @AppStorage("MLXtra.pendingDownloadModelId") private var pendingDownloadModelId = ""

    private var profile: ModelCapabilityProfile {
        viewModel.activeModelProfile
    }

    private var status: LocalEngineStatus {
        viewModel.localEngineStatus
    }

    private var isLoading: Bool {
        status.state == .preparing
            || status.state == .loadingModel
            || (status.loadProgress != nil && (viewModel.isGenerating || viewModel.isModelLoading || viewModel.isPythonLoading))
    }

    private var showsLoadingLine: Bool {
        isLoading || status.loadProgress != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isModelPickerPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: profile.icon)
                        .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .medium))
                        .foregroundStyle(isLoading ? Color.accentColor : MLXtraDesignSystem.Palette.secondaryLabel)
                        .frame(width: 16)

                    Text(compactModelTitle)
                        .font(MLXtraDesignSystem.Typography.compactBodyMedium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "chevron.down")
                        .font(.system(size: MLXtraDesignSystem.Icon.micro, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 10)
                .padding(.trailing, 9)
                .frame(maxWidth: 188, minHeight: MLXtraDesignSystem.Icon.composerButton)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose model")
            .disabled(viewModel.isInputDisabled)
            .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
                ComposerModelPickerPopover(
                    viewModel: viewModel,
                    downloadManager: downloadManager,
                    isPresented: $isModelPickerPresented
                )
                .frame(width: 330)
            }
            .accessibilityIdentifier("composer.modelDropdown")

            segmentDivider

            Button {
                isSettingsPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .medium))
                    .foregroundStyle(MLXtraDesignSystem.Palette.secondaryLabel)
                    .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Model settings")
            .disabled(viewModel.isInputDisabled)
            .popover(isPresented: $isSettingsPresented, arrowEdge: .bottom) {
                ModelParameterPopover(viewModel: viewModel, profile: profile)
                    .frame(width: 320)
            }
            .accessibilityIdentifier("composer.modelSettings")

            segmentDivider

            Button {
                isStatusPresented.toggle()
            } label: {
                Image(systemName: status.systemImage)
                    .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .semibold))
                    .foregroundStyle(statusIconTint)
                    .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(status.detail)
            .popover(isPresented: $isStatusPresented, arrowEdge: .bottom) {
                LocalEngineStatusPopover(
                    status: status,
                    canFreeMemory: viewModel.canFreeLocalEngineMemory,
                    onOpenModels: {
                        isStatusPresented = false
                        if let modelId = status.primaryActionModelId {
                            pendingDownloadModelId = modelId
                        }
                        onOpenModels()
                    },
                    onRestart: {
                        isStatusPresented = false
                        onRestart()
                    },
                    onFreeMemory: {
                        isStatusPresented = false
                        onFreeMemory()
                    }
                )
            }
            .accessibilityIdentifier("composer.modelStatus")
        }
        .frame(height: MLXtraDesignSystem.Icon.composerButton)
        .background(
            Capsule()
                .fill(MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
        )
        .overlay {
            Capsule()
                .stroke(borderColor, lineWidth: MLXtraDesignSystem.Spacing.hairline)
        }
        .overlay(alignment: .bottom) {
            if showsLoadingLine {
                ZStack {
                    ComposerModelLoadProgressLine(progress: status.loadProgress)
                    Text("Model loading")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(height: 2)
                        .accessibilityLabel("Model loading")
                        .accessibilityIdentifier("composer.modelLoadingIndicator")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 1)
            }
        }
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.modelControl")
        .onAppear {
            downloadManager.refreshStatuses()
        }
    }

    private var compactModelTitle: String {
        if let progress = status.loadProgress {
            return progress.compactTitle(modelName: profile.name)
        }

        if isLoading {
            return "Loading \(profile.name.split(separator: " ").first.map(String.init) ?? "model")"
        }

        return profile.name
    }

    private var statusIconTint: Color {
        switch status.state {
        case .ready, .idle, .memoryFreed:
            return MLXtraDesignSystem.Palette.secondaryLabel
        default:
            return status.tone.color
        }
    }

    private var borderColor: Color {
        isLoading ? Color.accentColor.opacity(0.20) : MLXtraDesignSystem.Surface.quietHairline
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(MLXtraDesignSystem.Surface.quietHairline)
            .frame(width: MLXtraDesignSystem.Spacing.hairline, height: 18)
    }
}

private struct ComposerModelLoadProgressLine: View {
    let progress: ModelLoadProgress?
    @State private var indeterminateOffset: CGFloat = -0.35

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.14))

                if let fraction = progress?.fractionCompleted {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.82))
                        .frame(width: max(2, width * fraction))
                } else {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.82))
                        .frame(width: max(26, width * 0.30))
                        .offset(x: width * indeterminateOffset)
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .onAppear {
            guard progress?.fractionCompleted == nil else { return }
            indeterminateOffset = -0.35
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: false)) {
                indeterminateOffset = 1.05
            }
        }
    }
}

private struct ComposerModelPickerPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var downloadManager: ModelDownloadManager
    @Binding var isPresented: Bool

    private var readyProfiles: [ModelCapabilityProfile] {
        compatibleProfiles.filter { profile in
            downloadManager.state(for: profile.downloadableModel) == .downloaded
        }
    }

    private var compatibleProfiles: [ModelCapabilityProfile] {
        viewModel.availableProfilesForCurrentMode.filter { $0.isRuntimeCompatible() }
    }

    private var hasResolvedModelStates: Bool {
        compatibleProfiles.allSatisfy { profile in
            downloadManager.states[profile.downloadableModel.id] != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if readyProfiles.isEmpty {
                Text(hasResolvedModelStates ? "No ready models" : "Checking ready models")
                    .font(MLXtraDesignSystem.Typography.captionMedium)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("composer.modelPicker.empty")
            } else {
                ForEach(readyProfiles) { profile in
                    ComposerModelProfileRow(
                        profile: profile,
                        isSelected: viewModel.isModelProfileSelected(profile),
                        action: {
                            viewModel.selectModelProfile(profile)
                            downloadManager.refreshStatuses()
                            isPresented = false
                        }
                    )
                }
            }
        }
        .padding(.vertical, 6)
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.popover)
        .shadow(
            color: Color.black.opacity(MLXtraDesignSystem.Elevation.popoverShadowOpacity),
            radius: MLXtraDesignSystem.Elevation.popoverShadowRadius,
            x: 0,
            y: MLXtraDesignSystem.Elevation.popoverShadowY
        )
        .onAppear {
            downloadManager.refreshStatuses()
        }
    }
}

private struct ComposerModelProfileRow: View {
    let profile: ModelCapabilityProfile
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: profile.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : MLXtraDesignSystem.Palette.secondaryLabel)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(MLXtraDesignSystem.Typography.compactBodyMedium)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(profile.subtitle)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? MLXtraDesignSystem.Surface.hoverFill : Color.clear)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityIdentifier("composer.modelProfile.\(profile.modelId.accessibilityIdentifierComponent)")
    }
}

private extension String {
    var accessibilityIdentifierComponent: String {
        lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }
}

private extension LocalEngineStatus.Tone {
    var color: Color {
        switch self {
        case .neutral:
            return .secondary
        case .accent:
            return .accentColor
        case .success:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }
}

struct ToolSelectorInline: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @State private var isShowingPopover = false

    private var isActive: Bool {
        viewModel.selectedTool != .auto
    }

    var body: some View {
        Button(action: {
            isShowingPopover.toggle()
        }) {
            HStack(spacing: 6) {
                Image(systemName: viewModel.selectedTool.icon)
                    .font(.system(size: MLXtraDesignSystem.Icon.regular))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(viewModel.selectedTool.rawValue)
                    .font(MLXtraDesignSystem.Typography.compactBody)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: MLXtraDesignSystem.Icon.micro))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
                    .overlay(
                        Capsule()
                            .stroke(isActive ? Color.accentColor.opacity(0.18) : MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isInputDisabled)
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            ToolSelectorPopover(
                viewModel: viewModel,
                downloadManager: downloadManager,
                isPresented: $isShowingPopover
            )
            .frame(width: 300)
        }
        .onAppear {
            downloadManager.refreshStatuses()
        }
        .fixedSize()
        .accessibilityIdentifier("toolbar.modelSelector")
        .accessibilityIdentifier("composer.toolSelector")
    }
}

struct ToolSelectorPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var downloadManager: ModelDownloadManager
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Tool.allCases, id: \.id) { tool in
                ToolRow(
                    tool: tool,
                    isSelected: viewModel.selectedTool == tool,
                    state: viewModel.downloadRequirement(for: tool).map { downloadManager.state(for: $0) },
                    action: {
                        viewModel.selectTool(tool)
                        downloadManager.refreshStatuses()
                        isPresented = false
                    }
                )
            }
        }
        .padding(.vertical, 6)
        .designPanelSurface(cornerRadius: 14)
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 4)
    }
}

struct ToolRow: View {
    let tool: Tool
    let isSelected: Bool
    let state: ModelDownloadManager.DownloadState?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.rawValue)
                        .font(MLXtraDesignSystem.Typography.compactBodyMedium)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(tool.subtitle)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    readinessBadge

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? MLXtraDesignSystem.Surface.hoverFill : Color.clear)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityIdentifier("tool.\(tool.id)")
    }

    @ViewBuilder
    private var readinessBadge: some View {
        switch state {
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(MLXtraDesignSystem.Palette.secondaryLabel)
                .labelStyle(.titleAndIcon)
        case .downloading:
            Label("Loading", systemImage: "arrow.down.circle.fill")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(Color.accentColor)
                .labelStyle(.titleAndIcon)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(Color.orange)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            let failedState = ModelDownloadManager.DownloadState.failed(message)
            Label(failedState.failureBadgeTitle, systemImage: failedState.failureBadgeIcon)
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(failedState.failureBadgeTint)
                .labelStyle(.titleAndIcon)
        case .notDownloaded:
            Label("Missing", systemImage: "arrow.down.circle")
                .font(MLXtraDesignSystem.Typography.microMedium)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case nil:
            EmptyView()
        }
    }
}

private struct ModelParameterPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showAdvanced = false
    private let explicitProfile: ModelCapabilityProfile?

    init(viewModel: ChatViewModel, profile: ModelCapabilityProfile? = nil) {
        self.viewModel = viewModel
        self.explicitProfile = profile
    }

    private var profile: ModelCapabilityProfile {
        explicitProfile ?? viewModel.activeModelProfile
    }

    private var basicParameters: [ModelParameterDefinition] {
        profile.parameters.filter { !$0.isAdvanced }
    }

    private var advancedParameters: [ModelParameterDefinition] {
        profile.parameters.filter(\.isAdvanced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: profile.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text(profile.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if !basicParameters.isEmpty {
                VStack(spacing: 10) {
                    ForEach(basicParameters) { parameter in
                        ParameterControl(
                            definition: parameter,
                            value: viewModel.parameterValue(for: profile, key: parameter.key),
                            onChange: { value in
                                viewModel.setParameterValue(value, for: parameter, profile: profile)
                            }
                        )
                    }
                }
            }

            if !advancedParameters.isEmpty {
                ClickableDisclosureSection(isExpanded: $showAdvanced) {
                    VStack(spacing: 10) {
                        ForEach(advancedParameters) { parameter in
                            ParameterControl(
                                definition: parameter,
                                value: viewModel.parameterValue(for: profile, key: parameter.key),
                                onChange: { value in
                                    viewModel.setParameterValue(value, for: parameter, profile: profile)
                                }
                            )
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced")
                        .font(.caption.weight(.semibold))
                }
            }

            Divider()

            HStack {
                Menu {
                    ForEach(profile.presets) { preset in
                        Button(preset.label) {
                            viewModel.applyParameterPreset(preset, to: profile)
                        }
                    }
                } label: {
                    Text("Use preset")
                }
                .menuStyle(.borderlessButton)
                .disabled(profile.presets.isEmpty)

                Spacer()

                Button("Reset") {
                    viewModel.resetParameters(for: profile)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
    }
}

private struct ParameterControl: View {
    let definition: ModelParameterDefinition
    let value: String
    let onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(definition.label)
                    .font(.caption.weight(.medium))
                Spacer()
                if definition.type == .decimal || definition.type == .integer {
                    Text(displayValue)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            control
        }
    }

    @ViewBuilder
    private var control: some View {
        switch definition.type {
        case .decimal, .integer:
            TicklessParameterSlider(
                value: Binding(
                    get: { Double(value) ?? Double(definition.defaultValue) ?? 0 },
                    set: { onChange(definition.clampedString($0)) }
                ),
                in: definition.range ?? 0...1,
                step: definition.step
            )
            .frame(height: 16)
        case .boolean:
            Toggle(
                "",
                isOn: Binding(
                    get: { value == "true" },
                    set: { onChange($0 ? "true" : "false") }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
        case .option:
            Picker(definition.label, selection: Binding(
                get: { value },
                set: { newValue in onChange(newValue) }
            )) {
                ForEach(definition.options, id: \.self) { option in
                    Text(option.isEmpty ? "Auto" : option.capitalized).tag(option)
                }
            }
            .pickerStyle(.menu)
        case .text:
            TextField(definition.defaultValue, text: Binding(
                get: { value },
                set: { newValue in onChange(newValue) }
            ))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var displayValue: String {
        value.isEmpty ? "Auto" : value
    }
}

private struct TicklessParameterSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        self._value = value
        self.range = range
        self.step = step
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.controlSize = .small
        slider.focusRingType = .none
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        nsView.numberOfTickMarks = 0
        nsView.allowsTickMarkValuesOnly = false
        nsView.isEnabled = context.environment.isEnabled

        let clampedValue = Self.clamped(value, in: range)
        if abs(nsView.doubleValue - clampedValue) > 0.000_001 {
            nsView.doubleValue = clampedValue
        }
        context.coordinator.value = $value
        context.coordinator.range = range
        context.coordinator.step = step
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, range: range, step: step)
    }

    private static func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>
        var range: ClosedRange<Double>
        var step: Double

        init(value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
            self.value = value
            self.range = range
            self.step = step
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let steppedValue = Self.rounded(sender.doubleValue, range: range, step: step)
            if abs(sender.doubleValue - steppedValue) > 0.000_001 {
                sender.doubleValue = steppedValue
            }
            value.wrappedValue = steppedValue
        }

        private static func rounded(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
            let clampedValue = TicklessParameterSlider.clamped(value, in: range)
            guard step > 0 else { return clampedValue }
            let steps = ((clampedValue - range.lowerBound) / step).rounded()
            return TicklessParameterSlider.clamped(range.lowerBound + steps * step, in: range)
        }
    }
}

struct ImageThumbnailView: View {
    let imageURL: URL
    let filename: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: {}) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: ImageCache.shared.image(for: imageURL) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
                    .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 80, height: 60)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(filename)
    }
}

struct MultilineTextInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFocused: Bool
    var isEditable: Bool = true
    var focusRequest: Int = 0
    var onPasteImages: () -> Bool = { false }
    var submitsOnReturn: Bool = true
    var accessibilityIdentifier: String = "composer.input"
    var accessibilityLabel: String = "Composer input"
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        let textView = ComposerTextView()
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.delegate = context.coordinator
        textView.font = MLXtraDesignSystem.Typography.nativeComposerInputFont()
        textView.placeholder = placeholder
        textView.isRichText = false
        textView.isSelectable = true
        textView.isEditable = isEditable
        textView.backgroundColor = NSColor.clear
        textView.drawsBackground = false
        textView.textColor = NSColor.labelColor
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(
            width: 0,
            height: MLXtraDesignSystem.Layout.composerTextContainerInset
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = nsView.documentView as? NSTextView else { return }
        if let composerTextView = textView as? ComposerTextView {
            composerTextView.placeholder = placeholder
        }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        textView.isEditable = isEditable
        textView.textColor = isEditable ? NSColor.labelColor : NSColor.secondaryLabelColor
        textView.font = MLXtraDesignSystem.Typography.nativeComposerInputFont()

        if isEditable, context.coordinator.consumeFocusRequest(focusRequest) {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextInput
        var textView: NSTextView?
        private var lastFocusRequest: Int

        init(_ parent: MultilineTextInput) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }

        func consumeFocusRequest(_ request: Int) -> Bool {
            guard request != lastFocusRequest else { return false }
            lastFocusRequest = request
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            syncText(from: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                syncText(from: textView)
            }
            parent.isFocused = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard parent.isEditable else { return false }

            if commandSelector == #selector(NSText.paste(_:)) {
                return parent.onPasteImages()
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                if !parent.submitsOnReturn || event?.modifierFlags.contains(.shift) == true {
                    textView.insertNewline(nil)
                    return true
                } else {
                    syncText(from: textView)
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }

        private func syncText(from textView: NSTextView) {
            if parent.text != textView.string {
                parent.text = textView.string
            }
            textView.needsDisplay = true
        }
    }
}

private final class ComposerTextView: NSTextView {
    var placeholder: String = "" {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }
        let placeholderFont = font ?? MLXtraDesignSystem.Typography.nativeComposerInputFont()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: placeholderFont,
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: paragraphStyle
        ]
        let origin = textContainerOrigin
        let caretGap = MLXtraDesignSystem.Layout.composerPlaceholderCaretGap
        let rect = NSRect(
            x: origin.x + caretGap,
            y: origin.y,
            width: max(bounds.width - origin.x - caretGap, 0),
            height: ceil(placeholderFont.ascender - placeholderFont.descender + placeholderFont.leading) + 2
        )
        placeholder.draw(in: rect, withAttributes: attributes)
    }
}

private func fileURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL {
        return url
    }

    if let data = item as? Data {
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    if let string = item as? String {
        return URL(string: string)
    }

    return nil
}

private func isSupportedImageURL(_ url: URL) -> Bool {
    guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
        return false
    }

    return type.conforms(to: .image)
}

private func saveTemporaryImage(_ image: NSImage) -> URL? {
    guard let data = image.pngData else { return nil }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MLXtra", isDirectory: true)
        .appendingPathComponent("PastedImages", isDirectory: true)
    let url = directory.appendingPathComponent("\(UUID().uuidString).png")

    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    } catch {
        print("Failed to save pasted image: \(error)")
        return nil
    }
}

private extension ModelDownloadManager.DownloadState {
    var failureBadgeTitle: String {
        isRepairableFailure ? "Repair" : "Failed"
    }

    var failureBadgeIcon: String {
        isRepairableFailure ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill"
    }

    var failureBadgeTint: Color {
        isRepairableFailure ? .orange : .red
    }
}

private extension NSImage {
    var pngData: Data? {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
