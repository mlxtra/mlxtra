import Foundation

struct StreamingFileDownloadResult {
    let response: URLResponse
    let bytesWritten: Int64
}

final class StreamingFileDownloader {
    typealias ResponseValidator = @Sendable (URLResponse) throws -> Void
    typealias ErrorPolicy = @Sendable (Error) -> Bool
    typealias RetryDelay = @Sendable (Int) async throws -> Void

    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private let maxAttempts: Int
    private let shouldRetry: ErrorPolicy
    private let shouldPreservePartial: ErrorPolicy
    private let retryDelay: RetryDelay

    init(
        configuration: URLSessionConfiguration = .default,
        fileManager: FileManager = .default,
        maxAttempts: Int = 1,
        shouldRetry: @escaping ErrorPolicy = { _ in false },
        shouldPreservePartial: @escaping ErrorPolicy = { _ in false },
        retryDelay: @escaping RetryDelay = { _ in }
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.maxAttempts = max(1, maxAttempts)
        self.shouldRetry = shouldRetry
        self.shouldPreservePartial = shouldPreservePartial
        self.retryDelay = retryDelay
    }

    func download(
        request: URLRequest,
        destinationURL: URL,
        temporaryURL: URL? = nil,
        expectedBytes: Int64? = nil,
        validateResponse: @escaping ResponseValidator = { _ in },
        onProgress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> StreamingFileDownloadResult {
        let temporaryURL = temporaryURL ?? Self.partialDownloadURL(for: destinationURL)
        try fileManager.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var attempt = 0
        var lastError: Error?
        while attempt < maxAttempts {
            attempt += 1
            let resumeOffset = Self.resumableDownloadSize(
                at: temporaryURL,
                expectedBytes: expectedBytes,
                fileManager: fileManager
            )
            if resumeOffset > 0 {
                onProgress(resumeOffset)
            }

            let stream = StreamingFileDownload(
                request: request,
                temporaryURL: temporaryURL,
                resumeOffset: resumeOffset,
                configuration: configuration,
                fileManager: fileManager,
                onProgress: onProgress
            )

            do {
                let result = try await stream.start()
                try validateResponse(result.response)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                if let expectedBytes {
                    onProgress(expectedBytes)
                }
                return result
            } catch {
                lastError = error
                let retry = shouldRetry(error)
                if !retry && !shouldPreservePartial(error) {
                    try? fileManager.removeItem(at: temporaryURL)
                }
                guard retry, attempt < maxAttempts else {
                    throw error
                }
                try await retryDelay(attempt)
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    static func partialDownloadURL(for destinationURL: URL) -> URL {
        destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).download")
    }

    static func resumableDownloadSize(
        at partialURL: URL,
        expectedBytes: Int64?,
        fileManager: FileManager = .default
    ) -> Int64 {
        guard let partialSize = fileSize(partialURL, fileManager: fileManager), partialSize > 0 else {
            return 0
        }

        if let expectedBytes, partialSize >= expectedBytes {
            try? fileManager.removeItem(at: partialURL)
            return 0
        }

        return partialSize
    }

    static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        return [
            .networkConnectionLost,
            .timedOut,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ].contains(urlError.code)
    }

    static func shouldPreservePartialDownload(after error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        return urlError.code == .cancelled || isTransientNetworkError(error)
    }

    static func fileSize(_ url: URL, fileManager: FileManager = .default) -> Int64? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }
}

final class StreamingFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let baseRequest: URLRequest
    private let temporaryURL: URL
    private let resumeOffset: Int64
    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private let onProgress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<StreamingFileDownloadResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var response: URLResponse?
    private var bytesWritten: Int64 = 0
    private var isCompleted = false

    init(
        request: URLRequest,
        temporaryURL: URL,
        resumeOffset: Int64,
        configuration: URLSessionConfiguration,
        fileManager: FileManager = .default,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) {
        self.baseRequest = request
        self.temporaryURL = temporaryURL
        self.resumeOffset = max(0, resumeOffset)
        self.configuration = configuration
        self.fileManager = fileManager
        self.onProgress = onProgress
    }

    func start() async throws -> StreamingFileDownloadResult {
        try preparePartialFile()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request())
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func preparePartialFile() throws {
        try fileManager.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if resumeOffset == 0 || !fileManager.fileExists(atPath: temporaryURL.path) {
            try Data().write(to: temporaryURL, options: [.atomic])
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.seekToEnd()

        lock.lock()
        fileHandle = handle
        bytesWritten = resumeOffset
        lock.unlock()
    }

    private func request() -> URLRequest {
        var request = baseRequest
        if resumeOffset > 0,
           request.value(forHTTPHeaderField: "Range") == nil {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var restartError: Error?
        let shouldRestartFromZero = resumeOffset > 0
            && (response as? HTTPURLResponse)?.statusCode == 200
        lock.lock()
        self.response = response
        if shouldRestartFromZero {
            do {
                bytesWritten = 0
                try fileHandle?.truncate(atOffset: 0)
                try fileHandle?.seek(toOffset: 0)
            } catch {
                restartError = error
            }
        }
        lock.unlock()

        if let restartError {
            complete(.failure(restartError))
            completionHandler(.cancel)
            return
        }

        if shouldRestartFromZero {
            onProgress(0)
        }

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            let emittedBytes = try appendDownloadedData(data)
            onProgress(emittedBytes)
        } catch {
            complete(.failure(error))
            dataTask.cancel()
        }
    }

    private func appendDownloadedData(_ data: Data) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        guard let fileHandle else {
            throw URLError(.cannotWriteToFile)
        }
        try fileHandle.write(contentsOf: data)
        bytesWritten += Int64(data.count)
        return bytesWritten
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(.failure(error))
            return
        }

        lock.lock()
        let response = self.response
        let bytesWritten = self.bytesWritten
        lock.unlock()

        guard let response else {
            complete(.failure(URLError(.badServerResponse)))
            return
        }

        complete(.success(StreamingFileDownloadResult(response: response, bytesWritten: bytesWritten)))
    }

    private func complete(_ result: Result<StreamingFileDownloadResult, Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let continuation = self.continuation
        self.continuation = nil
        let fileHandle = self.fileHandle
        self.fileHandle = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        try? fileHandle?.close()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
