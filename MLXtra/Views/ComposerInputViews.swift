import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageThumbnailView: View {
    let imageURL: URL
    let filename: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: {}) {
            ZStack(alignment: .topTrailing) {
                AsyncCachedImage(url: imageURL) { image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 80, height: 60)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                }

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
        scrollView.setAccessibilityIdentifier("\(accessibilityIdentifier).scrollView")
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

func fileURL(from item: NSSecureCoding?) -> URL? {
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

func isSupportedImageURL(_ url: URL) -> Bool {
    guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
        return false
    }

    return type.conforms(to: .image)
}

func saveTemporaryImage(_ image: NSImage) async -> URL? {
    await Task.detached(priority: .utility) {
        guard let data = image.pngData else { return nil }
        return writeTemporaryPNGData(data)
    }.value
}

func saveTemporaryImageData(_ imageData: Data?) async -> URL? {
    await Task.detached(priority: .utility) {
        guard
            let imageData,
            let image = NSImage(data: imageData),
            let data = image.pngData
        else {
            return nil
        }

        return writeTemporaryPNGData(data)
    }.value
}

private func writeTemporaryPNGData(_ data: Data) -> URL? {
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
