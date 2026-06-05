import Foundation

typealias BridgeJSONMessage = [String: Any]

func bridgeDouble(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value.isFinite ? value : nil
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? NSNumber {
        let doubleValue = value.doubleValue
        return doubleValue.isFinite ? doubleValue : nil
    }
    return nil
}

struct BridgeOutputRoute {
    let requestID: String?
    let shouldHandle: @Sendable (BridgeJSONMessage) -> Bool
    let onEOF: @Sendable () -> Void
    let handler: @Sendable (BridgeJSONMessage) -> Void
}

final class BridgeOutputDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [UUID: BridgeOutputRoute] = [:]

    @discardableResult
    func register(
        id: UUID = UUID(),
        requestID: String? = nil,
        shouldHandle: @escaping @Sendable (BridgeJSONMessage) -> Bool = { _ in true },
        onEOF: @escaping @Sendable () -> Void = {},
        handler: @escaping @Sendable (BridgeJSONMessage) -> Void
    ) -> UUID {
        lock.lock()
        routes[id] = BridgeOutputRoute(
            requestID: requestID,
            shouldHandle: shouldHandle,
            onEOF: onEOF,
            handler: handler
        )
        lock.unlock()
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock()
        routes.removeValue(forKey: id)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        routes.removeAll()
        lock.unlock()
    }

    func dispatch(_ json: BridgeJSONMessage) {
        let requestID = json["request_id"] as? String
        let routes = snapshotRoutes()

        for route in routes {
            if let routeRequestID = route.requestID {
                guard routeRequestID == requestID else { continue }
            } else if requestID != nil {
                continue
            }

            if route.shouldHandle(json) {
                route.handler(json)
            }
        }
    }

    func handleEOF() {
        for route in snapshotRoutes() {
            route.onEOF()
        }
    }

    private func snapshotRoutes() -> [BridgeOutputRoute] {
        lock.lock()
        let routes = Array(routes.values)
        lock.unlock()
        return routes
    }
}

final class BridgeStderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxLines: Int
    private var lines: [String] = []

    init(maxLines: Int) {
        self.maxLines = max(1, maxLines)
    }

    func append(_ line: String) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }

        lock.lock()
        lines.append(trimmedLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    func summary() -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        return snapshot.joined(separator: "\n")
    }
}

final class BridgeLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ output: String) -> [String] {
        append(Data(output.utf8))
    }

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        pending.append(data)
        var lines: [String] = []

        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending[..<newlineIndex]
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newlineIndex)

            if !line.isEmpty {
                lines.append(line)
            }
        }

        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard !pending.isEmpty else { return nil }
        let line = String(decoding: pending, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pending.removeAll(keepingCapacity: true)
        return line.isEmpty ? nil : line
    }
}

final class VLMBridgeOutputProcessor: @unchecked Sendable {
    private let dispatcher: BridgeOutputDispatcher
    private let stdoutLineBuffer = BridgeLineBuffer()
    private let stderrLineBuffer = BridgeLineBuffer()
    private let stderrBuffer: BridgeStderrBuffer
    private let log: @Sendable (String) -> Void

    init(
        dispatcher: BridgeOutputDispatcher,
        stderrBuffer: BridgeStderrBuffer,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dispatcher = dispatcher
        self.stderrBuffer = stderrBuffer
        self.log = log
    }

    func appendStdout(_ data: Data) {
        for line in stdoutLineBuffer.append(data) {
            processStdoutLine(line)
        }
    }

    func finishStdout() {
        if let line = stdoutLineBuffer.flush() {
            processStdoutLine(line)
        }
        dispatcher.handleEOF()
    }

    func appendStderr(_ data: Data) {
        for line in stderrLineBuffer.append(data) {
            processStderrLine(line)
        }
    }

    func finishStderr() {
        if let line = stderrLineBuffer.flush() {
            processStderrLine(line)
        }
    }

    private func processStdoutLine(_ line: String) {
        log("[VLMExecutor] Received: \(line.prefix(200))...")

        do {
            guard let lineData = line.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: lineData) as? BridgeJSONMessage else {
                log("[VLMExecutor] Could not parse JSON or missing type field")
                return
            }
            dispatcher.dispatch(json)
        } catch {
            log("[VLMExecutor] Parse error: \(error)")
        }
    }

    private func processStderrLine(_ line: String) {
        stderrBuffer.append(line)
        if DiagnosticsLogStore.isVerboseBridgeLoggingEnabled {
            DiagnosticsLogStore.log(line, category: .bridge, level: .debug)
        }
        log("[Python STDERR] \(line)")
    }
}

enum VLMBridgeRequestWriter {
    static func lineData(for payload: BridgeJSONMessage) throws -> Data {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw ExecutionError.encodingFailed
        }

        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw ExecutionError.encodingFailed
        }

        data.append(0x0A)
        return data
    }

    static func write(
        _ payload: BridgeJSONMessage,
        to fileHandle: FileHandle,
        processIsRunning: () -> Bool?,
        stoppedProcessError: () -> ExecutionError
    ) throws {
        try write(
            payload,
            write: { data in
                try fileHandle.write(contentsOf: data)
            },
            processIsRunning: processIsRunning,
            stoppedProcessError: stoppedProcessError
        )
    }

    static func write(
        _ payload: BridgeJSONMessage,
        write: (Data) throws -> Void,
        processIsRunning: () -> Bool?,
        stoppedProcessError: () -> ExecutionError
    ) throws {
        let lineData = try lineData(for: payload)

        do {
            try write(lineData)
        } catch {
            guard processIsRunning() == true else {
                throw stoppedProcessError()
            }
            throw ExecutionError.pipeWriteFailed(error.localizedDescription)
        }
    }
}

final class ResponseBuilder: @unchecked Sendable {
    private var parts: [String] = []
    private let lock = NSLock()

    var fullResponse: String {
        lock.lock()
        defer { lock.unlock() }
        return parts.joined()
    }

    func append(_ token: String) {
        lock.lock()
        parts.append(token)
        lock.unlock()
    }
}
