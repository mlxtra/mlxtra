import XCTest
@testable import MLXtra

final class MarkdownRenderingTests: XCTestCase {

    // MARK: - Policy

    func testAssistantTextUsesFastPlainRendererByDefault() {
        XCTAssertTrue(AIContentRenderingPolicy.shouldUseFastPlainText(for: "Short answer."))
    }

    func testMarkdownDetectionTriggersRendering() {
        // Headings, lists, code blocks, etc. should require rendered path
        XCTAssertFalse(AIContentRenderingPolicy.shouldUseFastPlainText(for: "# Heading\n\nContent"))
        XCTAssertFalse(AIContentRenderingPolicy.shouldUseFastPlainText(for: "**bold** text"))
    }

    func testMarkdownDetectionRecognizesOrderedListsAndItalic() {
        XCTAssertFalse(AIContentRenderingPolicy.shouldUseFastPlainText(for: "1. First\n2. Second"))
        XCTAssertFalse(AIContentRenderingPolicy.shouldUseFastPlainText(for: "Use *emphasis* here"))
    }

    func testWaveformBarHeightScalesRatiosToGeometry() {
        XCTAssertEqual(AudioWaveformScrubberMetrics.barHeight(ratio: 0.5, maxHeight: 40), 20)
        XCTAssertEqual(AudioWaveformScrubberMetrics.barHeight(ratio: 0.1, maxHeight: 40), 7)
    }

    // MARK: - Block parsing (via MarkdownBlockRenderer)

    func testHeadings() {
        let input = """
        # Heading 1

        ## Heading 2

        ### Heading 3

        Paragraph text here.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        XCTAssertGreaterThanOrEqual(blocks.count, 3)
        // Verify all three headings are present with correct levels
        let headings = blocks.compactMap { block -> (Int, String)? in
            if case let .heading(level, content) = block { return (level, content) }
            return nil
        }
        XCTAssertEqual(headings.map(\.0), [1, 2, 3])
        XCTAssertEqual(headings.map(\.1), ["Heading 1", "Heading 2", "Heading 3"])
    }

    func testCodeBlocks() {
        let input = """
        Here is some code:

        ```swift
        let x = 42
        print(x)
        ```

        After the code block.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        XCTAssertFalse(blocks.isEmpty)
        // Find code block
        let codeBlocks = blocks.filter { if case .codeBlock = $0 { return true }; return false }
        XCTAssertEqual(codeBlocks.count, 1, "Should have exactly one code block")
        if case let .codeBlock(language, content) = codeBlocks[0] {
            XCTAssertEqual(language, "swift")
            XCTAssertTrue(content.contains("let x = 42"))
        }
        // Should also have surrounding paragraphs
        let paragraphs = blocks.filter { if case .paragraph = $0 { return true }; return false }
        XCTAssertGreaterThanOrEqual(paragraphs.count, 1)
    }

    func testUnorderedLists() {
        let input = """
        - Item one
        - Item two
        - Item three

        After the list.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        XCTAssertFalse(blocks.isEmpty)
        if case let .unorderedList(items) = blocks.first(where: { if case .unorderedList = $0 { return true }; return false }) {
            XCTAssertEqual(items, ["Item one", "Item two", "Item three"])
        } else {
            XCTFail("Expected unorderedList in \(blocks)")
        }
    }

    func testOrderedLists() {
        let input = """
        1. First
        2. Second
        3. Third

        After the list.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        XCTAssertFalse(blocks.isEmpty)
        if case let .orderedList(items) = blocks.first(where: { if case .orderedList = $0 { return true }; return false }) {
            XCTAssertEqual(items, ["First", "Second", "Third"])
        } else {
            XCTFail("Expected orderedList, got \(blocks)")
        }
    }

    func testBlockquotes() {
        let input = """
        > This is a quote
        > With multiple lines

        After the quote.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        XCTAssertFalse(blocks.isEmpty)
        let quotes = blocks.filter { if case .quote = $0 { return true }; return false }
        XCTAssertFalse(quotes.isEmpty, "Should contain a quote block")
        if case let .quote(lines) = quotes[0] {
            XCTAssertTrue(lines.contains(where: { $0.contains("This is a quote") }))
            XCTAssertTrue(lines.contains(where: { $0.contains("With multiple lines") }))
        }
    }

    func testTables() {
        let input = """
        | Name | Value |
        | --- | --- |
        | Alpha | 1.0 |
        | Beta | 2.0 |
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        XCTAssertFalse(blocks.isEmpty)
        let table = blocks.first(where: { if case .table = $0 { return true }; return false })
        XCTAssertNotNil(table, "Should find a table block in \(blocks)")
        if case let .table(rows) = table! {
            XCTAssertEqual(rows.first, ["Name", "Value"], "Table should preserve the header row")
            XCTAssertGreaterThanOrEqual(rows.count, 3, "Table should include the header and data rows")
            let allCells = rows.flatMap { $0 }
            XCTAssertTrue(allCells.contains("Alpha"), "Table should contain 'Alpha' data")
            XCTAssertTrue(allCells.contains("Beta"), "Table should contain 'Beta' data")
        }
    }

    func testTaskLists() {
        let input = """
        - [x] Completed task
        - [ ] Pending task
        - [x] Another done

        After tasks.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        // swift-markdown renders task lists as unordered lists
        // This is an accepted difference — our custom task list detection is in the splitter
        XCTAssertFalse(blocks.isEmpty)
    }

    func testMathBlocks() {
        let input = """
        Before math.

        $$
        E = mc^2
        $$

        After math.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        // swift-markdown doesn't natively parse $$, so it's detected as custom math
        let mathBlocks = blocks.filter { if case .mathBlock = $0 { return true }; return false }
        XCTAssertFalse(mathBlocks.isEmpty, "Should detect $$ math blocks")
    }

    func testMixedContent() {
        let input = """
        # Title

        Introductory paragraph.

        ## Section

        - Bullet one
        - Bullet two

        1. First ordered
        2. Second ordered

        > A quote

        ```python
        def hello():
            return "world"
        ```

        Final paragraph.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        XCTAssertFalse(blocks.isEmpty)
        // Verify heading is present
        XCTAssertTrue(blocks.contains(where: { if case .heading(level: 1, content: "Title") = $0 { return true }; return false }))
    }

    func testFencedCodeWithLanguage() {
        let input = """
        ```javascript
        const x = 1;
        ```

        Plain text.
        """

        let blocks = MarkdownBlockRenderer.blocks(from: input)

        XCTAssertFalse(blocks.isEmpty)
        let codeBlocks = blocks.filter { if case .codeBlock = $0 { return true }; return false }
        XCTAssertEqual(codeBlocks.count, 1, "Should have one code block")
        if case let .codeBlock(language, content) = codeBlocks[0] {
            XCTAssertEqual(language, "javascript")
            XCTAssertTrue(content.contains("const x = 1"))
        }
    }

    func testParserRecognizesDisplayMathBlocks() {
        let blocks = MarkdownBlockRenderer.blocks(from: """
            Intro

            $$
            E = mc^2
            $$
            """)

        let mathBlocks = blocks.filter { if case .mathBlock = $0 { return true }; return false }
        XCTAssertFalse(mathBlocks.isEmpty)
    }

    func testParserBuildsStructuredTables() {
        let blocks = MarkdownBlockRenderer.blocks(from: """
            | Name | Value |
            | --- | --- |
            | TTFT | 0.21s |
            """)

        XCTAssertEqual(blocks.count, 1)
        if case let .table(rows) = blocks[0] {
            XCTAssertEqual(rows.first, ["Name", "Value"], "Table should preserve header cells")
            XCTAssertGreaterThanOrEqual(rows.count, 2, "Table should have a header row and at least one data row")
            let allCells = rows.flatMap { $0 }
            XCTAssertTrue(allCells.contains("TTFT"), "Should contain data 'TTFT'")
        } else {
            XCTFail("Expected table, got \(blocks)")
        }
    }

    @MainActor
    func testAttributedTableRenderIncludesHeaderText() {
        let rendered = MarkdownAttributedRenderer.finalRender(
            markdown: """
            | Switch | Sound | Feel |
            | --- | --- | --- |
            | Gazzew Boba U4 | Very low | Smooth tactile |
            """,
            style: .default
        )

        let output = rendered.string
        XCTAssertTrue(output.contains("Switch"), "Rendered table should include header text")
        XCTAssertTrue(output.contains("Sound"), "Rendered table should include the sound header")
        XCTAssertTrue(output.contains("Gazzew Boba U4"), "Rendered table should include data rows")
    }

    // MARK: - Inline segments

    func testInlineSegmentsSplitLatexWithoutDroppingMarkdownText() {
        let segments = MarkdownInlineSegment.parseSegments("Use **energy** $E = mc^2$ now.")

        XCTAssertEqual(
            segments,
            [
                .text("Use **energy** "),
                .math("E = mc^2"),
                .text(" now.")
            ]
        )
    }

    func testLatexRendererNormalizesCommonSyntax() {
        let rendered = LatexRenderer.render(#"\frac{1}{2} \times x_1^2 \leq \sqrt{9}"#)

        XCTAssertEqual(rendered, "1\u{2044}2 \u{00D7} x\u{2081}\u{00B2} \u{2264} \u{221A}(9)")
    }
}
