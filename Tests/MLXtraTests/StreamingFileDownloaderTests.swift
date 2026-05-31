import XCTest
@testable import MLXtra

final class StreamingFileDownloaderTests: XCTestCase {
    func testRetriesTransientFailureAndResumesPartialFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data([1, 2, 3, 4, 5, 6])
        StreamingDownloaderURLProtocol.reset(
            data: payload,
            failFirstRequestBeforeResponse: true
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingDownloaderURLProtocol.self]
        let destinationURL = directory.appendingPathComponent("model.bin")
        let temporaryURL = StreamingFileDownloader.partialDownloadURL(for: destinationURL)
        try FileManager.default.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2]).write(to: temporaryURL)
        let progress = Int64Recorder()

        let downloader = StreamingFileDownloader(
            configuration: configuration,
            maxAttempts: 2,
            shouldRetry: { StreamingFileDownloader.isTransientNetworkError($0) },
            retryDelay: { _ in }
        )

        let result = try await downloader.download(
            request: URLRequest(url: URL(string: "https://stream.test/model.bin")!),
            destinationURL: destinationURL,
            expectedBytes: Int64(payload.count),
            onProgress: { bytesWritten in
                progress.append(bytesWritten)
            }
        )

        XCTAssertEqual(result.bytesWritten, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: destinationURL), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertEqual(StreamingDownloaderURLProtocol.recordedRangeHeaders(), ["bytes=2-", "bytes=2-"])
        XCTAssertTrue(progress.values().contains(2))
        XCTAssertEqual(progress.values().last, Int64(payload.count))
    }

    func testRemovesPartialFileWhenResponseValidationFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        StreamingDownloaderURLProtocol.reset(data: Data([1, 2, 3]), statusCode: 500)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingDownloaderURLProtocol.self]
        let destinationURL = directory.appendingPathComponent("bad.bin")
        let temporaryURL = StreamingFileDownloader.partialDownloadURL(for: destinationURL)

        let downloader = StreamingFileDownloader(configuration: configuration)

        do {
            _ = try await downloader.download(
                request: URLRequest(url: URL(string: "https://stream.test/bad.bin")!),
                destinationURL: destinationURL,
                validateResponse: { response in
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                }
            )
            XCTFail("Expected response validation failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testPreservesPartialFileWhenPolicyRequestsIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        StreamingDownloaderURLProtocol.reset(
            data: Data([1, 2, 3, 4]),
            failEveryRequestWith: URLError(.cancelled)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingDownloaderURLProtocol.self]
        let destinationURL = directory.appendingPathComponent("cancelled.bin")
        let temporaryURL = StreamingFileDownloader.partialDownloadURL(for: destinationURL)
        try FileManager.default.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2]).write(to: temporaryURL)

        let downloader = StreamingFileDownloader(
            configuration: configuration,
            maxAttempts: 3,
            shouldRetry: { StreamingFileDownloader.isTransientNetworkError($0) },
            shouldPreservePartial: { StreamingFileDownloader.shouldPreservePartialDownload(after: $0) }
        )

        do {
            _ = try await downloader.download(
                request: URLRequest(url: URL(string: "https://stream.test/cancelled.bin")!),
                destinationURL: destinationURL,
                expectedBytes: 4
            )
            XCTFail("Expected cancellation failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(try Data(contentsOf: temporaryURL), Data([1, 2]))
        XCTAssertEqual(StreamingDownloaderURLProtocol.recordedRangeHeaders(), ["bytes=2-"])
    }

    func testPreservesPartialFileWhenCancellationErrorIsThrown() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data([1, 2, 3, 4])
        StreamingDownloaderURLProtocol.reset(data: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingDownloaderURLProtocol.self]
        let destinationURL = directory.appendingPathComponent("cancelled-validation.bin")
        let temporaryURL = StreamingFileDownloader.partialDownloadURL(for: destinationURL)

        let downloader = StreamingFileDownloader(
            configuration: configuration,
            shouldPreservePartial: { StreamingFileDownloader.shouldPreservePartialDownload(after: $0) }
        )

        do {
            _ = try await downloader.download(
                request: URLRequest(url: URL(string: "https://stream.test/cancelled-validation.bin")!),
                destinationURL: destinationURL,
                validateResponse: { _ in
                    throw CancellationError()
                }
            )
            XCTFail("Expected cancellation failure")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(try Data(contentsOf: temporaryURL), payload)
        XCTAssertTrue(StreamingFileDownloader.shouldPreservePartialDownload(after: CancellationError()))
    }

    func testRestartsFromZeroWhenPartialFileAlreadyMatchesExpectedSize() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data([1, 2, 3, 4])
        StreamingDownloaderURLProtocol.reset(data: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingDownloaderURLProtocol.self]
        let destinationURL = directory.appendingPathComponent("stale.bin")
        let temporaryURL = StreamingFileDownloader.partialDownloadURL(for: destinationURL)
        try FileManager.default.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([9, 9, 9, 9]).write(to: temporaryURL)

        let downloader = StreamingFileDownloader(configuration: configuration)
        let result = try await downloader.download(
            request: URLRequest(url: URL(string: "https://stream.test/stale.bin")!),
            destinationURL: destinationURL,
            expectedBytes: Int64(payload.count)
        )

        XCTAssertEqual(result.bytesWritten, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: destinationURL), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertEqual(StreamingDownloaderURLProtocol.recordedRangeHeaders(), [nil])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtraTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class StreamingDownloaderURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var statusCode = 200
    private static var shouldFailFirstRequestBeforeResponse = false
    private static var hasFailedFirstRequest = false
    private static var failEveryRequestWithError: URLError?
    private static var rangeHeaders: [String?] = []

    static func reset(
        data: Data,
        statusCode: Int = 200,
        failFirstRequestBeforeResponse: Bool = false,
        failEveryRequestWith: URLError? = nil
    ) {
        lock.lock()
        responseData = data
        self.statusCode = statusCode
        shouldFailFirstRequestBeforeResponse = failFirstRequestBeforeResponse
        hasFailedFirstRequest = false
        failEveryRequestWithError = failEveryRequestWith
        rangeHeaders = []
        lock.unlock()
    }

    static func recordedRangeHeaders() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return rangeHeaders
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stream.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        Self.lock.lock()
        let failEveryRequestWithError = Self.failEveryRequestWithError
        let data = Self.responseData
        let statusCode = Self.statusCode
        let shouldFailBeforeResponse = Self.shouldFailFirstRequestBeforeResponse
            && !Self.hasFailedFirstRequest
        if shouldFailBeforeResponse {
            Self.hasFailedFirstRequest = true
        }
        Self.rangeHeaders.append(rangeHeader)
        Self.lock.unlock()

        if let failEveryRequestWithError {
            client?.urlProtocol(self, didFailWithError: failEveryRequestWithError)
            return
        }
        if shouldFailBeforeResponse {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        let startOffset = rangeStart(from: rangeHeader, dataCount: data.count)
        let responseData = Data(data[startOffset..<data.count])
        let isPartialResponse = startOffset > 0 && statusCode == 200
        var headers = ["Content-Length": "\(responseData.count)"]
        if isPartialResponse {
            headers["Content-Range"] = "bytes \(startOffset)-\(data.count - 1)/\(data.count)"
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: isPartialResponse ? 206 : statusCode,
            httpVersion: nil,
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !responseData.isEmpty else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let firstChunkCount = min(2, responseData.count)
        client?.urlProtocol(self, didLoad: Data(responseData.prefix(firstChunkCount)))

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data(responseData.dropFirst(firstChunkCount)))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private func rangeStart(from rangeHeader: String?, dataCount: Int) -> Int {
        guard let rangeHeader,
              rangeHeader.hasPrefix("bytes="),
              let rangeStart = rangeHeader
                .dropFirst("bytes=".count)
                .split(separator: "-")
                .first
                .flatMap({ Int($0) }) else {
            return 0
        }
        return min(max(rangeStart, 0), dataCount)
    }
}

private final class Int64Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Int64] = []

    func append(_ value: Int64) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }

    func values() -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}
