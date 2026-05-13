import Foundation

/// Semantic Markdown block types — the shared model used by the splitter,
/// both renderers, and the cache.
enum MarkdownBlock: Equatable {
    case heading(level: Int, content: String)
    case paragraph(content: String)
    case quote(lines: [String])
    case unorderedList(items: [String])
    case orderedList(items: [String])
    case taskList(items: [TaskListItem])
    case codeBlock(language: String?, content: String)
    case table(rows: [[String]])
    case mathBlock(content: String)
    case divider
}

struct TaskListItem: Equatable {
    let text: String
    let isComplete: Bool
}

/// Describes the incomplete tail after the last stable block.
/// Used by the streaming splitter and attributed renderer.
enum MarkdownTail: Equatable {
    case paragraph(String)                      // current paragraph, no blank line yet
    case openCodeFence(String, language: String?) // open ``` with accumulated content
    case incompleteTable([String])              // table rows still being written
    case unsafePlain(String)                    // half-open link, unmatched backticks, partial math
    case empty
}

// MARK: - Inline segments

enum MarkdownInlineSegment: Equatable {
    case text(String)
    case math(String)
}

extension MarkdownInlineSegment {

    /// Splits text into inline segments, separating math (`$...$`, `\(...\)`)
    /// from plain text. Preserves Markdown formatting in text segments.
    static func parseSegments(_ text: String) -> [MarkdownInlineSegment] {
        let processed = normalizeHTMLLikeTags(text)
        var segments: [MarkdownInlineSegment] = []
        var scan = processed.startIndex
        var textStart = processed.startIndex

        func appendText(upTo end: String.Index) {
            guard textStart < end else { return }
            segments.append(.text(String(processed[textStart..<end])))
        }

        while scan < processed.endIndex {
            if processed[scan] == "\\" {
                let next = processed.index(after: scan)
                if next < processed.endIndex, processed[next] == "(" {
                    let contentStart = processed.index(after: next)
                    if let end = processed.range(of: "\\)", range: contentStart..<processed.endIndex) {
                        appendText(upTo: scan)
                        segments.append(.math(String(processed[contentStart..<end.lowerBound])))
                        scan = end.upperBound
                        textStart = scan
                        continue
                    }
                }
            }

            if processed[scan] == "$" {
                let next = processed.index(after: scan)
                if next < processed.endIndex, processed[next] != "$",
                   let closing = processed[next...].firstIndex(of: "$") {
                    appendText(upTo: scan)
                    segments.append(.math(String(processed[next..<closing])))
                    scan = processed.index(after: closing)
                    textStart = scan
                    continue
                }
            }

            scan = processed.index(after: scan)
        }

        appendText(upTo: processed.endIndex)
        return segments.isEmpty ? [.text(processed)] : coalesceTextSegments(segments)
    }

    /// Creates an `AttributedString` from text with inline-only Markdown parsing.
    static func inlineAttributedString(_ text: String) -> AttributedString {
        let processed = normalizeHTMLLikeTags(text)
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try AttributedString(markdown: processed, options: options, baseURL: nil)
        } catch {
            return AttributedString(processed)
        }
    }

    // MARK: - Helpers

    private static func normalizeHTMLLikeTags(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"),
            ("<strong>", "**"), ("</strong>", "**"),
            ("<b>", "**"), ("</b>", "**"),
            ("<em>", "*"), ("</em>", "*"),
            ("<i>", "*"), ("</i>", "*"),
            ("<code>", "`"), ("</code>", "`"),
            ("<p>", ""), ("</p>", "\n"),
            ("<div>", ""), ("</div>", "\n")
        ]
        for (source, replacement) in replacements {
            result = result.replacingOccurrences(of: source, with: replacement, options: [.caseInsensitive])
        }
        return result
    }

    private static func coalesceTextSegments(_ segments: [MarkdownInlineSegment]) -> [MarkdownInlineSegment] {
        var result: [MarkdownInlineSegment] = []
        for segment in segments {
            if case .text(let text) = segment, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + text)
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
