import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var isTextInputFocused = false
    @State private var isDropTargeted = false

    private var borderIsActive: Bool {
        viewModel.isGenerating || isTextInputFocused || isDropTargeted
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
                    viewModel.sendMessage()
                }
            )

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
            .help("Attach file")

            ToolSelectorInline(viewModel: viewModel)

            Spacer()

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
                ModelSelectorInline(viewModel: viewModel)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        openPanel.message = "Select images to attach"
        openPanel.prompt = "Attach"

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
                    .font(.system(size: 13))
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
            ToolSelectorPopover(viewModel: viewModel, isPresented: $isShowingPopover)
                .frame(width: 240)
        }
        .fixedSize()
    }
}

struct ToolSelectorPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Tool.allCases, id: \.id) { tool in
                ToolRow(
                    tool: tool,
                    isSelected: viewModel.selectedTool == tool,
                    action: {
                        viewModel.selectTool(tool)
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
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.rawValue)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(tool.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
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
}

struct ModelSelectorInline: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        Menu {
            ForEach(AIModel.allCases, id: \.id) { model in
                Button(action: {
                    viewModel.selectModel(model)
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 13))
                            Text(model.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.selectedModel == model {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedModel.displayName)
                    .font(.system(size: 13))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
