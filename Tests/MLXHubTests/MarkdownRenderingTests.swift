import XCTest
@testable import MLXHub

final class MarkdownRenderingTests: XCTestCase {
    func testAssistantTextUsesFastPlainRendererByDefault() {
        XCTAssertTrue(AIContentRenderingPolicy.shouldUseFastPlainText(for: "Short answer."))
    }

    func testParserRecognizesDisplayMathBlocks() {
        let blocks = MarkdownParser.parseBlocks(
            """
            Intro

            $$
            E = mc^2
            $$
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .paragraph(content: "Intro"),
                .mathBlock(content: "E = mc^2")
            ]
        )
    }

    func testParserBuildsStructuredTables() {
        let blocks = MarkdownParser.parseBlocks(
            """
            | Name | Value |
            | --- | --- |
            | TTFT | 0.21s |
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .table(rows: [
                    ["Name", "Value"],
                    ["TTFT", "0.21s"]
                ])
            ]
        )
    }

    func testInlineSegmentsSplitLatexWithoutDroppingMarkdownText() {
        let segments = MarkdownParser.inlineSegments("Use **energy** $E = mc^2$ now.")

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

        XCTAssertEqual(rendered, "1⁄2 × x₁² ≤ √(9)")
    }
}
