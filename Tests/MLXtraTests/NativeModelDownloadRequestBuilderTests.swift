import XCTest
@testable import MLXtra

final class NativeModelDownloadRequestBuilderTests: XCTestCase {
    func testManifestRequestEncodesPathSegmentsAndAppliesHFToken() throws {
        let builder = NativeModelDownloadRequestBuilder(
            baseURL: URL(string: "https://hf.test/")!,
            environment: ["HF_TOKEN": " token-value "]
        )

        let request = try builder.manifestRequest(
            repoID: "org name/model+name",
            revision: "refs/pr/1"
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://hf.test/api/models/org%20name/model%2Bname/revision/refs/pr/1?blobs=true&files_metadata=true"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer token-value"
        )
    }

    func testDownloadRequestEncodesFilePathAndFallsBackToHubToken() throws {
        let builder = NativeModelDownloadRequestBuilder(
            baseURL: URL(string: "https://hf.test/nested")!,
            environment: [
                "HF_TOKEN": " ",
                "HUGGING_FACE_HUB_TOKEN": "fallback-token"
            ]
        )

        let request = try builder.downloadRequest(
            repoID: "org/model",
            revision: "abc#123",
            path: "weights/model 1+2.safetensors"
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://hf.test/nested/org/model/resolve/abc%23123/weights/model%201%2B2.safetensors"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer fallback-token"
        )
    }

    func testRequestOmitsAuthorizationHeaderWhenNoTokenIsConfigured() throws {
        let builder = NativeModelDownloadRequestBuilder(
            baseURL: URL(string: "https://hf.test")!,
            environment: [:]
        )

        let request = try builder.downloadRequest(
            repoID: "org/model",
            revision: "main",
            path: "model.safetensors"
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}
