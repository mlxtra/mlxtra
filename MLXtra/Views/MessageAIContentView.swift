import AppKit
import Combine
import SwiftUI

struct AIContentView: View {
    let content: String
    let isStreaming: Bool
    let cursorVisible: Bool
    let onCopy: () -> Void
    let onOpenModels: (() -> Void)?
    let onRestartLocalEngine: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let recoveryNotice = RecoveryNotice(content: content), !isStreaming {
                RecoveryNoticeView(
                    notice: recoveryNotice,
                    onOpenModels: onOpenModels,
                    onRestartLocalEngine: onRestartLocalEngine
                )
            } else {
                if let mainContent = ReasoningContentFilter.visibleText(from: content), !mainContent.isEmpty {
                    if isStreaming {
                        StreamingPlainTextView(text: mainContent + (isStreaming && cursorVisible ? "▊" : ""))
                    } else if AIContentRenderingPolicy.shouldUseFastPlainText(for: mainContent) {
                        PlainAssistantTextView(text: mainContent)
                    } else {
                        MarkdownTextView(
                            text: mainContent,
                            isStreaming: false
                        )
                    }
                }
            }
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlainAssistantTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(MLXtraDesignSystem.Typography.messageBody)
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("message.assistant.plainText")
    }
}

enum AIContentRenderingPolicy {
    static func shouldUseFastPlainText(for content: String) -> Bool {

        let hasHeading = content.contains("\n# ") || content.hasPrefix("# ")
        let hasParagraphBreak = containsParagraphBreak(content)
        let hasBold = content.contains("**")
        let hasItalic = content.contains("*") && hasItalicPair(content)
        let hasCodeBlock = content.contains("```")
        let hasUnorderedList = content.contains("\n- ") || content.hasPrefix("- ")
            || content.contains("\n* ") || content.hasPrefix("* ")
            || content.contains("\n+ ") || content.hasPrefix("+ ")
        let hasOrderedList = hasOrderedListPrefix(content)
        let hasTable = content.contains("|") && hasTableSeparator(content)
        let hasBlockquote = content.contains("\n> ") || content.hasPrefix("> ")
        let hasMath = content.contains("$$") || content.contains("\\[")
        let hasLink = content.contains("](")
        return !hasHeading && !hasParagraphBreak && !hasBold && !hasItalic && !hasCodeBlock
            && !hasUnorderedList && !hasOrderedList && !hasTable
            && !hasBlockquote && !hasMath && !hasLink
    }

    private static func containsParagraphBreak(_ text: String) -> Bool {
        var sawNewline = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                if sawNewline { return true }
                sawNewline = true
            } else if sawNewline, !character.isWhitespace {
                sawNewline = false
            }
            index = text.index(after: index)
        }
        return false
    }

    private static func hasItalicPair(_ text: String) -> Bool {
        var openSingleStar = false
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "*" else {
                index = text.index(after: index)
                continue
            }

            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "*" {
                index = text.index(after: next)
                continue
            }

            if openSingleStar { return true }
            openSingleStar = true
            index = next
        }
        return false
    }

    private static func hasOrderedListPrefix(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmed = line.trimmingPrefix(while: { $0 == " " })
            guard let markerEnd = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else {
                continue
            }
            if let num = Int(trimmed[..<markerEnd]), num > 0, markerEnd < trimmed.endIndex {
                let next = trimmed[trimmed.index(after: markerEnd)]
                if next == " " { return true }
            }
        }
        return false
    }

    private static func hasTableSeparator(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") && s.hasSuffix("|") && s.contains("-") {
                let inner = s.dropFirst().dropLast()
                let parts = inner.split(separator: "|")
                if parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).allSatisfy({ ch in ch == "-" || ch == ":" || ch == " " }) }) {
                    return true
                }
            }
        }
        return false
    }
}

private struct StreamingPlainTextView: View {
    let text: String

    var body: some View {
        FastStreamingTextView(text: text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
    }
}

struct StreamingAIContentView: View {
    let streamingContent: StreamingMessageContent
    let onOpenModels: (() -> Void)?
    let onRestartLocalEngine: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FastStreamingTextView(streamingContent: streamingContent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FastStreamingTextView: NSViewRepresentable {
    private let text: String?
    private let streamingContent: StreamingMessageContent?

    init(text: String) {
        self.text = text
        self.streamingContent = nil
    }

    init(streamingContent: StreamingMessageContent) {
        self.text = nil
        self.streamingContent = streamingContent
    }

    func makeNSView(context: Context) -> FastStreamingTextNativeView {
        FastStreamingTextNativeView()
    }

    func updateNSView(_ nsView: FastStreamingTextNativeView, context: Context) {
        if let streamingContent {
            nsView.bind(to: streamingContent)
        } else {
            nsView.updateStaticText(text ?? "")
        }
    }

    static func dismantleNSView(_ nsView: FastStreamingTextNativeView, coordinator: ()) {
        nsView.unbindStreamingContent()
    }
}

private final class FastStreamingTextNativeView: NSView {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var currentText = ""
    private var lastMeasuredWidth: CGFloat = 0
    private var cachedHeight: CGFloat = 18
    private var appliedRevision: Int?
    private var streamingCancellable: AnyCancellable?
    private var boundStreamingContentId: UUID?
    private var lastHeightMeasurementTime = Date.distantPast

    private var lastFilterInput = ""
    private var lastFilterOutput = ""

    private let markdownState = StreamingMarkdownState()
    private let splitter = StreamingMarkdownSplitter()
    private let renderStyle = MarkdownRenderStyle.default

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTextView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTextView()
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: cachedHeight)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = max(bounds.width, 1)
        if abs(width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = width
            configureContainer(width: width)
            refreshMeasuredHeight(width: width, force: true)
        }
    }

    func bind(to streamingContent: StreamingMessageContent) {
        if boundStreamingContentId != streamingContent.id {
            unbindStreamingContent()
            boundStreamingContentId = streamingContent.id
            currentText = ""
            appliedRevision = nil
            markdownState.reset()
            textView.textStorage?.setAttributedString(NSAttributedString())
        }

        apply(streamingContent: streamingContent)

        if streamingCancellable == nil {
            streamingCancellable = streamingContent.$revision
                .dropFirst()
                .sink { [weak self, weak streamingContent] _ in
                    guard let streamingContent else { return }
                    self?.apply(streamingContent: streamingContent)
                }
        }
    }

    func unbindStreamingContent() {
        streamingCancellable?.cancel()
        streamingCancellable = nil
        boundStreamingContentId = nil
        lastFilterInput = ""
        lastFilterOutput = ""
        markdownState.reset()
    }

    func updateStaticText(_ text: String) {
        unbindStreamingContent()
        updateText(text, mutation: .replace(text), revision: nil, autoScroll: false, forceHeight: true)
    }

    private func apply(streamingContent: StreamingMessageContent) {
        let text: String
        if streamingContent.containsReasoningMarkup {
            let raw = streamingContent.text
            if raw == lastFilterInput {
                text = lastFilterOutput
            } else {
                let filtered = ReasoningContentFilter.visibleText(from: raw) ?? ""
                text = filtered
                lastFilterInput = raw
                lastFilterOutput = filtered
            }
        } else {
            text = streamingContent.text
            lastFilterInput = ""
            lastFilterOutput = ""
        }

        applySplitterBasedUpdate(
            text: text,
            revision: streamingContent.revision
        )
    }

    private func applySplitterBasedUpdate(text: String, revision: Int) {
        guard appliedRevision != revision else { return }
        appliedRevision = revision

        let result = splitter.splitStablePrefix(
            text,
            committedEndIndex: markdownState.committedEndIndex,
            committedUTF16Offset: markdownState.committedUTF16Offset
        )

        guard let storage = textView.textStorage else { return }

        // Preserve block order by removing the unstable tail before appending newly stable blocks.
        let oldTailRange = markdownState.tailRange(storageLength: storage.length)
        if oldTailRange.length > 0 {
            storage.replaceCharacters(in: oldTailRange, with: NSAttributedString())
        }

        if !result.newBlocks.isEmpty {
            let blockAttr = MarkdownAttributedRenderer.attributedString(
                from: result.newBlocks,
                style: renderStyle
            )
            MarkdownAttributedRenderer.appendBlockSeparatorIfNeeded(to: storage, style: renderStyle)
            storage.append(blockAttr)
        }

        markdownState.stableStorageEndLocation = storage.length
        markdownState.committedEndIndex = result.newCommittedEndIndex
        markdownState.committedUTF16Offset = result.newCommittedUTF16Offset

        let tailAttr = MarkdownAttributedRenderer.tailAttributedString(
            from: result.tail,
            style: renderStyle
        )
        if tailAttr.length > 0 {
            MarkdownAttributedRenderer.appendBlockSeparatorIfNeeded(to: storage, style: renderStyle)
            storage.append(tailAttr)
        }

        currentText = text
        configureContainer(width: max(bounds.width, 1))
        refreshMeasuredHeight(width: max(bounds.width, 1), force: true)
        needsLayout = true
    }

    private func updateText(
        _ newText: String,
        mutation: StreamingMessageContentMutation,
        revision: Int?,
        autoScroll: Bool,
        forceHeight: Bool
    ) {
        if let revision {
            guard appliedRevision != revision else { return }
            appliedRevision = revision
        } else {
            guard newText != currentText else { return }
        }

        switch mutation {
        case .append(let delta) where !currentText.isEmpty || newText == delta:
            textView.textStorage?.append(attributedString(delta))
        case .replace(let text):
            textView.textStorage?.setAttributedString(attributedString(text))
        case .append:
            if newText.hasPrefix(currentText) {
                let delta = String(newText.dropFirst(currentText.count))
                textView.textStorage?.append(attributedString(delta))
            } else {
                textView.textStorage?.setAttributedString(attributedString(newText))
            }
        }

        currentText = newText
        configureContainer(width: max(bounds.width, 1))
        refreshMeasuredHeight(width: max(bounds.width, 1), force: forceHeight)
        needsLayout = true
    }

    private func configureTextView() {
        wantsLayer = true
        layer?.masksToBounds = true

        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView
        addSubview(scrollView)

#if DEBUG
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            scrollView.setAccessibilityIdentifier("message.assistant.nativeTextScroll")
            textView.setAccessibilityIdentifier("message.assistant.nativeTextView")
        }
#endif
    }

    private func configureContainer(width: CGFloat) {
        let height = max(cachedHeight, bounds.height, 18)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    }

    private func refreshMeasuredHeight(width: CGFloat, force: Bool) {
        let now = Date()
        let isEarlyContent = currentText.count < 200
        let effectiveInterval: TimeInterval = isEarlyContent ? 1.0 / 60.0 : 1.0 / 30.0
        guard force || now.timeIntervalSince(lastHeightMeasurementTime) >= effectiveInterval else {
            return
        }
        lastHeightMeasurementTime = now

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        configureContainer(width: width)
        layoutManager.ensureLayout(for: textContainer)
        let height = max(18, ceil(layoutManager.usedRect(for: textContainer).height))
        guard abs(height - cachedHeight) > 0.5 else { return }

        cachedHeight = height
        invalidateIntrinsicContentSize()
    }

    private func shouldForceHeightRefresh(for mutation: StreamingMessageContentMutation) -> Bool {
        switch mutation {
        case .append(let delta):
            return delta.contains("\n") || delta.count > 120
        case .replace:
            return true
        }
    }

    private func attributedString(_ string: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
    }
}

private enum RecoveryAction {
    case openModels
    case restart
}

private struct RecoveryNotice {
    let title: String
    let detail: String
    let systemImage: String
    let actionTitle: String?
    let action: RecoveryAction?

    init?(content: String) {
        if content.hasPrefix("The local engine stopped before it could finish.\n\n") {
            title = "Local engine stopped"
            detail = content
            systemImage = "exclamationmark.triangle"
            actionTitle = "Restart"
            action = .restart
            return
        }

        if content.hasPrefix("The local engine reported an error.\n\n") {
            title = "Local engine error"
            detail = content
            systemImage = "exclamationmark.triangle"
            actionTitle = nil
            action = nil
            return
        }

        switch content {
        case "The local engine stopped before it could finish. Restart it, then try again.":
            title = "Local engine stopped"
            detail = content
            systemImage = "exclamationmark.triangle"
            actionTitle = "Restart"
            action = .restart
        case "The selected model could not be loaded. Open Models to check the download, then try again.":
            title = "Model needs attention"
            detail = content
            systemImage = "arrow.down.circle"
            actionTitle = "Open Models"
            action = .openModels
        case "This took longer than expected. Please try again.":
            title = "Request timed out"
            detail = content
            systemImage = "clock"
            actionTitle = nil
            action = nil
        case "Please send your message again.",
             "The request could not be completed. Please try again.":
            title = "Request not completed"
            detail = content
            systemImage = "arrow.clockwise"
            actionTitle = nil
            action = nil
        default:
            return nil
        }
    }
}

private struct RecoveryNoticeView: View {
    let notice: RecoveryNotice
    let onOpenModels: (() -> Void)?
    let onRestartLocalEngine: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.systemImage)
                .font(.system(size: MLXtraDesignSystem.Icon.medium, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 26, height: 26)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 6) {
                Text(notice.title)
                    .font(MLXtraDesignSystem.Typography.compactBodySemibold)

                Text(notice.detail)
                    .font(MLXtraDesignSystem.Typography.compactBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = notice.actionTitle, let action = actionHandler {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var actionHandler: (() -> Void)? {
        switch notice.action {
        case .openModels:
            return onOpenModels
        case .restart:
            return onRestartLocalEngine
        case nil:
            return nil
        }
    }
}
