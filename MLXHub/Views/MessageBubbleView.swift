import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isStreaming: Bool
    @State private var isHovered = false
    @State private var isCopyAreaHovered = false
    @State private var cursorVisible = true
    @State private var showCopyFeedback = false

    init(message: Message, isStreaming: Bool = false) {
        self.message = message
        self.isStreaming = isStreaming
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser {
                Spacer()
            }

            // Avatar
            if !message.isUser {
                Image(systemName: "sparkle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor)
                    .clipShape(Circle())
            }

            // Message content
            VStack(alignment: .leading, spacing: 4) {
                if let toolCall = message.toolCall {
                    ToolCallView(toolCall: toolCall)
                }

                // AI message with thinking and markdown
                if !message.isUser {
                    if !message.imageURLs.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(message.imageURLs, id: \.self) { imageURL in
                                GeneratedImageAttachmentView(imageURL: imageURL)
                            }
                        }
                        .frame(maxWidth: 540, alignment: .leading)
                    }

                    AIContentView(
                        content: message.content,
                        isStreaming: isStreaming,
                        cursorVisible: cursorVisible,
                        onCopy: copyToClipboard
                    )
                    .contextMenu {
                        Button("Copy") {
                            copyToClipboard()
                        }
                    }
                } else {
                    UserMessageContent(
                        message: message,
                        isStreaming: isStreaming,
                        cursorVisible: cursorVisible
                    )
                }

                // Copy button (visible on hover for completed messages)
                if !message.isUser && !message.content.isEmpty && !isStreaming {
                    HStack {
                        Button(action: copyToClipboard) {
                            HStack(spacing: 4) {
                                Image(systemName: showCopyFeedback ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11))
                                Text(showCopyFeedback ? "Copied!" : "Copy")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovered || isCopyAreaHovered || showCopyFeedback ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: isHovered || isCopyAreaHovered || showCopyFeedback)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isCopyAreaHovered = hovering
                        }
                    }
                }

                // Timestamp
                if !isStreaming {
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }

            if !message.isUser {
                Spacer()
            }

            // User avatar (right side)
            if message.isUser {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
                    .frame(width: 28, height: 28)
                    .background(Color(NSColor.secondaryLabelColor))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, message.isUser ? 0 : 0)
        .onAppear {
            if isStreaming {
                startCursorAnimation()
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                startCursorAnimation()
            }
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()

        var clipboardText = message.content
        if !message.imageURLs.isEmpty {
            let attachments = message.imageURLs.map { $0.lastPathComponent }.joined(separator: ", ")
            clipboardText += clipboardText.isEmpty ? "Attachments: \(attachments)" : "\n\nAttachments: \(attachments)"
        }

        NSPasteboard.general.setString(clipboardText, forType: .string)

        withAnimation {
            showCopyFeedback = true
        }

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation {
                    showCopyFeedback = false
                }
            }
        }
    }

    private func startCursorAnimation() {
        Task { @MainActor in
            while isStreaming {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if isStreaming {
                    cursorVisible.toggle()
                }
            }
            cursorVisible = false
        }
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
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SentImageAttachmentView: View {
    let imageURL: URL

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(nsImage: NSImage(contentsOf: imageURL) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 112, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )

            Text(imageURL.lastPathComponent)
                .font(.system(size: 10))
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

    var body: some View {
        Image(nsImage: NSImage(contentsOf: imageURL) ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 260, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 1)
            )
            .help(imageURL.lastPathComponent)
    }
}

// MARK: - AI Content View with Thinking and Markdown
struct AIContentView: View {
    let content: String
    let isStreaming: Bool
    let cursorVisible: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thinking section - expanded while streaming, collapsible when complete
            if let thinkingContent = extractThinking(content) {
                ThinkingView(content: thinkingContent, isStreaming: isStreaming)
            }

            // Main response
            if let mainContent = extractMainContent(content), !mainContent.isEmpty {
                MarkdownTextView(
                    text: mainContent + (isStreaming && cursorVisible ? "▊" : ""),
                    isStreaming: isStreaming
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Extract thinking content from  <think>  tags
    /// Handles both complete and incomplete (streaming) thinking sections
    private func extractThinking(_ text: String) -> String? {
        for tagPair in thinkingTagPairs {
            // Check if we have an opening tag
            guard text.contains(tagPair.open) else { continue }

            // If we have both opening and closing tags, extract content between them
            if text.contains(tagPair.close) {
                let pattern = "\(NSRegularExpression.escapedPattern(for: tagPair.open))(.*?)\(NSRegularExpression.escapedPattern(for: tagPair.close))"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                    return nil
                }

                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                let thinkingParts = matches.compactMap { match -> String? in
                    guard let range = Range(match.range(at: 1), in: text) else { return nil }
                    return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                return thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n")
            }

            // Incomplete thinking (streaming): extract everything after the opening tag
            if let range = text.range(of: tagPair.open) {
                let thinkingContent = String(text[range.upperBound...])
                return thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    /// Extract main content (everything outside  <think>  tags)
    /// Returns nil if there's incomplete thinking (to hide main content while thinking)
    private func extractMainContent(_ text: String) -> String? {
        for tagPair in thinkingTagPairs {
            // If we have complete think tags, remove them and return the rest
            if text.contains(tagPair.open) && text.contains(tagPair.close) {
                // Remove think tags and their content
                let pattern = "\(NSRegularExpression.escapedPattern(for: tagPair.open)).*?\(NSRegularExpression.escapedPattern(for: tagPair.close))"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                    return text
                }

                let mutableText = NSMutableString(string: text)
                regex.replaceMatches(in: mutableText, options: [], range: NSRange(location: 0, length: mutableText.length), withTemplate: "")

                let result = String(mutableText).trimmingCharacters(in: .whitespacesAndNewlines)
                return result.isEmpty ? nil : result
            }

            // If we have opening tag but no closing tag (incomplete/streaming), return nil
            // This hides the main content until thinking is complete
            if text.contains(tagPair.open) && !text.contains(tagPair.close) {
                return nil
            }
        }

        // No think tags at all, return full text
        return text
    }

    private var thinkingTagPairs: [(open: String, close: String)] {
        [
            ("<think>", "</think>"),
            ("<thinking>", "</thinking>")
        ]
    }
}

// MARK: - Thinking View
struct ThinkingView: View {
    let content: String
    let isStreaming: Bool
    @State private var isExpanded: Bool
    
    init(content: String, isStreaming: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
        // Start expanded while streaming, collapsed when complete
        self._isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(content)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                Text("Thinking")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Markdown Text View
struct MarkdownTextView: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(parseInlineMarkdown(content))
                .font(.system(size: headingSize(for: level), weight: .semibold))
                .lineSpacing(3)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let content):
            Text(parseInlineMarkdown(content))
                .font(.system(size: 14))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(parseInlineMarkdown(line))
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
            }

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 14, weight: .medium))
                        Text(parseInlineMarkdown(item))
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(parseInlineMarkdown(item))
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .taskList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.isComplete ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(item.isComplete ? Color.accentColor : .secondary)
                        Text(parseInlineMarkdown(item.text))
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .codeBlock(let language, let content):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 1)
            )

        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(rows.joined(separator: "\n"))
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .padding(10)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func parseInlineMarkdown(_ text: String) -> AttributedString {
        let processed = normalizeHTMLLikeTags(text)

        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace

            return try AttributedString(
                markdown: processed,
                options: options,
                baseURL: nil
            )
        } catch {
            return AttributedString(processed)
        }
    }

    private func parseBlocks(_ text: String) -> [MarkdownBlock] {
        let normalizedText = normalizeHTMLLikeTags(text)
        let lines = normalizedText.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                index += 1

                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }

                blocks.append(.codeBlock(language: language.isEmpty ? nil : language, content: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if isTableStart(lines, at: index) {
                var tableRows: [String] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    tableRows.append(lines[index])
                    index += 1
                }
                blocks.append(.table(rows: tableRows))
                continue
            }

            if let quote = parseQuote(lines, startIndex: index) {
                blocks.append(.quote(lines: quote.lines))
                index = quote.nextIndex
                continue
            }

            if let taskList = parseTaskList(lines, startIndex: index) {
                blocks.append(.taskList(items: taskList.items))
                index = taskList.nextIndex
                continue
            }

            if let unorderedList = parseUnorderedList(lines, startIndex: index) {
                blocks.append(.unorderedList(items: unorderedList.items))
                index = unorderedList.nextIndex
                continue
            }

            if let orderedList = parseOrderedList(lines, startIndex: index) {
                blocks.append(.orderedList(items: orderedList.items))
                index = orderedList.nextIndex
                continue
            }

            var paragraphLines = [trimmed]
            index += 1

            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty
                    || next.hasPrefix("```")
                    || next.hasPrefix("~~~")
                    || parseHeading(next) != nil
                    || isDivider(next)
                    || isTableStart(lines, at: index)
                    || lineStartsQuote(next)
                    || lineStartsTaskList(next)
                    || lineStartsUnorderedList(next)
                    || lineStartsOrderedList(next) {
                    break
                }
                paragraphLines.append(next)
                index += 1
            }

            blocks.append(.paragraph(content: paragraphLines.joined(separator: " ")))
        }

        return blocks.isEmpty ? [.paragraph(content: text)] : blocks
    }

    private func parseHeading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else {
            return nil
        }

        let content = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, content: content)
    }

    private func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "*" } || compact.allSatisfy { $0 == "_" }
    }

    private func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let current = lines[index].trimmingCharacters(in: .whitespaces)
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard current.contains("|"), separator.contains("|") else { return false }

        let allowed = CharacterSet(charactersIn: "|:- ")
        return separator.unicodeScalars.allSatisfy { allowed.contains($0) } && separator.contains("-")
    }

    private func parseQuote(_ lines: [String], startIndex: Int) -> (lines: [String], nextIndex: Int)? {
        guard lineStartsQuote(lines[startIndex].trimmingCharacters(in: .whitespaces)) else { return nil }

        var quoteLines: [String] = []
        var index = startIndex
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard lineStartsQuote(line) else { break }
            quoteLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }

        return (quoteLines, index)
    }

    private func parseTaskList(_ lines: [String], startIndex: Int) -> (items: [TaskListItem], nextIndex: Int)? {
        guard lineStartsTaskList(lines[startIndex].trimmingCharacters(in: .whitespaces)) else { return nil }

        var items: [TaskListItem] = []
        var index = startIndex
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard lineStartsTaskList(line) else { break }

            let isComplete = line.lowercased().hasPrefix("- [x]") || line.lowercased().hasPrefix("* [x]")
            let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            items.append(TaskListItem(text: text, isComplete: isComplete))
            index += 1
        }

        return (items, index)
    }

    private func parseUnorderedList(_ lines: [String], startIndex: Int) -> (items: [String], nextIndex: Int)? {
        guard lineStartsUnorderedList(lines[startIndex].trimmingCharacters(in: .whitespaces)) else { return nil }

        var items: [String] = []
        var index = startIndex
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard lineStartsUnorderedList(line) else { break }
            items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            index += 1
        }

        return (items, index)
    }

    private func parseOrderedList(_ lines: [String], startIndex: Int) -> (items: [String], nextIndex: Int)? {
        guard let first = orderedListContent(lines[startIndex]) else { return nil }

        var items: [String] = [first]
        var index = startIndex + 1
        while index < lines.count, let item = orderedListContent(lines[index]) {
            items.append(item)
            index += 1
        }

        return (items, index)
    }

    private func lineStartsQuote(_ line: String) -> Bool {
        line.hasPrefix(">")
    }

    private func lineStartsTaskList(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.hasPrefix("- [ ] ")
            || lowercased.hasPrefix("- [x] ")
            || lowercased.hasPrefix("* [ ] ")
            || lowercased.hasPrefix("* [x] ")
    }

    private func lineStartsUnorderedList(_ line: String) -> Bool {
        (line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")) && !lineStartsTaskList(line)
    }

    private func lineStartsOrderedList(_ line: String) -> Bool {
        orderedListContent(line) != nil
    }

    private func orderedListContent(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerEnd = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }

        let number = trimmed[..<markerEnd]
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber }) else { return nil }

        let afterMarker = trimmed.index(after: markerEnd)
        guard afterMarker < trimmed.endIndex, trimmed[afterMarker] == " " else { return nil }

        return String(trimmed[trimmed.index(after: afterMarker)...]).trimmingCharacters(in: .whitespaces)
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 19
        case 3: return 17
        default: return 15
        }
    }

    private func normalizeHTMLLikeTags(_ text: String) -> String {
        var result = text
        let replacements = [
            ("<br>", "\n"),
            ("<br/>", "\n"),
            ("<br />", "\n"),
            ("<strong>", "**"),
            ("</strong>", "**"),
            ("<b>", "**"),
            ("</b>", "**"),
            ("<em>", "*"),
            ("</em>", "*"),
            ("<i>", "*"),
            ("</i>", "*"),
            ("<code>", "`"),
            ("</code>", "`"),
            ("<p>", ""),
            ("</p>", "\n"),
            ("<div>", ""),
            ("</div>", "\n")
        ]

        for (source, replacement) in replacements {
            result = result.replacingOccurrences(of: source, with: replacement, options: [.caseInsensitive])
        }

        return result
    }
}

private enum MarkdownBlock {
    case heading(level: Int, content: String)
    case paragraph(content: String)
    case quote(lines: [String])
    case unorderedList(items: [String])
    case orderedList(items: [String])
    case taskList(items: [TaskListItem])
    case codeBlock(language: String?, content: String)
    case table(rows: [String])
    case divider
}

private struct TaskListItem {
    let text: String
    let isComplete: Bool
}

// MARK: - Tool Call View
struct ToolCallView: View {
    let toolCall: ToolCall
    @State private var isExpanded = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toolCall.icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)

            Text(toolCall.toolName)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(toolCall.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        MessageBubble(message: Message(
            content: "Hello! How can I help you today?",
            isUser: false,
            timestamp: Date()
        ))

        MessageBubble(message: Message(
            content: "I need help with SwiftUI",
            isUser: true,
            timestamp: Date()
        ))
    }
    .padding()
}
