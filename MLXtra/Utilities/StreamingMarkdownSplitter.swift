import Foundation

// MARK: - Split result

struct SplitResult {
    let newBlocks: [MarkdownBlock]            // new stable blocks since committedEndIndex
    let tail: MarkdownTail
    let newCommittedEndIndex: String.Index    // right after the last stable block
    let newCommittedUTF16Offset: Int          // fallback for index recovery
}

// MARK: - Streaming state

/// Tracks splitter position and NSTextStorage layout during streaming.
/// Kept separate from the pure splitter — this is mutable view state.
final class StreamingMarkdownState {
    var committedEndIndex: String.Index?
    var committedUTF16Offset: Int = 0
    var stableStorageEndLocation: Int = 0    // NSTextStorage length after last stable block
    var lastSplitTime: CFTimeInterval = 0

    func reset() {
        committedEndIndex = nil
        committedUTF16Offset = 0
        stableStorageEndLocation = 0
        lastSplitTime = 0
    }

    func tailRange(storageLength: Int) -> NSRange {
        let location = min(max(stableStorageEndLocation, 0), storageLength)
        return NSRange(location: location, length: storageLength - location)
    }
}

// MARK: - Splitter

/// Pure function: splits streaming Markdown text into stable completed blocks
/// and an unstable tail. Does NOT render — only produces `MarkdownBlock` values.
///
/// Throttle externally (~30 Hz). Between splits, tokens accumulate in the tail
/// and are rendered inline-only by `MarkdownAttributedRenderer`.
struct StreamingMarkdownSplitter {

    func splitStablePrefix(
        _ rawText: String,
        committedEndIndex: String.Index?,
        committedUTF16Offset: Int? = nil
    ) -> SplitResult {
        let startIndex = validatedStart(
            rawText: rawText,
            committedEndIndex: committedEndIndex,
            committedUTF16Offset: committedUTF16Offset
        )
        guard startIndex < rawText.endIndex else {
            return SplitResult(
                newBlocks: [],
                tail: .empty,
                newCommittedEndIndex: startIndex,
                newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: startIndex)
            )
        }

        let unscanned = rawText[startIndex...]
        let lines = unscanned.components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return SplitResult(
                newBlocks: [],
                tail: .empty,
                newCommittedEndIndex: startIndex,
                newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: startIndex)
            )
        }

        var blocks: [MarkdownBlock] = []
        var cursor = 0  // index within `lines`
        var currentIndex = startIndex
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if trimmed.isEmpty {
                cursor += 1
                currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                continue
            }

            // Code fence
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let result = parseCodeFence(lines: lines, cursor: cursor)
                if let fenceResult = result {
                    blocks.append(fenceResult.block)
                    cursor = fenceResult.nextIndex
                    currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                    continue
                }
                // Open code fence — not stable
                let accumulated = lines[cursor...].joined(separator: "\n")
                let tail: MarkdownTail = .openCodeFence(
                    accumulated,
                    language: extractCodeFenceLanguage(trimmed)
                )
                return SplitResult(
                    newBlocks: blocks,
                    tail: tail,
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            // Heading — stable only if next line has begun (not at streaming EOF)
            if let heading = parseHeadingLine(trimmed) {
                let nextNonEmptyAfterHeading = nextNonEmptyLine(lines, from: cursor + 1)
                if let next = nextNonEmptyAfterHeading {
                    // Next line exists and is not empty — heading is stable
                    blocks.append(heading)
                    cursor = next.index
                    currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                    continue
                }
                // No next line yet — heading stays in tail, not stable
                return SplitResult(
                    newBlocks: blocks,
                    tail: .paragraph(lines[cursor...].joined(separator: "\n")),
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            // Divider
            if isDividerLine(trimmed) {
                blocks.append(.divider)
                cursor += 1
                currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                continue
            }

            // Math block
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") || trimmed.hasPrefix("\\begin{equation}") {
                let result = parseMathBlock(lines: lines, cursor: cursor)
                if let mathResult = result {
                    blocks.append(mathResult.block)
                    cursor = mathResult.nextIndex
                    currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                    continue
                }
                // Open math block — not stable
                return SplitResult(
                    newBlocks: blocks,
                    tail: .unsafePlain(lines[cursor...].joined(separator: "\n")),
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            // Table — check if this line + next line form a table
            if trimmed.contains("|") {
                let tableEnd = findTableEnd(lines: lines, from: cursor)
                if tableEnd > cursor + 1 {
                    // Table has at least 2 lines (header + separator) and is complete
                    let tableLines = Array(lines[cursor..<tableEnd])
                    let tableBlock = parseTableBlock(tableLines)
                    blocks.append(tableBlock)
                    cursor = tableEnd
                    currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                    continue
                }
                // Single pipe line or incomplete table
                return SplitResult(
                    newBlocks: blocks,
                    tail: .incompleteTable(Array(lines[cursor...])),
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            // Blockquote — group consecutive `>` lines
            if trimmed.hasPrefix(">") {
                let quoteEnd = findQuoteEnd(lines: lines, from: cursor)
                if quoteEnd < lines.count {
                    // Quote is complete (followed by non-empty, non-quote content or blank line)
                    let quoteLines = Array(lines[cursor..<quoteEnd]).map {
                        let t = $0.trimmingCharacters(in: .whitespaces)
                        return t.hasPrefix(">") ? String(t.dropFirst()).trimmingCharacters(in: .whitespaces) : t
                    }
                    blocks.append(.quote(lines: quoteLines))
                    cursor = quoteEnd
                    currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                    continue
                }
                // Quote at end of stream — not stable
                return SplitResult(
                    newBlocks: blocks,
                    tail: .paragraph(lines[cursor...].joined(separator: "\n")),
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            // Task list
            if isTaskListItem(trimmed) {
                let listEnd = findTaskListEnd(lines: lines, from: cursor)
                if listEnd < lines.count {
                    let items = parseTaskListItems(Array(lines[cursor..<listEnd]))
                    blocks.append(.taskList(items: items))
                    cursor = listEnd
                    currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                    continue
                }
                return SplitResult(
                    newBlocks: blocks,
                    tail: .paragraph(lines[cursor...].joined(separator: "\n")),
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            // Unordered list
            if isUnorderedListItem(trimmed) {
                let listEnd = findListEnd(lines: lines, from: cursor, isOrdered: false)
                if listEnd < lines.count {
                    let items = Array(lines[cursor..<listEnd]).map {
                        String($0.trimmingCharacters(in: .whitespaces).dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    }
                    blocks.append(.unorderedList(items: items))
                    cursor = listEnd
                    currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                    continue
                }
                return SplitResult(
                    newBlocks: blocks,
                    tail: .paragraph(lines[cursor...].joined(separator: "\n")),
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            // Ordered list
            if isOrderedListItem(trimmed) {
                let listEnd = findListEnd(lines: lines, from: cursor, isOrdered: true)
                if listEnd < lines.count {
                    let items = Array(lines[cursor..<listEnd]).compactMap { extractOrderedContent($0) }
                    blocks.append(.orderedList(items: items))
                    cursor = listEnd
                    currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                    continue
                }
                return SplitResult(
                    newBlocks: blocks,
                    tail: .paragraph(lines[cursor...].joined(separator: "\n")),
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            // Paragraph — collect until next boundary
            let paraEnd = findParagraphEnd(lines: lines, from: cursor)
            let paraLines = Array(lines[cursor..<paraEnd])
            let paraText = paraLines.joined(separator: "\n")

            if paraEnd < lines.count {
                // Paragraph is complete (next line is empty or a boundary)
                blocks.append(.paragraph(content: paraText))
                cursor = paraEnd
                // Skip trailing blank line if present
                if cursor < lines.count && lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                    cursor += 1
                }
                currentIndex = advanceIndexByLines(in: rawText, from: startIndex, count: cursor, lines: lines)
                continue
            }

            // Paragraph at end of stream — not stable. Check for unsafe constructs.
            if hasUnsafeConstruct(paraText) {
                return SplitResult(
                    newBlocks: blocks,
                    tail: .unsafePlain(paraText),
                    newCommittedEndIndex: currentIndex,
                    newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
                )
            }

            return SplitResult(
                newBlocks: blocks,
                tail: .paragraph(paraText),
                newCommittedEndIndex: currentIndex,
                newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
            )
        }

        return SplitResult(
            newBlocks: blocks,
            tail: .empty,
            newCommittedEndIndex: currentIndex,
            newCommittedUTF16Offset: rawText.utf16.distance(from: rawText.startIndex, to: currentIndex)
        )
    }

    // MARK: - Index validation

    private func validatedStart(
        rawText: String,
        committedEndIndex: String.Index?,
        committedUTF16Offset: Int?
    ) -> String.Index {
        if let offset = committedUTF16Offset,
           let index = indexFromUTF16Offset(offset, in: rawText) {
            return index
        }

        guard committedEndIndex != nil else {
            return rawText.startIndex
        }
        return rawText.startIndex
    }

    // MARK: - Index helpers

    private func indexFromUTF16Offset(_ offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: text)
    }

    private func advanceIndexByLines(in text: String, from start: String.Index, count: Int, lines: [String]) -> String.Index {
        var idx = start
        var remaining = count
        while remaining > 0 && idx < text.endIndex {
            if text[idx] == "\n" {
                remaining -= 1
            }
            idx = text.index(after: idx)
        }
        return idx
    }

}
