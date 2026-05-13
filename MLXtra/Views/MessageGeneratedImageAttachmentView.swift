import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func copyGeneratedImageFile(from sourceURL: URL, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    let temporaryURL = destinationURL
        .deletingLastPathComponent()
        .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")

    defer {
        try? fileManager.removeItem(at: temporaryURL)
    }

    try fileManager.copyItem(at: sourceURL, to: temporaryURL)
    if fileManager.fileExists(atPath: destinationURL.path) {
        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
    } else {
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
}

struct UserMessageContent: View {
    let message: Message
    let isStreaming: Bool
    let cursorVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.imageURLs.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(message.imageURLs, id: \.self) { imageURL in
                        SentImageAttachmentView(imageURL: imageURL)
                    }
                }
                .frame(maxWidth: 300, alignment: .leading)
            }

            if !message.content.isEmpty || isStreaming {
                Text(message.content + (isStreaming && cursorVisible ? "▊" : ""))
                    .font(MLXtraDesignSystem.Typography.messageBody)
                    .lineSpacing(4)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
#if DEBUG
        .overlay {
            if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
                Color.primary.opacity(0.001)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("User message bubble")
                    .accessibilityIdentifier("message.user.bubble")
            }
        }
#endif
    }
}

struct SentImageAttachmentView: View {
    let imageURL: URL

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(nsImage: ImageCache.shared.image(for: imageURL) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 112, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )

            Text(imageURL.lastPathComponent)
                .font(MLXtraDesignSystem.Typography.micro)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: 112, alignment: .leading)
                .background(Color.black.opacity(0.45))
        }
        .help(imageURL.lastPathComponent)
    }
}

struct GeneratedImageAttachmentView: View {
    let imageURL: URL
    @State private var downloadError: String?
    @State private var showLightbox = false
    private let controlButtonSize: CGFloat = MLXtraDesignSystem.Icon.mediaActionButton

    private var loadedImage: NSImage? {
        ImageCache.shared.image(for: imageURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.media, style: .continuous)
                    .fill(Color.primary.opacity(0.035))

                if let loadedImage {
                    Image(nsImage: loadedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 320)
                        .padding(12)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("Image not available")
                            .font(MLXtraDesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 320)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 320)
            .contentShape(Rectangle())
            .onTapGesture {
                if loadedImage != nil {
                    showLightbox = true
                }
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generated image")
                        .font(MLXtraDesignSystem.Typography.compactBodySemibold)
                    Text(imageURL.lastPathComponent)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button(action: revealImage) {
                    Label("Reveal", systemImage: "folder")
                        .labelStyle(.iconOnly)
                        .font(.system(size: MLXtraDesignSystem.Icon.regular, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(
                            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                Button(action: downloadImage) {
                    Label("Download", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.system(size: MLXtraDesignSystem.Icon.regular, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(
                            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                }
                .buttonStyle(.plain)
                .help("Download image")
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .designContentSurface(cornerRadius: MLXtraDesignSystem.Radius.media)
        .help(imageURL.lastPathComponent)
        .accessibilityIdentifier("generated.image")
        .accessibilityValue(imageURL.path)
        .contextMenu {
            Button("Open Image", action: { showLightbox = true })
            Button("Reveal in Finder", action: revealImage)
            Button("Download Image", action: downloadImage)
        }
        .alert("Download failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "Unable to save the image.")
        }
        .onChange(of: showLightbox) { _, show in
            if show {
                ImageLightboxWindowController.show(imageURL: imageURL, onClose: { showLightbox = false })
            }
        }
    }

    private func downloadImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: imageURL.pathExtension) ?? .png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = imageURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            do {
                try copyGeneratedImageFile(from: imageURL, to: destinationURL)
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private func revealImage() {
        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
    }
}

struct ImageLightboxView: View {
    let imageURL: URL
    let onClose: () -> Void
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var downloadError: String?

    private var loadedImage: NSImage? {
        ImageCache.shared.image(for: imageURL)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                let newScale = lastScale * value.magnification
                                scale = min(max(newScale, 1), 5)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.0 {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1.0 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if scale > 1.0 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Image not available")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            VStack {
                HStack {
                    Spacer()

                    HStack(spacing: 12) {
                        if scale > 1.0 {
                            Button(action: resetZoom) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }

                        Button(action: revealImage) {
                            Image(systemName: "folder")
                                .font(.system(size: 14, weight: .medium))
                        }

                        Button(action: downloadImage) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 14, weight: .medium))
                        }

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(20)

                Spacer()

                HStack {
                    Text(imageURL.lastPathComponent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    if let loadedImage {
                        Text("\(Int(loadedImage.size.width))×\(Int(loadedImage.size.height))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Text("Double-click to zoom · Pinch to scale")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .keyboardShortcut(KeyEquivalent.escape, modifiers: [])
        .alert("Could not save image", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "Unable to save the image.")
        }
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.25)) {
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }

    private func downloadImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: imageURL.pathExtension) ?? .png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = imageURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            do {
                try copyGeneratedImageFile(from: imageURL, to: destinationURL)
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private func revealImage() {
        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
    }
}

private final class LightboxWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class ImageLightboxWindowController {
    private static var activeWindow: LightboxWindow?

    static func show(imageURL: URL, onClose: @escaping () -> Void) {
        close()

        guard let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            DispatchQueue.main.async { onClose() }
            return
        }
        let window = LightboxWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.isReleasedWhenClosed = false
        window.onCancel = {
            close()
            DispatchQueue.main.async { onClose() }
        }

        let hostingView = NSHostingView(
            rootView: ImageLightboxView(imageURL: imageURL, onClose: {
                close()
                DispatchQueue.main.async { onClose() }
            })
        )
        hostingView.frame = window.contentView?.bounds ?? screen.visibleFrame
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        window.makeKeyAndOrderFront(nil)
        activeWindow = window
    }

    static func close() {
        activeWindow?.close()
        activeWindow = nil
    }
}

// MARK: - AI Content View with Markdown
