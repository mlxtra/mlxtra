import AppKit
import SwiftUI

struct ThinkingView: View {
    let content: String
    let isStreaming: Bool
    @State private var isExpanded: Bool

    init(content: String, isStreaming: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
        self._isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        ClickableDisclosureSection(isExpanded: $isExpanded) {
            Text(content)
                .font(MLXtraDesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: MLXtraDesignSystem.Icon.small))
                Text("Thinking")
                    .font(MLXtraDesignSystem.Typography.captionMedium)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)
    }
}

struct MarkdownTextView: View {
    static let blockSpacing = MarkdownRenderStyle.defaultParagraphSpacing

    let text: String
    let isStreaming: Bool

    private var parsedBlocks: [MarkdownBlock] {
        if let cached = MarkdownCache.shared.blocks(for: text) {
            return cached
        }
        let blocks = MarkdownBlockRenderer.blocks(from: text)
        MarkdownCache.shared.setBlocks(blocks, for: text)
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            ForEach(Array(parsedBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .accessibilityIdentifier(markdownAccessibilityIdentifier(for: block))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown.content")
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineText(content)
                .font(MLXtraDesignSystem.Typography.markdownHeading(level: level))
                .lineSpacing(4)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let content):
            inlineText(content)
                .font(MLXtraDesignSystem.Typography.messageBody)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let lines):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    inlineText(line)
                        .font(MLXtraDesignSystem.Typography.messageBody)
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
            }

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(MLXtraDesignSystem.Typography.messageBodyStrong)
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        inlineText(item)
                            .font(MLXtraDesignSystem.Typography.messageBody)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(MLXtraDesignSystem.Typography.messageBodyStrong)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        inlineText(item)
                            .font(MLXtraDesignSystem.Typography.messageBody)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .taskList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.isComplete ? "checkmark.square.fill" : "square")
                            .font(.system(size: MLXtraDesignSystem.Icon.regular))
                            .foregroundStyle(item.isComplete ? Color.accentColor : .secondary)
                            .frame(width: 18, alignment: .trailing)
                        inlineText(item.text)
                            .font(MLXtraDesignSystem.Typography.messageBody)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .codeBlock(let language, let content):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(MLXtraDesignSystem.Typography.codeCaption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(MLXtraDesignSystem.Typography.code)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                    .stroke(MLXtraDesignSystem.Surface.hairline, lineWidth: 1)
            )

        case .table(let rows):
            MarkdownTableView(rows: rows)

        case .mathBlock(let content):
            MarkdownMathBlockView(content: content)

        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func inlineText(_ content: String) -> Text {
        MarkdownInlineSegment.parseSegments(content).reduce(Text("")) { partial, segment in
            switch segment {
            case .text(let value):
                return partial + Text(MarkdownInlineSegment.inlineAttributedString(value))
            case .math(let value):
                return partial + Text(LatexRenderer.render(value))
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundColor(.accentColor)
            }
        }
    }

    private func markdownAccessibilityIdentifier(for block: MarkdownBlock) -> String {
        switch block {
        case .heading:
            return "markdown.heading"
        case .paragraph:
            return "markdown.paragraph"
        case .quote:
            return "markdown.quote"
        case .unorderedList, .orderedList, .taskList:
            return "markdown.list"
        case .codeBlock:
            return "markdown.codeBlock"
        case .table:
            return "markdown.table"
        case .mathBlock:
            return "markdown.mathBlock"
        case .divider:
            return "markdown.divider"
        }
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                            Text(MarkdownInlineSegment.inlineAttributedString(cell))
                                .font(rowIndex == 0 ? MLXtraDesignSystem.Typography.compactBodySemibold : MLXtraDesignSystem.Typography.compactBody)
                                .lineSpacing(3)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: columnWidths[columnIndex], alignment: .topLeading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(rowIndex == 0 ? Color.accentColor.opacity(0.08) : Color.clear)
                                .overlay(alignment: .trailing) {
                                    if columnIndex < columnCount - 1 {
                                        Rectangle()
                                            .fill(MLXtraDesignSystem.Surface.hairline)
                                            .frame(width: 1)
                                    }
                                }
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                    .stroke(MLXtraDesignSystem.Surface.hairline, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
    }

    private var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    private var normalizedRows: [[String]] {
        rows.map { row in
            let missingCells = max(0, columnCount - row.count)
            return row + Array(repeating: "", count: missingCells)
        }
    }

    private var columnWidths: [CGFloat] {
        guard columnCount > 0 else { return [] }

        return (0..<columnCount).map { columnIndex in
            let longestCellLength = normalizedRows
                .map { $0[columnIndex].count }
                .max() ?? 0
            let measuredWidth = CGFloat(min(longestCellLength, 46)) * 7.4 + 32
            let minimumWidth: CGFloat = columnIndex == 0 ? 140 : 112
            let maximumWidth: CGFloat = longestCellLength > 34 ? 360 : 260
            return min(max(measuredWidth, minimumWidth), maximumWidth)
        }
    }
}

private struct MarkdownMathBlockView: View {
    let content: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(LatexRenderer.render(content))
                .font(.system(size: 15, weight: .medium, design: .serif))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)
        .accessibilityIdentifier("markdown.mathBlock")
    }
}

enum LatexRenderer {
    private static let commandReplacements: [(String, String)] = [
        ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\Rightarrow", "⇒"),
        ("\\Leftarrow", "⇐"), ("\\times", "×"), ("\\cdot", "·"),
        ("\\leq", "≤"), ("\\geq", "≥"), ("\\neq", "≠"), ("\\approx", "≈"),
        ("\\pm", "±"), ("\\infty", "∞"), ("\\sum", "∑"), ("\\prod", "∏"),
        ("\\int", "∫"), ("\\partial", "∂"), ("\\nabla", "∇"), ("\\alpha", "α"),
        ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"), ("\\epsilon", "ε"),
        ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ"), ("\\pi", "π"),
        ("\\sigma", "σ"), ("\\omega", "ω"), ("\\Delta", "Δ"), ("\\Omega", "Ω")
    ]

    private static let superscriptMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ"
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ"
    ]

    static func render(_ input: String) -> String {
        var result = input.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result
            .replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")

        result = replaceCommand("\\frac", arity: 2, in: result) { values in
            "\(render(values[0]))⁄\(render(values[1]))"
        }
        result = replaceCommand("\\sqrt", arity: 1, in: result) { values in
            "√(\(render(values[0])))"
        }
        result = replaceCommand("\\text", arity: 1, in: result) { values in
            values[0]
        }

        for (source, replacement) in commandReplacements {
            result = result.replacingOccurrences(of: source, with: replacement)
        }

        result = replaceScript(marker: "^", map: superscriptMap, in: result)
        result = replaceScript(marker: "_", map: subscriptMap, in: result)
        return result.replacingOccurrences(of: "\\", with: "")
    }

    private static func replaceCommand(
        _ command: String,
        arity: Int,
        in text: String,
        transform: ([String]) -> String
    ) -> String {
        var output = text

        while let commandRange = output.range(of: command) {
            var cursor = commandRange.upperBound
            var values: [String] = []

            for _ in 0..<arity {
                while cursor < output.endIndex, output[cursor].isWhitespace {
                    cursor = output.index(after: cursor)
                }
                guard let parsed = parseBracedGroup(in: output, from: cursor) else {
                    return output
                }
                values.append(parsed.content)
                cursor = parsed.endIndex
            }

            output.replaceSubrange(commandRange.lowerBound..<cursor, with: transform(values))
        }

        return output
    }

    private static func parseBracedGroup(in text: String, from start: String.Index) -> (content: String, endIndex: String.Index)? {
        guard start < text.endIndex, text[start] == "{" else { return nil }

        var depth = 0
        var cursor = start
        let contentStart = text.index(after: start)

        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(text[contentStart..<cursor]), text.index(after: cursor))
                }
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func replaceScript(marker: Character, map: [Character: Character], in text: String) -> String {
        var result = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard text[cursor] == marker else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }

            let valueStart = text.index(after: cursor)
            guard valueStart < text.endIndex else {
                result.append(marker)
                cursor = valueStart
                continue
            }

            let parsed: (content: String, endIndex: String.Index)
            if text[valueStart] == "{", let group = parseBracedGroup(in: text, from: valueStart) {
                parsed = group
            } else {
                parsed = (String(text[valueStart]), text.index(after: valueStart))
            }

            if let mapped = mappedScript(parsed.content, map: map) {
                result += mapped
            } else {
                result += "\(marker)(\(parsed.content))"
            }
            cursor = parsed.endIndex
        }

        return result
    }

    private static func mappedScript(_ value: String, map: [Character: Character]) -> String? {
        var result = ""
        for character in value {
            guard let mapped = map[character] else { return nil }
            result.append(mapped)
        }
        return result
    }
}
