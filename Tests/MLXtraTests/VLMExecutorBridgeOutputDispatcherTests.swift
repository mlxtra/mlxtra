import XCTest
@testable import MLXtra

final class VLMExecutorBridgeOutputDispatcherTests: XCTestCase {
    func testOutputProcessorDispatchesSplitStdoutJSON() {
        let dispatcher = BridgeOutputDispatcher()
        let processor = VLMBridgeOutputProcessor(
            dispatcher: dispatcher,
            stderrBuffer: BridgeStderrBuffer(maxLines: 4)
        )
        let readyExpectation = expectation(description: "ready message dispatched")
        let line = #"{"type":"system.ready","message":"hello 🌍"}"#
        var data = Data(line.utf8)
        data.append(0x0A)
        let splitIndex = data.firstIndex(of: 0xF0) ?? data.startIndex

        dispatcher.register(
            shouldHandle: { json in
                json["type"] as? String == "system.ready"
            }
        ) { json in
            XCTAssertEqual(json["message"] as? String, "hello 🌍")
            readyExpectation.fulfill()
        }

        processor.appendStdout(Data(data[..<data.index(splitIndex, offsetBy: 2)]))
        processor.appendStdout(Data(data[data.index(splitIndex, offsetBy: 2)...]))

        wait(for: [readyExpectation], timeout: 0.5)
    }

    func testOutputProcessorFlushesTrailingStdoutAndSignalsEOF() {
        let dispatcher = BridgeOutputDispatcher()
        let processor = VLMBridgeOutputProcessor(
            dispatcher: dispatcher,
            stderrBuffer: BridgeStderrBuffer(maxLines: 4)
        )
        let readyExpectation = expectation(description: "trailing message dispatched")
        let eofExpectation = expectation(description: "EOF handler called")

        dispatcher.register(
            shouldHandle: { json in
                json["type"] as? String == "system.ready"
            },
            onEOF: {
                eofExpectation.fulfill()
            }
        ) { _ in
            readyExpectation.fulfill()
        }

        processor.appendStdout(Data(#"{"type":"system.ready"}"#.utf8))
        processor.finishStdout()

        wait(for: [readyExpectation, eofExpectation], timeout: 0.5)
    }

    func testOutputProcessorBuffersSplitStderrUTF8() {
        let stderrBuffer = BridgeStderrBuffer(maxLines: 4)
        let processor = VLMBridgeOutputProcessor(
            dispatcher: BridgeOutputDispatcher(),
            stderrBuffer: stderrBuffer
        )
        let data = Data("trace 🌍 line\n".utf8)
        let splitIndex = data.firstIndex(of: 0xF0) ?? data.startIndex

        processor.appendStderr(Data(data[..<data.index(splitIndex, offsetBy: 2)]))
        processor.appendStderr(Data(data[data.index(splitIndex, offsetBy: 2)...]))

        XCTAssertEqual(stderrBuffer.summary(), "trace 🌍 line")
    }

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
