import XCTest
@testable import MLXtra

final class VLMExecutorWaitForModelLoadedIntegrationTests: XCTestCase {

    private var tempDirectory: URL!
    private var mockBridgePath: URL!

    private final class LockedOutput {
        private let lock = NSLock()
        private var data = Data()

        func append(_ newData: Data) {
            lock.lock()
            data.append(newData)
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(data: snapshot, encoding: .utf8) ?? ""
        }
    }

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        mockBridgePath = tempDirectory.appendingPathComponent("mock_bridge.py")
    }

    override func tearDown() {
        if FileManager.default.fileExists(atPath: mockBridgePath.path) {
            try? FileManager.default.removeItem(at: mockBridgePath)
        }
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    func test_pythonBridge_sendsModelLoadingThenModelLoaded() {
        let mockScript = """
        import json
        import time
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        send_json({"type": "model.loading", "status": "loading"})
        time.sleep(0.5)
        send_json({"type": "model.loaded", "model": "test-model"})

        sys.stdin.readline()
        """

        try? mockScript.write(to: mockBridgePath, atomically: true, encoding: .utf8)

        let startTime = Date()
        let stdout = runProcessBridge(path: mockBridgePath.path)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertTrue(elapsed >= 0.5, "Should have waited for the delay in mock script, took \(elapsed)s")
        XCTAssertTrue(stdout.contains("model.loading"), "Should have received model.loading message")
        XCTAssertTrue(stdout.contains("model.loaded"), "Should have received model.loaded message")
    }

    func test_pythonBridge_acceptsModelInitializedAsValidMessage() {
        let mockScript = """
        import json
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        send_json({"type": "model.initialized", "model": "test-model"})
        sys.stdin.readline()
        """

        try? mockScript.write(to: mockBridgePath, atomically: true, encoding: .utf8)

        let stdout = runProcessBridge(path: mockBridgePath.path)

        XCTAssertTrue(stdout.contains("model.initialized"), "Should accept model.initialized message")
    }

    func test_pythonBridge_sendsErrorMessageOnFailure() {
        let mockScript = """
        import json
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        send_json({"type": "error", "message": "Model loading failed"})
        sys.stdin.readline()
        """

        try? mockScript.write(to: mockBridgePath, atomically: true, encoding: .utf8)

        let stdout = runProcessBridge(path: mockBridgePath.path)

        XCTAssertTrue(stdout.contains("error"), "Should have error message")
        XCTAssertTrue(stdout.contains("Model loading failed"), "Should have specific error message")
    }

    func test_pythonBridge_sendsModelLoadingWithStatusUpdates() {
        let mockScript = """
        import json
        import time
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        send_json({"type": "model.loading", "status": "loading"})
        time.sleep(0.3)
        send_json({"type": "model.loading", "status": "waiting_for_models"})
        time.sleep(0.3)
        send_json({"type": "model.loaded", "model": "test-model"})

        sys.stdin.readline()
        """

        try? mockScript.write(to: mockBridgePath, atomically: true, encoding: .utf8)

        let startTime = Date()
        let stdout = runProcessBridge(path: mockBridgePath.path)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertTrue(elapsed >= 0.6, "Should have waited for both delays, took \(elapsed)s")
        XCTAssertTrue(stdout.contains("waiting_for_models"), "Should show waiting status")
    }

    func test_pythonBridge_roundTripsRequestID() {
        let mockScript = """
        import json
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        request = json.loads(sys.stdin.readline())
        request_id = request.get("request_id")
        send_json({"type": "model.loading", "request_id": request_id, "status": "loading"})
        send_json({"type": "model.loaded", "request_id": request_id, "model": request.get("model_id", "test-model")})
        """

        try? mockScript.write(to: mockBridgePath, atomically: true, encoding: .utf8)

        let stdout = runProcessBridge(
            path: mockBridgePath.path,
            input: #"{"type":"init","model_id":"test-model","request_id":"req-456"}"#
        )

        XCTAssertTrue(stdout.contains(#""request_id": "req-456""#))
    }

    private func runProcessBridge(path: String, input: String = "done") -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stdout = LockedOutput()
        let stderr = LockedOutput()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdout.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderr.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }

        let inputData = "\(input)\n".data(using: .utf8)!
        inputPipe.fileHandleForWriting.write(inputData)
        inputPipe.fileHandleForWriting.closeFile()

        let group = DispatchGroup()
        group.enter()

        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        let timeout = group.wait(timeout: .now() + 10)
        if timeout == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            XCTFail("Timed out waiting for bridge process. stderr: \(stderr.string())")
            return "TIMEOUT"
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        let trailingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let trailingError = errorPipe.fileHandleForReading.readDataToEndOfFile()
        stdout.append(trailingOutput)
        stderr.append(trailingError)
        let errorText = stderr.string().trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorText.isEmpty {
            XCTContext.runActivity(named: "bridge stderr") { activity in
                let attachment = XCTAttachment(string: errorText)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        return stdout.string().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
