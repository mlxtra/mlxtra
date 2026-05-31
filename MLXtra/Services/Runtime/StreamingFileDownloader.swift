import Foundation

struct StreamingFileDownloadResult {
    let response: URLResponse
    let bytesWritten: Int64
}

final class StreamingFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let baseRequest: URLRequest
    private let temporaryURL: URL
    private let resumeOffset: Int64
    private let configuration: URLSessionConfiguration
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
        onProgress: @escaping @Sendable (Int64) -> Void
    ) {
        self.baseRequest = request
        self.temporaryURL = temporaryURL
        self.resumeOffset = max(0, resumeOffset)
        self.configuration = configuration
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
        try FileManager.default.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if resumeOffset == 0 || !FileManager.default.fileExists(atPath: temporaryURL.path) {
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
