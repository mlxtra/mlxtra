import Foundation

extension StreamingMarkdownSplitter {

    struct CodeFenceResult {
        let block: MarkdownBlock
        let nextIndex: Int
    }

    func parseCodeFence(lines: [String], cursor: Int) -> CodeFenceResult? {
        let opening = lines[cursor].trimmingCharacters(in: .whitespaces)
        let fence = String(opening.prefix(3))
        let language = String(opening.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        var i = cursor + 1
        while i < lines.count {
            let candidate = lines[i].trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix(fence) {
                let code = lines[(cursor + 1)..<i].joined(separator: "\n")
                return CodeFenceResult(
                    block: .codeBlock(language: language.isEmpty ? nil : language, content: code),
                    nextIndex: i + 1
                )
            }
            i += 1
        }
        return nil
    }

    struct MathBlockResult {
        let block: MarkdownBlock
        let nextIndex: Int
    }

    func parseMathBlock(lines: [String], cursor: Int) -> MathBlockResult? {
        let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("$$") {
            let after = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if after.hasSuffix("$$") {
                return MathBlockResult(block: .mathBlock(content: String(after.dropLast(2)).trimmingCharacters(in: .whitespaces)), nextIndex: cursor + 1)
            }
            var i = cursor + 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
                    let math = lines[(cursor + 1)..<i].joined(separator: "\n")
                    return MathBlockResult(block: .mathBlock(content: math), nextIndex: i + 1)
                }
                i += 1
            }
            return nil
        }

        if trimmed.hasPrefix("\\[") {
            if trimmed.hasSuffix("\\]") {
                let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                return MathBlockResult(block: .mathBlock(content: inner), nextIndex: cursor + 1)
            }
            var i = cursor + 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("\\]") {
                    let math = lines[(cursor + 1)..<i].joined(separator: "\n")
                    return MathBlockResult(block: .mathBlock(content: math), nextIndex: i + 1)
                }
                i += 1
            }
            return nil
        }

        if trimmed.hasPrefix("\\begin{equation}") {
            var i = cursor + 1
            while i < lines.count {
                if lines[i].contains("\\end{equation}") {
                    let math = lines[(cursor + 1)..<i].joined(separator: "\n")
                    return MathBlockResult(block: .mathBlock(content: math), nextIndex: i + 1)
                }
                i += 1
            }
            return nil
        }

        return nil
    }

    func parseTableBlock(_ lines: [String]) -> MarkdownBlock {
        guard lines.count >= 2 else {
            return .paragraph(content: lines.joined(separator: "\n"))
        }

        func splitRow(_ row: String) -> [String] {
            var cells = row.split(separator: "|", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            return cells
        }

        let header = splitRow(lines[0])
        var body: [[String]] = []

        for i in 1..<lines.count {
            let row = splitRow(lines[i])
            let isSeparator = row.allSatisfy { cell in
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && trimmed.allSatisfy { ch in ch == "-" || ch == ":" || ch == " " }
            }
            if !isSeparator {
                body.append(row)
            }
        }

        return .table(rows: [header] + body)
    }

    func parseTaskListItems(_ lines: [String]) -> [TaskListItem] {
        lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            let isComplete = lower.hasPrefix("- [x]") || lower.hasPrefix("* [x]")
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return TaskListItem(text: text, isComplete: isComplete)
        }
    }


    func parseHeadingLine(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes),
              line.dropFirst(hashes).first == " " else { return nil }
        let content = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, content: content)
    }

    func isDividerLine(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy({ $0 == "-" }) || compact.allSatisfy({ $0 == "*" }) || compact.allSatisfy({ $0 == "_" })
    }

    func isTaskListItem(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.hasPrefix("- [ ] ") || lower.hasPrefix("- [x] ")
            || lower.hasPrefix("* [ ] ") || lower.hasPrefix("* [x] ")
    }

    func isUnorderedListItem(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return (t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")) && !isTaskListItem(line)
    }

    func isOrderedListItem(_ line: String) -> Bool {
        extractOrderedContent(line) != nil
    }

    func extractOrderedContent(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerEnd = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let number = trimmed[..<markerEnd]
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber }) else { return nil }
        let after = trimmed.index(after: markerEnd)
        guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
        return String(trimmed[trimmed.index(after: after)...]).trimmingCharacters(in: .whitespaces)
    }


    func nextNonEmptyLine(_ lines: [String], from index: Int) -> (index: Int, line: String)? {
        var i = index
        while i < lines.count {
            if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                return (i, lines[i])
            }
            i += 1
        }
        return nil
    }

    func findParagraphEnd(lines: [String], from cursor: Int) -> Int {
        var i = cursor
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return i }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { return i }
            if t.hasPrefix("$$") || t.hasPrefix("\\[") { return i }
            if parseHeadingLine(t) != nil { return i }
            if isDividerLine(t) { return i }
            if t.contains("|") && i + 1 < lines.count { return i }
            if t.hasPrefix(">") { return i }
            if isTaskListItem(t) || isUnorderedListItem(t) || isOrderedListItem(t) { return i }
            i += 1
        }
        return i
    }

    func findQuoteEnd(lines: [String], from cursor: Int) -> Int {
        var i = cursor
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return i }
            guard t.hasPrefix(">") else { return i }
            i += 1
        }
        return i
    }

    func findListEnd(lines: [String], from cursor: Int, isOrdered: Bool) -> Int {
        var i = cursor
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return i }
            let matches: Bool = isOrdered ? isOrderedListItem(t) : isUnorderedListItem(t)
            guard matches else { return i }
            i += 1
        }
        return i
    }

    func findTaskListEnd(lines: [String], from cursor: Int) -> Int {
        var i = cursor
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return i }
            guard isTaskListItem(t) else { return i }
            i += 1
        }
        return i
    }

    func findTableEnd(lines: [String], from cursor: Int) -> Int {
        var i = cursor
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if !t.contains("|") {
                return i
            }
            i += 1
        }
        return i
    }


    func hasUnsafeConstruct(_ text: String) -> Bool {
        if let bracketEnd = text.range(of: "](") {
            let after = text[bracketEnd.upperBound...]
            if !after.contains(")") { return true }
        }

        let backtickCount = text.filter { $0 == "`" }.count
        if backtickCount % 2 != 0 { return true }

        if text.contains("$") && text.filter({ $0 == "$" }).count % 2 != 0 { return true }
        if text.contains("<") && !text.contains(">") { return true }
        return false
    }

    func extractCodeFenceLanguage(_ line: String) -> String? {
        let fence = line.hasPrefix("```") ? String(line.dropFirst(3)) : String(line.dropFirst(3))
        let lang = fence.trimmingCharacters(in: .whitespacesAndNewlines)
        return lang.isEmpty ? nil : lang
    }
}
