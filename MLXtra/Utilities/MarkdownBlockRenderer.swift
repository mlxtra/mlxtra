import Foundation
import Markdown

/// Walks a swift-markdown `Document` AST and produces `[MarkdownBlock]`.
///
/// Math blocks ($$, \[, \begin{equation}) are custom-detected since
/// swift-markdown does not natively handle them.
struct MarkdownBlockRenderer {
    /// Convenience: parses raw Markdown text through swift-markdown and
    /// returns semantic blocks. Use this from contexts that don't import Markdown.
    static func blocks(from markdown: String) -> [MarkdownBlock] {
        blocks(from: Document(parsing: markdown))
    }

    static func blocks(from document: Document) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for child in document.blockChildren {
            blocks.append(contentsOf: convert(child))
        }
        if blocks.isEmpty {
            return [.paragraph(content: "")]
        }
        return blocks
    }


    private static func convert(_ block: any Markup) -> [MarkdownBlock] {
        switch block {
        case let heading as Heading:
            return [.heading(level: heading.level, content: plainText(heading))]

        case let codeBlock as CodeBlock:
            let lang = codeBlock.language?.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = codeBlock.code.trimmingCharacters(in: .whitespacesAndNewlines)
            return [.codeBlock(language: (lang?.isEmpty ?? true) ? nil : lang, content: code)]

        case let paragraph as Paragraph:
            let text = plainText(paragraph)
            if let math = parseMathBlock(from: text) {
                return [math]
            }
            return [.paragraph(content: text)]

        case let blockQuote as BlockQuote:
            var lines: [String] = []
            for child in blockQuote.blockChildren {
                lines.append(plainText(child))
            }
            return [.quote(lines: lines)]

        case let unorderedList as UnorderedList:
            var items: [String] = []
            for item in unorderedList.listItems {
                items.append(plainText(item))
            }
            return [.unorderedList(items: items)]

        case let orderedList as OrderedList:
            var items: [String] = []
            for item in orderedList.listItems {
                items.append(plainText(item))
            }
            return [.orderedList(items: items)]

        case let table as Markdown.Table:
            var rows: [[String]] = []

            let header = Array(table.head.cells.map { plainText($0) })
            if !header.isEmpty {
                rows.append(header)
            }

            for row in table.body.rows {
                let cells = Array(row.cells.map { plainText($0) })
                if !cells.allSatisfy({ isDelimiterCell($0) }) {
                    rows.append(cells)
                }
            }

            if rows.isEmpty {
                return [.paragraph(content: "")]
            }
            return [.table(rows: rows)]

        case is ThematicBreak:
            return [.divider]

        default:
            let text = plainText(block)
            guard !text.isEmpty else { return [] }
            if let math = parseMathBlock(from: text) {
                return [math]
            }
            return [.paragraph(content: text)]
        }
    }


    /// Extracts all inline text from a Markup node, preserving author-entered line breaks.
    private static func plainText(_ node: some Markup) -> String {
        node.children.compactMap { child in
            if let text = child as? Markdown.Text {
                return text.string
            }
            if let inlineCode = child as? InlineCode {
                return "`\(inlineCode.code)`"
            }
            if let emphasis = child as? Emphasis {
                return "*\(plainText(emphasis))*"
            }
            if let strong = child as? Strong {
                return "**\(plainText(strong))**"
            }
            if let link = child as? Markdown.Link {
                let title = plainText(link)
                let destination = link.destination ?? ""
                return "[\(title)](\(destination))"
            }
            if let image = child as? Markdown.Image {
                let alt = plainText(image)
                let src = image.source ?? ""
                return "![\(alt)](\(src))"
            }
            if child is SoftBreak {
                return "\n"
            }
            if child is LineBreak {
                return "\n"
            }
            if let strikethrough = child as? Strikethrough {
                return "~~\(plainText(strikethrough))~~"
            }
            if let html = child as? HTMLBlock {
                return html.rawHTML
            }
            if let inlineHTML = child as? InlineHTML {
                return inlineHTML.rawHTML
            }
            return plainText(child)
        }.joined(separator: "")
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: ":-| ")
        return trimmed.unicodeScalars.allSatisfy(allowed.contains) && trimmed.contains("-")
    }


    private static func parseMathBlock(from text: String) -> MarkdownBlock? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("$$") {
            let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if content.hasSuffix("$$") {
                return .mathBlock(content: String(content.dropLast(2)).trimmingCharacters(in: .whitespaces))
            }
            return .mathBlock(content: content)
        }

        if trimmed.hasPrefix("\\[") {
            let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if content.hasSuffix("\\]") {
                return .mathBlock(content: String(content.dropLast(2)).trimmingCharacters(in: .whitespaces))
            }
            return .mathBlock(content: content)
        }

        return nil
    }
}
