import XCTest
@testable import MLXtra

final class ReasoningContentFilterTests: XCTestCase {
    func testCompleteThinkTagsAreRemoved() {
        let text = """
        <think>
        Internal reasoning.
        </think>
        Final answer.
        """

        XCTAssertEqual(ReasoningContentFilter.visibleText(from: text), "Final answer.")
    }

    func testIncompleteThinkTagHidesStreamingReasoning() {
        let text = "<think>\nInternal reasoning still streaming"

        XCTAssertNil(ReasoningContentFilter.visibleText(from: text))
    }

    func testOrphanClosingThinkTagKeepsOnlyVisibleAnswer() {
        let text = """
        Internal reasoning leaked from the model.
        </think>
        I can help with that.
        """

        XCTAssertEqual(ReasoningContentFilter.visibleText(from: text), "I can help with that.")
    }

    func testThinkingAliasIsRemoved() {
        let text = "<thinking>hidden</thinking>\nVisible response"

        XCTAssertEqual(ReasoningContentFilter.visibleText(from: text), "Visible response")
    }
}
