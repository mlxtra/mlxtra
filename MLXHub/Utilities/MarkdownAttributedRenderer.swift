import Foundation
import AppKit

// MARK: - Render style

struct MarkdownRenderStyle {
    let fontSize: CGFloat
    let textColor: NSColor
    let codeFont: NSFont
    let codeBackground: NSColor
    let headingFont: (Int) -> NSFont
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat

    static let `default` = MarkdownRenderStyle(
        fontSize: 14.5,
        textColor: .labelColor,
        codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        codeBackground: NSColor.textBackgroundColor,
        headingFont: { level in
            let sizes: [CGFloat] = [22, 19, 17, 15, 14, 14]
            let weight: NSFont.Weight = level <= 2 ? .semibold : .medium
            return .systemFont(ofSize: sizes[max(0, min(level - 1, 5))], weight: weight)
        },
        lineSpacing: 5,
        paragraphSpacing: 8
    )
}

// MARK: - Attributed string renderer

/// Renders `[MarkdownBlock]` and `MarkdownTail` values to `NSAttributedString`
/// for direct use with `NSTextStorage`.
struct MarkdownAttributedRenderer {

    // MARK: - Full pipeline (raw Markdown → NSAttributedString)

    /// Runs the full final-render pipeline: raw Markdown → swift-markdown AST →
    /// `MarkdownBlockRenderer` → semantic blocks → `NSAttributedString`.
    ///
    /// Uses the cache if available; otherwise parses, renders, and caches.
    @MainActor
    static func finalRender(markdown: String, style: MarkdownRenderStyle) -> NSAttributedString {
        if let cached = MarkdownCache.shared.attributedString(for: markdown, style: style) {
            return cached
        }
        let blocks = MarkdownBlockRenderer.blocks(from: markdown)
        let result = attributedString(from: blocks, style: style)
        MarkdownCache.shared.setAttributedString(result, for: markdown, style: style)
        return result
    }

    // MARK: - Full document (from blocks)

    static func attributedString(
        from blocks: [MarkdownBlock],
        style: MarkdownRenderStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(attributedString(from: block, style: style))
        }
        return result
    }

    // MARK: - Single block

    static func attributedString(
        from block: MarkdownBlock,
        style: MarkdownRenderStyle
    ) -> NSAttributedString {
        switch block {
        case .heading(let level, let content):
            return heading(content, level: level, style: style)

        case .paragraph(let content):
            return paragraph(content, style: style)

        case .codeBlock(let language, let content):
            return codeBlock(content, language: language, style: style)

        case .unorderedList(let items):
            return list(items, marker: "•", style: style)

        case .orderedList(let items):
            let result = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "\n")) }
                result.append(paragraph("\(index + 1). \(item)", style: style))
            }
            return result

        case .taskList(let items):
            let result = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "\n")) }
                let mark = item.isComplete ? "[x]" : "[ ]"
                result.append(paragraph("\(mark) \(item.text)", style: style))
            }
            return result

        case .quote(let lines):
            return quote(lines, style: style)

        case .table(let rows):
            return table(rows, style: style)

        case .mathBlock(let content):
            return mathBlock(content, style: style)

        case .divider:
            return divider(style: style)
        }
    }

    // MARK: - Tail rendering

    static func tailAttributedString(
        from tail: MarkdownTail,
        style: MarkdownRenderStyle
    ) -> NSAttributedString {
        switch tail {
        case .paragraph(let text):
            return inlineAttributedString(text, style: style)

        case .openCodeFence(let content, let language):
            let display = language.map { "```\($0)\n\(content)" } ?? "```\n\(content)"
            let attr = NSMutableAttributedString(string: display)
            let fullRange = NSRange(location: 0, length: attr.length)
            attr.addAttribute(.font, value: style.codeFont, range: fullRange)
            attr.addAttribute(.foregroundColor, value: style.textColor, range: fullRange)
            attr.addAttribute(.backgroundColor, value: style.codeBackground, range: fullRange)
            return attr

        case .unsafePlain(let text):
            return plainString(text, style: style)

        case .incompleteTable(let rows):
            return plainString(rows.joined(separator: "\n"), style: style)

        case .empty:
            return NSAttributedString()
        }
    }

    // MARK: - Block renderers

    private static func heading(_ text: String, level: Int, style: MarkdownRenderStyle) -> NSAttributedString {
        let result = inlineAttributedString(text, style: style)
        let mutable = NSMutableAttributedString(attributedString: result)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: style.headingFont(level), range: fullRange)
        return mutable
    }

    private static func paragraph(_ text: String, style: MarkdownRenderStyle) -> NSAttributedString {
        inlineAttributedString(text, style: style)
    }

    private static func codeBlock(_ code: String, language: String?, style: MarkdownRenderStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if let language, !language.isEmpty {
            let langLine = NSAttributedString(
                string: "\(language)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            result.append(langLine)
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 0
        let codeAttr = NSAttributedString(
            string: code,
            attributes: [
                .font: style.codeFont,
                .foregroundColor: style.textColor,
                .backgroundColor: style.codeBackground,
                .paragraphStyle: paragraphStyle
            ]
        )
        result.append(codeAttr)

        return result
    }

    private static func list(_ items: [String], marker: String, style: MarkdownRenderStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let markerAttr = NSAttributedString(
                string: "\(marker) ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: style.fontSize, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            result.append(markerAttr)
            result.append(inlineAttributedString(item, style: style))
        }
        return result
    }

    private static func quote(_ lines: [String], style: MarkdownRenderStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let lineAttr = inlineAttributedString(line, style: style)
            let mutable = NSMutableAttributedString(attributedString: lineAttr)
            let fullRange = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: fullRange)
            result.append(mutable)
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = 12
        paragraphStyle.firstLineHeadIndent = 12
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func table(_ rows: [[String]], style: MarkdownRenderStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 { result.append(NSAttributedString(string: "\n")) }
            let rowText = row.joined(separator: "  ")
            let attr = NSAttributedString(
                string: rowText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: rowIndex == 0 ? .semibold : .regular),
                    .foregroundColor: style.textColor
                ]
            )
            result.append(attr)
        }
        return result
    }

    private static func mathBlock(_ content: String, style: MarkdownRenderStyle) -> NSAttributedString {
        let rendered = LatexRenderer.render(content)
        return NSAttributedString(
            string: rendered,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: style.textColor
            ]
        )
    }

    private static func divider(style: MarkdownRenderStyle) -> NSAttributedString {
        NSAttributedString(
            string: String(repeating: "—", count: 24),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.separatorColor
            ]
        )
    }

    // MARK: - Inline rendering

    private static func inlineAttributedString(_ text: String, style: MarkdownRenderStyle) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: style.fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.lineSpacing

        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            let attributed = try AttributedString(markdown: text, options: options, baseURL: nil)
            let nsAttr = NSMutableAttributedString(attributed)
            // Apply base attributes as defaults (don't override explicit formatting)
            let fullRange = NSRange(location: 0, length: nsAttr.length)
            nsAttr.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
                if attrs[.font] == nil {
                    nsAttr.addAttribute(.font, value: baseFont, range: range)
                }
                if attrs[.foregroundColor] == nil {
                    nsAttr.addAttribute(.foregroundColor, value: style.textColor, range: range)
                }
                if attrs[.paragraphStyle] == nil {
                    nsAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
                }
            }
            return nsAttr
        } catch {
            return plainString(text, style: style)
        }
    }

    private static func plainString(_ text: String, style: MarkdownRenderStyle) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.lineSpacing
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: style.fontSize),
                .foregroundColor: style.textColor,
                .paragraphStyle: paragraphStyle
            ]
        )
    }
}
