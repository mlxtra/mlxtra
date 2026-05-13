import XCTest
@testable import MLXtra

final class StreamingMarkdownSplitterTests: XCTestCase {

    let splitter = StreamingMarkdownSplitter()

    // MARK: - Paragraph tests

    func testSimpleParagraphStabilizedAfterBlankLine() {
        let result = splitter.splitStablePrefix(
            "Hello world\n\nnext",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [.paragraph(content: "Hello world")])
        XCTAssertEqual(result.tail, .paragraph("next"))
    }

    func testParagraphAtEOFNotStable() {
        let result = splitter.splitStablePrefix(
            "Hello world",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .paragraph("Hello world"))
    }

    func testMultipleParagraphsStabilize() {
        let result = splitter.splitStablePrefix(
            "First paragraph.\n\nSecond paragraph.\n\nthird",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [
            .paragraph(content: "First paragraph."),
            .paragraph(content: "Second paragraph.")
        ])
        XCTAssertEqual(result.tail, .paragraph("third"))
    }

    // MARK: - Code fence tests

    func testClosedCodeFenceBecomesStableBlock() {
        let input = """
        ```swift
        let x = 42
        print(x)
        ```

        After code.
        """

        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks.count, 1)
        if case let .codeBlock(language, content) = result.newBlocks[0] {
            XCTAssertEqual(language, "swift")
            XCTAssertTrue(content.contains("let x = 42"))
            XCTAssertTrue(content.contains("print(x)"))
        } else {
            XCTFail("Expected codeBlock, got \(result.newBlocks[0])")
        }
        XCTAssertEqual(result.tail, .paragraph("After code."))
    }

    func testOpenCodeFenceIsTailOnly() {
        let result = splitter.splitStablePrefix(
            "```python\nimport os\nos.path",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        if case let .openCodeFence(content, language) = result.tail {
            XCTAssertEqual(language, "python")
            XCTAssertTrue(content.contains("import os"))
            XCTAssertTrue(content.contains("os.path"))
        } else {
            XCTFail("Expected openCodeFence tail, got \(result.tail)")
        }
    }

    func testCodeFenceWithoutLanguage() {
        let input = """
        ```
        plain code
        ```

        after
        """

        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks.count, 1)
        if case let .codeBlock(language, content) = result.newBlocks[0] {
            XCTAssertNil(language)
            XCTAssertEqual(content, "plain code")
        } else {
            XCTFail("Expected codeBlock, got \(result.newBlocks[0])")
        }
    }

    // MARK: - Heading tests

    func testHeadingStableWhenNextLineExists() {
        let result = splitter.splitStablePrefix(
            "# My Heading\n\nnext line",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [.heading(level: 1, content: "My Heading")])
        XCTAssertEqual(result.tail, .paragraph("next line"))
    }

    func testHeadingNotStableAtEOF() {
        let result = splitter.splitStablePrefix(
            "## Pending Heading",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .paragraph("## Pending Heading"))
    }

    func testHeadingNotStableWithOnlyBlankAfter() {
        let result = splitter.splitStablePrefix(
            "### Title\n\n",
            committedEndIndex: nil
        )

        // When only blank lines follow, heading stays in tail
        XCTAssertEqual(result.newBlocks, [])
        XCTAssertFalse(result.tail == .empty)
    }

    // MARK: - Link safety tests

    func testHalfOpenLinkBecomesUnsafePlain() {
        let result = splitter.splitStablePrefix(
            "Check [this link](https://example.com",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .unsafePlain("Check [this link](https://example.com"))
    }

    func testCompletedLinkPartOfParagraph() {
        let result = splitter.splitStablePrefix(
            "Check [this link](https://example.com) now\n\nnext",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [.paragraph(content: "Check [this link](https://example.com) now")])
        XCTAssertEqual(result.tail, .paragraph("next"))
    }

    func testUnmatchedBackticksUnsafe() {
        let result = splitter.splitStablePrefix(
            "Here is `code",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .unsafePlain("Here is `code"))
    }

    // MARK: - List tests

    func testUnorderedListStabilizedAfterBlankLine() {
        let input = """
        - Item one
        - Item two
        - Item three

        After list.
        """

        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks.count, 1)
        if case let .unorderedList(items) = result.newBlocks[0] {
            XCTAssertEqual(items, ["Item one", "Item two", "Item three"])
        } else {
            XCTFail("Expected unorderedList, got \(result.newBlocks[0])")
        }
        XCTAssertEqual(result.tail, .paragraph("After list."))
    }

    func testOrderedListStabilizedAfterBlankLine() {
        let input = """
        1. First
        2. Second
        3. Third

        After list.
        """

        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks.count, 1)
        if case let .orderedList(items) = result.newBlocks[0] {
            XCTAssertEqual(items, ["First", "Second", "Third"])
        } else {
            XCTFail("Expected orderedList, got \(result.newBlocks[0])")
        }
    }

    func testListAtEOFNotStable() {
        let result = splitter.splitStablePrefix(
            "- Item one\n- Item two",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .paragraph("- Item one\n- Item two"))
    }

    func testTaskListStabilized() {
        let input = """
        - [x] Completed task
        - [ ] Pending task

        After tasks.
        """

        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks.count, 1)
        if case let .taskList(items) = result.newBlocks[0] {
            XCTAssertEqual(items.count, 2)
            XCTAssertTrue(items[0].isComplete)
            XCTAssertFalse(items[1].isComplete)
            XCTAssertEqual(items[0].text, "Completed task")
            XCTAssertEqual(items[1].text, "Pending task")
        } else {
            XCTFail("Expected taskList, got \(result.newBlocks[0])")
        }
    }

    // MARK: - Blockquote tests

    func testBlockquoteStabilized() {
        let input = """
        > This is a quote
        > With multiple lines

        After quote.
        """

        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks.count, 1)
        if case let .quote(lines) = result.newBlocks[0] {
            XCTAssertEqual(lines, ["This is a quote", "With multiple lines"])
        } else {
            XCTFail("Expected quote, got \(result.newBlocks[0])")
        }
    }

    func testBlockquoteAtEOFNotStable() {
        let result = splitter.splitStablePrefix(
            "> A lonely quote",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .paragraph("> A lonely quote"))
    }

    // MARK: - Divider tests

    func testDividerStabilized() {
        let result = splitter.splitStablePrefix(
            "---\n\nnext",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [.divider])
        XCTAssertEqual(result.tail, .paragraph("next"))
    }

    // MARK: - Table tests

    func testIncompleteTableBecomesTail() {
        let result = splitter.splitStablePrefix(
            "| Name | Value |",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        if case let .incompleteTable(lines) = result.tail {
            XCTAssertEqual(lines, ["| Name | Value |"])
        } else {
            XCTFail("Expected incompleteTable tail, got \(result.tail)")
        }
    }

    func testCompleteTableStabilized() {
        let input = """
        | Name | Value |
        | --- | --- |
        | Alpha | 1.0 |
        | Beta | 2.0 |

        After table.
        """

        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks.count, 1)
        if case let .table(rows) = result.newBlocks[0] {
            XCTAssertEqual(rows.count, 3) // header + 2 data rows
            XCTAssertEqual(rows[0], ["Name", "Value"])
        } else {
            XCTFail("Expected table, got \(result.newBlocks[0])")
        }
    }

    // MARK: - Math block tests

    func testDisplayMathDetectedNotStableAtEOF() {
        let result = splitter.splitStablePrefix(
            "$$\nE = mc^2",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        // Open math delimiter without closing — unsafe plain
        XCTAssertEqual(result.tail, .unsafePlain("$$\nE = mc^2"))
    }

    // MARK: - Index recovery tests

    func testStaleCommittedIndexReset() {
        let oldText = "old string"
        let oldResult = splitter.splitStablePrefix(oldText, committedEndIndex: nil)
        let oldEnd = oldResult.newCommittedEndIndex

        // Use the index from oldText on a new string — should reset
        let result = splitter.splitStablePrefix(
            "new text\n\nafter",
            committedEndIndex: oldEnd
        )

        // Should have parsed from scratch
        XCTAssertEqual(result.newBlocks, [.paragraph(content: "new text")])
        XCTAssertEqual(result.tail, .paragraph("after"))
    }

    func testCommittedEndIndexRespected() {
        // First pass: stabilize first paragraph
        let first = splitter.splitStablePrefix(
            "First paragraph.\n\nSecond paragraph.\n\nthird",
            committedEndIndex: nil
        )

        XCTAssertEqual(first.newBlocks.count, 2)
        XCTAssertEqual(first.tail, .paragraph("third"))

        // Second pass: nothing new yet
        let second = splitter.splitStablePrefix(
            "First paragraph.\n\nSecond paragraph.\n\nthird",
            committedEndIndex: first.newCommittedEndIndex
        )

        XCTAssertEqual(second.newBlocks, [])
        XCTAssertEqual(second.tail, .paragraph("third"))

        // Third pass: more content arrived
        let third = splitter.splitStablePrefix(
            "First paragraph.\n\nSecond paragraph.\n\nthird part\n\nfourth",
            committedEndIndex: first.newCommittedEndIndex
        )

        XCTAssertEqual(third.newBlocks, [.paragraph(content: "third part")])
        XCTAssertEqual(third.tail, .paragraph("fourth"))
    }

    // MARK: - Multiple blocks

    func testMultipleBlocksInOneSplit() {
        let input = """
        # Title

        Paragraph one.

        - bullet a
        - bullet b

        Final paragraph.
        """

        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks.count, 3)
        XCTAssertEqual(result.newBlocks[0], .heading(level: 1, content: "Title"))
        XCTAssertEqual(result.newBlocks[1], .paragraph(content: "Paragraph one."))
        if case let .unorderedList(items) = result.newBlocks[2] {
            XCTAssertEqual(items, ["bullet a", "bullet b"])
        } else {
            XCTFail("Expected unorderedList at index 2, got \(result.newBlocks[2])")
        }
        // Final paragraph is at EOF → not stable, stays in tail
        XCTAssertEqual(result.tail, .paragraph("Final paragraph."))
    }

    // MARK: - Empty and edge cases

    func testEmptyInput() {
        let result = splitter.splitStablePrefix("", committedEndIndex: nil)

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .empty)
    }

    func testOnlyWhitespace() {
        let result = splitter.splitStablePrefix(
            "   \n\n   \n",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .empty)
    }

    func testUTF16OffsetTracking() {
        let input = "Hello\n\nworld"
        let result = splitter.splitStablePrefix(input, committedEndIndex: nil)

        XCTAssertEqual(result.newCommittedUTF16Offset, 7) // "Hello\n\n" in UTF-16
    }

    // MARK: - Unsafe construct tests

    func testPartialMathDelimiterUnsafe() {
        let result = splitter.splitStablePrefix(
            "The formula $E = mc^2",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .unsafePlain("The formula $E = mc^2"))
    }

    func testOpenHTMLTagUnsafe() {
        let result = splitter.splitStablePrefix(
            "Here is <div",
            committedEndIndex: nil
        )

        XCTAssertEqual(result.newBlocks, [])
        XCTAssertEqual(result.tail, .unsafePlain("Here is <div"))
    }
}
