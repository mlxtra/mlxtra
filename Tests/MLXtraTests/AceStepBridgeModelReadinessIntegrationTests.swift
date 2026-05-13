import XCTest
@testable import MLXtra

final class AceStepBridgeModelReadinessIntegrationTests: XCTestCase {

    private var tempDirectory: URL!

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
    }

    override func tearDown() {
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    func test_modelLoadingSentBeforeModelLoaded() {
        let mockScript = """
        import json
        import time
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        send_json({"type": "model.loading", "model": "test", "status": "loading"})
        time.sleep(0.3)
        send_json({"type": "model.loaded", "model": "test"})

        sys.stdin.readline()
        """

        let scriptPath = tempDirectory.appendingPathComponent("mock_model_ready.py")
        try? mockScript.write(to: scriptPath, atomically: true, encoding: .utf8)

        let startTime = Date()
        let stdout = runProcessBridge(path: scriptPath.path)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertTrue(elapsed >= 0.3, "Should have waited for delay, took \(elapsed)s")
        XCTAssertTrue(stdout.contains("model.loading"), "Should send model.loading first, got: \(stdout)")
        XCTAssertTrue(stdout.contains("model.loaded"), "Should eventually send model.loaded, got: \(stdout)")
    }

    func test_waitingForModelsStatusSentBeforeLoaded() {
        let mockScript = """
        import json
        import time
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        send_json({"type": "model.loading", "model": "test", "status": "loading"})
        send_json({"type": "model.loading", "model": "test", "status": "waiting_for_models"})
        time.sleep(0.3)
        send_json({"type": "model.loaded", "model": "test"})

        sys.stdin.readline()
        """

        let scriptPath = tempDirectory.appendingPathComponent("mock_waiting_status.py")
        try? mockScript.write(to: scriptPath, atomically: true, encoding: .utf8)

        let stdout = runProcessBridge(path: scriptPath.path)

        let loadingIdx = stdout.range(of: "model.loading")
        let waitingIdx = stdout.range(of: "waiting_for_models")
        let loadedIdx = stdout.range(of: "model.loaded")

        XCTAssertNotNil(loadingIdx, "Should have model.loading")
        XCTAssertNotNil(waitingIdx, "Should have waiting_for_models status")
        XCTAssertNotNil(loadedIdx, "Should have model.loaded")

        if let lIdx = loadingIdx, let wIdx = waitingIdx {
            XCTAssertTrue(lIdx.lowerBound < wIdx.lowerBound, "loading should come before waiting_for_models")
        }
        if let wIdx = waitingIdx, let dIdx = loadedIdx {
            XCTAssertTrue(wIdx.lowerBound < dIdx.lowerBound, "waiting_for_models should come before model.loaded")
        }
    }

    func test_componentsReadyStatusShownBeforeModelLoaded() {
        let mockScript = """
        import json
        import time
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        send_json({"type": "model.loading", "model": "test", "status": "loading"})
        send_json({"type": "model.loading", "model": "test", "status": "components_ready"})
        time.sleep(0.3)
        send_json({"type": "model.loaded", "model": "test"})

        sys.stdin.readline()
        """

        let scriptPath = tempDirectory.appendingPathComponent("mock_components_ready.py")
        try? mockScript.write(to: scriptPath, atomically: true, encoding: .utf8)

        let stdout = runProcessBridge(path: scriptPath.path)

        XCTAssertTrue(stdout.contains("components_ready"),
                     "Should show components_ready status before model.loaded, got: \(stdout)")
    }

    func test_errorMessageSentOnFailure() {
        let mockScript = """
        import json
        import sys

        def send_json(obj):
            print(json.dumps(obj), flush=True)

        send_json({"type": "error", "message": "Timeout waiting for model components to load"})

        sys.stdin.readline()
        """

        let scriptPath = tempDirectory.appendingPathComponent("mock_error.py")
        try? mockScript.write(to: scriptPath, atomically: true, encoding: .utf8)

        let stdout = runProcessBridge(path: scriptPath.path)

        XCTAssertTrue(stdout.contains("error"), "Should have error message, got: \(stdout)")
        XCTAssertTrue(stdout.contains("Timeout"), "Should have specific error message, got: \(stdout)")
    }

    private func runProcessBridge(path: String) -> String {
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

        // Write input then close
        let inputData = "done\n".data(using: .utf8)!
        inputPipe.fileHandleForWriting.write(inputData)
        inputPipe.fileHandleForWriting.closeFile()

        // Use a semaphore to wait for process to complete without blocking async
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
        stdout.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
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
