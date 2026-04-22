import XCTest
@testable import MLXHub

final class VLMExecutorBridgeOutputDispatcherTests: XCTestCase {
    func testDispatcherRoutesMessagesByRequestID() {
        let dispatcher = BridgeOutputDispatcher()
        let matchingExpectation = expectation(description: "matching route called")
        let nonMatchingExpectation = expectation(description: "non matching route not called")
        nonMatchingExpectation.isInverted = true

        dispatcher.register(requestID: "req-1") { json in
            XCTAssertEqual(json["request_id"] as? String, "req-1")
            matchingExpectation.fulfill()
        }
        dispatcher.register(requestID: "req-2") { _ in
            nonMatchingExpectation.fulfill()
        }

        dispatcher.dispatch(["type": "chat.completion.chunk", "request_id": "req-1"])

        wait(for: [matchingExpectation, nonMatchingExpectation], timeout: 0.5)
    }

    func testDispatcherRoutesRequestlessMessagesToGlobalHandlersOnly() {
        let dispatcher = BridgeOutputDispatcher()
        let globalExpectation = expectation(description: "global route called")
        let requestBoundExpectation = expectation(description: "request route not called")
        requestBoundExpectation.isInverted = true

        dispatcher.register(
            shouldHandle: { json in
                json["type"] as? String == "system.ready"
            }
        ) { _ in
            globalExpectation.fulfill()
        }
        dispatcher.register(requestID: "req-1") { _ in
            requestBoundExpectation.fulfill()
        }

        dispatcher.dispatch(["type": "system.ready"])

        wait(for: [globalExpectation, requestBoundExpectation], timeout: 0.5)
    }

    func testDispatcherNotifiesEOFHandlers() {
        let dispatcher = BridgeOutputDispatcher()
        let eofExpectation = expectation(description: "EOF handler called")

        dispatcher.register(
            requestID: "req-1",
            onEOF: {
                eofExpectation.fulfill()
            }
        ) { _ in
            XCTFail("Did not expect normal handler during EOF notification")
        }

        dispatcher.handleEOF()

        wait(for: [eofExpectation], timeout: 0.5)
    }
}
