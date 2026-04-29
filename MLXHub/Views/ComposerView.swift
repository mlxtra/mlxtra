import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @ObservedObject var viewModel: ChatViewModel
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
        VStack(spacing: 0) {
            attachmentTray
            textInput
            modeDraftControls
            Divider().padding(.horizontal, 18)
            footerControls
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(NSColor.shadowColor).opacity(0.2), radius: 16, x: 0, y: 4)
        .overlay(composerBorder)
        .animation(.easeInOut(duration: 0.18), value: borderIsActive)
        .onDrop(of: acceptedDropTypes, isTargeted: $isDropTargeted, perform: handleImageDrop)
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
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, -8)
        }
    }

    private var textInput: some View {
        ZStack(alignment: .topLeading) {
            MultilineTextInput(
                text: $viewModel.inputText,
                isFocused: $isTextInputFocused,
                isEditable: !viewModel.isInputDisabled,
                onPasteImages: handlePasteboardImages,
                onSubmit: {
                    viewModel.performComposerPrimaryAction()
                }
            )

            if viewModel.inputText.isEmpty {
                Text(viewModel.composerPlaceholder)
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: viewModel.hasSelectedImages ? 20 : 32, maxHeight: 80)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .overlay(alignment: .center) {
            if isDropTargeted {
                Text("Drop images to attach")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
    }

    private var footerControls: some View {
        HStack(spacing: 8) {
            Button(action: showFilePicker) {
                Image(systemName: "paperclip")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(attachmentHelp)

            ToolSelectorInline(viewModel: viewModel)

            Spacer()

            if viewModel.localEngineStatus.isVisibleInComposer {
                LocalEngineStatusPill(
                    status: viewModel.localEngineStatus,
                    canFreeMemory: viewModel.canFreeLocalEngineMemory,
                    onOpenModels: { openSettings() },
                    onRestart: viewModel.restartLocalEngine,
                    onFreeMemory: viewModel.freeLocalEngineMemory
                )
            }

            if viewModel.isGenerating {
                Button(action: {
                    viewModel.cancelGeneration()
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color(NSColor.controlColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                ModelParameterButton(viewModel: viewModel)
                ModelSelectorInline(viewModel: viewModel)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            viewModel.refreshLocalEngineDownloadStatus()
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
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var composerBorder: some View {
        if viewModel.isGenerating {
            AnimatedComposerBorder(cornerRadius: 24)
        } else {
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    borderIsActive ? Color.primary.opacity(0.18) : Color(NSColor.separatorColor).opacity(0.5),
                    lineWidth: borderIsActive ? 1.5 : 1
                )
        }
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
                !promptIsEmpty
                    || !lyricsAreEmpty
                    || viewModel.isMusicLyricsEditorVisible
                    || viewModel.musicComposerPrompt == .needsLyrics
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.showsMusicControls {
                musicSetupRow
            }

            ForEach(draft.slots) { slot in
                ComposerDraftSlotRow(slot: slot) { action in
                    perform(slotAction: action)
                }
            }

            if shouldShowLyricsEditor {
                lyricsEditor
            }
        }
    }

    private var musicSetupRow: some View {
        HStack(spacing: 10) {
            Text("Vocals")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: vocalModeBinding) {
                ForEach(MusicVocalMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            Spacer(minLength: 0)

            if shouldShowLyricsEditor {
                Button {
                    viewModel.rewriteMusicLyrics()
                } label: {
                    Label(lyricsButtonTitle, systemImage: "pencil.and.sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(promptIsEmpty || viewModel.isDraftingMusicLyrics)
            }
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
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.musicLyricsText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 78, maxHeight: 110)

                if viewModel.musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Paste lyrics here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor).opacity(0.55), lineWidth: 1)
            }
        }
    }

    private var lyricsButtonTitle: String {
        if viewModel.isDraftingMusicLyrics {
            return "Generating..."
        }
        return lyricsAreEmpty ? "Generate from idea" : "Regenerate"
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
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(.system(size: 12, weight: .semibold))

                if let subtitle = slot.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
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
            return Color(NSColor.controlColor).opacity(0.48)
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
            HStack(spacing: title == nil ? 0 : 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                if let title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .frame(width: title == nil ? 36 : nil, height: 34)
            .padding(.horizontal, title == nil ? 0 : 12)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.65))
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 1)
                    }
            }
            .shadow(
                color: shadowColor,
                radius: isEnabled ? (isHovered ? 10 : 7) : 0,
                x: 0,
                y: isHovered ? 4 : 2
            )
            .fixedSize(horizontal: title != nil, vertical: false)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? help : disabledHelp)
        .accessibilityLabel(help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var background: AnyShapeStyle {
        if isEnabled {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.accentColor,
                        Color(red: 0.10, green: 0.47, blue: 0.96)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(Color(NSColor.controlColor).opacity(0.7))
    }

    private var borderColor: Color {
        isEnabled ? Color.white.opacity(0.18) : Color(NSColor.separatorColor).opacity(0.28)
    }

    private var shadowColor: Color {
        isEnabled ? Color.accentColor.opacity(0.22) : Color.clear
    }
}

private struct LocalEngineStatusPill: View {
    let status: LocalEngineStatus
    let canFreeMemory: Bool
    let onOpenModels: () -> Void
    let onRestart: () -> Void
    let onFreeMemory: () -> Void

    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 12, weight: .semibold))

                Text(compactTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(tint.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.20), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(status.detail)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            LocalEngineStatusPopover(
                status: status,
                canFreeMemory: canFreeMemory,
                onOpenModels: {
                    isPresented = false
                    if let modelId = status.primaryActionModelId {
                        pendingDownloadModelId = modelId
                    }
                    onOpenModels()
                },
                onRestart: {
                    isPresented = false
                    onRestart()
                },
                onFreeMemory: {
                    isPresented = false
                    onFreeMemory()
                }
            )
        }
    }

    private var tint: Color {
        status.tone.color
    }

    private var compactTitle: String {
        switch status.state {
        case .ready:
            return "Ready"
        case .needsDownload:
            return "Download needed"
        case .memoryFreed:
            return "Unloaded"
        default:
            return status.title
        }
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
                    .foregroundStyle(status.tone.color)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(status.title)
                        .font(.system(size: 14, weight: .semibold))

                    Text(status.detail)
                        .font(.system(size: 12))
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
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
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

struct AnimatedComposerBorder: View {
    let cornerRadius: CGFloat
    @State private var rotation = Angle.degrees(0)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(animatedGradient(opacity: 0.44), lineWidth: 10)
                .blur(radius: 14)
                .padding(-7)

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(animatedGradient(opacity: 0.38), lineWidth: 5)
                .blur(radius: 5)
                .padding(-2)

            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.white.opacity(0.64), lineWidth: 1.2)

            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(animatedGradient(opacity: 0.24), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 6.0).repeatForever(autoreverses: false)) {
                rotation = .degrees(360)
            }
        }
    }

    private func animatedGradient(opacity: Double) -> AngularGradient {
        AngularGradient(
            colors: [
                Color(red: 1.00, green: 0.48, blue: 0.82).opacity(opacity),
                Color(red: 0.72, green: 0.58, blue: 1.00).opacity(opacity * 0.85),
                Color(red: 0.44, green: 0.88, blue: 1.00).opacity(opacity),
                Color(red: 0.82, green: 0.96, blue: 0.80).opacity(opacity * 0.72),
                Color(red: 1.00, green: 0.80, blue: 0.58).opacity(opacity * 0.82),
                Color(red: 1.00, green: 0.48, blue: 0.82).opacity(opacity)
            ],
            center: .center,
            angle: rotation
        )
    }
}

struct ToolSelectorInline: View {
    @ObservedObject var viewModel: ChatViewModel
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
                    .font(.system(size: 14))
                Text(viewModel.selectedTool.rawValue)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color(NSColor.controlColor))
                    .overlay(
                        Capsule()
                            .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.1), radius: 16, x: 0, y: 4)
        )
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(tool.subtitle)
                        .font(.system(size: 11))
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
        .background(isHovered ? Color(NSColor.selectedControlColor).opacity(0.1) : Color.clear)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var readinessBadge: some View {
        switch state {
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.green)
                .labelStyle(.titleAndIcon)
        case .downloading:
            Label("Loading", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .labelStyle(.titleAndIcon)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label("Retry", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.red)
                .labelStyle(.titleAndIcon)
        case .notDownloaded:
            Label("Missing", systemImage: "arrow.down.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case nil:
            EmptyView()
        }
    }
}

struct ModelSelectorInline: View {
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var downloadManager = ModelDownloadManager.shared

    var body: some View {
        Menu {
            ForEach(viewModel.availableProfilesForCurrentMode) { profile in
                Button(action: {
                    viewModel.selectModelProfile(profile)
                }) {
                    HStack {
                        Image(systemName: profile.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.system(size: 13))
                            Text(profile.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 5) {
                            modelBadges(for: profile)
                        }

                        if viewModel.isModelProfileSelected(profile) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.activeModelProfile.name)
                    .font(.system(size: 13))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .onAppear {
            downloadManager.refreshStatuses()
        }
        .fixedSize()
    }

    @ViewBuilder
    private func modelBadges(for profile: ModelCapabilityProfile) -> some View {
        let fit = profile.fit()
        Label(fit.shortTitle, systemImage: fit.systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fit.tint)
            .labelStyle(.titleAndIcon)

        switch downloadManager.state(for: profile.downloadableModel) {
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.green)
                .labelStyle(.titleAndIcon)
        case .downloading:
            Label("Loading", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .labelStyle(.titleAndIcon)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label("Retry", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.red)
                .labelStyle(.titleAndIcon)
        case .notDownloaded:
            Label("Missing", systemImage: "arrow.down.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }
}

private struct ModelParameterButton: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Model settings")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelParameterPopover(viewModel: viewModel)
                .frame(width: 320)
        }
    }
}

private struct ModelParameterPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showAdvanced = false

    private var profile: ModelCapabilityProfile {
        viewModel.activeModelProfile
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
                    Text(profile.fit().title)
                        .font(.caption)
                        .foregroundStyle(profile.fit().tint)
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
                DisclosureGroup(isExpanded: $showAdvanced) {
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
        .background(Color(NSColor.controlBackgroundColor))
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
            Slider(
                value: Binding(
                    get: { Double(value) ?? Double(definition.defaultValue) ?? 0 },
                    set: { onChange(definition.clampedString($0)) }
                ),
                in: definition.range ?? 0...1,
                step: definition.step
            )
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

struct ImageThumbnailView: View {
    let imageURL: URL
    let filename: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: {}) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSImage(contentsOf: imageURL) ?? NSImage())
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
    @Binding var isFocused: Bool
    var isEditable: Bool = true
    var onPasteImages: () -> Bool = { false }
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.isRichText = false
        textView.isSelectable = true
        textView.isEditable = isEditable
        textView.backgroundColor = NSColor.clear
        textView.textColor = NSColor.labelColor
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 6)
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
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.textColor = isEditable ? NSColor.labelColor : NSColor.secondaryLabelColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextInput
        var textView: NSTextView?

        init(_ parent: MultilineTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard parent.isEditable else { return false }

            if commandSelector == #selector(NSText.paste(_:)) {
                return parent.onPasteImages()
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                if event?.modifierFlags.contains(.shift) == true {
                    textView.insertNewline(nil)
                    return true
                } else {
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
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
        .appendingPathComponent("MLXHub", isDirectory: true)
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
