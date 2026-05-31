import Foundation

/// Thread-safe bridge-ready state for sync access from output handlers.
final class ReadyState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isReady = false
    private var _errorMessage: String?

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isReady
    }

    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return _errorMessage
    }

    func setReady() {
        lock.lock()
        defer { lock.unlock() }
        _isReady = true
    }

    func setError(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        _errorMessage = message
    }
}

struct ReadyWaiter {
    let state: ReadyState
    let handlerID: UUID
}

/// Thread-safe model-loaded state for sync access from output handlers.
final class ModelLoadedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isLoaded: Bool = false
    private var _errorMessage: String?
    private var pendingProgress: [ModelLoadProgress] = []

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isLoaded
    }

    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return _errorMessage
    }

    func setLoaded() {
        lock.lock()
        defer { lock.unlock() }
        _isLoaded = true
    }

    func setError(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        _errorMessage = message
    }

    func appendProgress(_ progress: ModelLoadProgress) {
        lock.lock()
        pendingProgress.append(progress)
        lock.unlock()
    }

    func drainProgress() -> [ModelLoadProgress] {
        lock.lock()
        defer { lock.unlock() }
        let progress = pendingProgress
        pendingProgress.removeAll(keepingCapacity: true)
        return progress
    }
}

struct ModelLoadWaiter {
    let state: ModelLoadedState
    let handlerID: UUID
}

struct ResponseStreamHandle {
    let stream: AsyncStream<ExecutionEvent>
    let handlerID: UUID
}

final class StreamFinishState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !finished else { return false }
        finished = true
        return true
    }
}
