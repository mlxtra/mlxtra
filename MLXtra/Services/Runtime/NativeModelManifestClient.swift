import Foundation

final class NativeModelManifestClient: @unchecked Sendable {
    private let session: URLSession
    private let requestBuilder: NativeModelDownloadRequestBuilder

    init(
        session: URLSession = .shared,
        requestBuilder: NativeModelDownloadRequestBuilder
    ) {
        self.session = session
        self.requestBuilder = requestBuilder
    }

    func fetchManifest(repoID: String, revision: String) async throws -> HuggingFaceManifest {
        let request = try requestBuilder.manifestRequest(repoID: repoID, revision: revision)
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTPResponse(response, context: repoID)
        return try HuggingFaceManifest.parse(data: data, repoID: repoID, revision: revision)
    }

    static func validateHTTPResponse(_ response: URLResponse, context: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NativeModelDownloadError.httpStatus(httpResponse.statusCode, context)
        }
    }
}
