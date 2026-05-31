import Foundation

final class DownloadUTF8Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        guard let output = String(data: buffer, encoding: .utf8) else {
            return nil
        }
        buffer.removeAll(keepingCapacity: true)
        return output
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else { return nil }
        let output = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return output
    }
}

private final class DownloadOutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private let maxCharacters: Int

    init(maxCharacters: Int = 40_000) {
        self.maxCharacters = maxCharacters
    }

    func append(_ newText: String) {
        lock.lock()
        defer { lock.unlock() }
        text += newText
        if text.count > maxCharacters {
            text = String(text.suffix(maxCharacters))
        }
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

private final class DownloadProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class DownloadContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<DownloadHelperProcessResult, Error>

    init(_ continuation: CheckedContinuation<DownloadHelperProcessResult, Error>) {
        self.continuation = continuation
    }

    func resume(returning result: DownloadHelperProcessResult) {
        guard markResumed() else { return }
        continuation.resume(returning: result)
    }

    func resume(throwing error: Error) {
        guard markResumed() else { return }
        continuation.resume(throwing: error)
    }

    private func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

struct DownloadHelperProcessResult {
    let output: String
    let errorOutput: String
    let terminationStatus: Int32
}

enum DownloadHelperProcessRunner {
    @MainActor
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onProcessStarted: @escaping @MainActor (Process) -> Void
    ) async throws -> DownloadHelperProcessResult {
        let processBox = DownloadProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DownloadHelperProcessResult, Error>) in
                let completion = DownloadContinuationBox(continuation)
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let outputDecoder = DownloadUTF8Buffer()
                let errorDecoder = DownloadUTF8Buffer()
                let outputLog = DownloadOutputLog()
                let errorLog = DownloadOutputLog()

                process.executableURL = executableURL
                process.arguments = arguments
                process.environment = environment
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                processBox.set(process)

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let output = outputDecoder.append(data) else { return }

                    outputLog.append(output)
                }

                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let output = errorDecoder.append(data) else { return }

                    errorLog.append(output)
                }

                process.terminationHandler = { process in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    processBox.clear()

                    let trailingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if !trailingData.isEmpty, let trailingOutput = outputDecoder.append(trailingData) {
                        outputLog.append(trailingOutput)
                    }
                    if let decodedOutput = outputDecoder.flush() {
                        outputLog.append(decodedOutput)
                    }

                    let errorTrailingData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if !errorTrailingData.isEmpty, let trailingErrorOutput = errorDecoder.append(errorTrailingData) {
                        errorLog.append(trailingErrorOutput)
                    }
                    if let decodedErrorOutput = errorDecoder.flush() {
                        errorLog.append(decodedErrorOutput)
                    }

                    completion.resume(
                        returning: DownloadHelperProcessResult(
                            output: outputLog.value(),
                            errorOutput: errorLog.value(),
                            terminationStatus: process.terminationStatus
                        )
                    )
                }

                do {
                    try process.run()
                    if Task.isCancelled {
                        process.terminate()
                    }
                    onProcessStarted(process)
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    processBox.clear()
                    completion.resume(throwing: error)
                }
            }
        } onCancel: {
            processBox.terminate()
        }
    }
}
