import XCTest
@testable import MLXtra

final class NativeModelManifestClientTests: XCTestCase {
    func testFetchManifestUsesAuthorizedRequestAndParsesResponse() async throws {
        ManifestClientURLProtocol.reset(
            statusCode: 200,
            payload: """
            {
              "sha": "resolved",
              "siblings": [
                {
                  "rfilename": "model.safetensors",
                  "size": 4
                }
              ]
            }
            """
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = NativeModelManifestClient(
            session: session,
            requestBuilder: NativeModelDownloadRequestBuilder(
                baseURL: URL(string: "https://manifest.test")!,
                environment: ["HF_TOKEN": "test-token"]
            )
        )

        let manifest = try await client.fetchManifest(repoID: "org/model", revision: "main")

        XCTAssertEqual(manifest.resolvedRevision, "resolved")
        XCTAssertEqual(manifest.files, [HuggingFaceManifestFile(path: "model.safetensors", size: 4, sha256: nil)])
        XCTAssertEqual(ManifestClientURLProtocol.recordedPath(), "/api/models/org/model/revision/main")
        XCTAssertEqual(ManifestClientURLProtocol.recordedQuery(), "blobs=true&files_metadata=true")
        XCTAssertEqual(ManifestClientURLProtocol.recordedAuthorizationHeader(), "Bearer test-token")
    }

    func testFetchManifestMapsHTTPFailuresToDownloadErrors() async throws {
        ManifestClientURLProtocol.reset(statusCode: 403, payload: #"{"error":"gated"}"#)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = NativeModelManifestClient(
            session: session,
            requestBuilder: NativeModelDownloadRequestBuilder(
                baseURL: URL(string: "https://manifest.test")!,
                environment: [:]
            )
        )

        do {
            _ = try await client.fetchManifest(repoID: "org/gated", revision: "main")
            XCTFail("Expected HTTP status to be mapped to a native download error")
        } catch NativeModelDownloadError.httpStatus(let statusCode, let context) {
            XCTAssertEqual(statusCode, 403)
            XCTAssertEqual(context, "org/gated")
        }
    }

    func testValidateHTTPResponseIgnoresNonHTTPResponses() throws {
        try NativeModelManifestClient.validateHTTPResponse(URLResponse(), context: "local")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManifestClientURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ManifestClientURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusCode = 200
    private static var payload = "{}"
    private static var path: String?
    private static var query: String?
    private static var authorizationHeader: String?

    static func reset(statusCode: Int, payload: String) {
        lock.lock()
        self.statusCode = statusCode
        self.payload = payload
        path = nil
        query = nil
        authorizationHeader = nil
        lock.unlock()
    }

    static func recordedPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return path
    }

    static func recordedQuery() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return query
    }

    static func recordedAuthorizationHeader() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return authorizationHeader
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "manifest.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: Self.currentStatusCode(),
                httpVersion: nil,
                headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        Self.record(request: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.currentPayload().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func record(request: URLRequest) {
        lock.lock()
        path = request.url?.path
        query = request.url?.query
        authorizationHeader = request.value(forHTTPHeaderField: "Authorization")
        lock.unlock()
    }

    private static func currentStatusCode() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return statusCode
    }

    private static func currentPayload() -> String {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }
}
