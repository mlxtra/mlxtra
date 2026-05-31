import Foundation

struct NativeModelDownloadRequestBuilder: Sendable {
    private let baseURL: URL
    private let authorizationToken: String?

    init(
        baseURL: URL = URL(string: "https://huggingface.co")!,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            baseURL: baseURL,
            authorizationToken: Self.authorizationToken(from: environment)
        )
    }

    init(baseURL: URL, authorizationToken: String?) {
        self.baseURL = baseURL
        self.authorizationToken = authorizationToken
    }

    func manifestRequest(repoID: String, revision: String) throws -> URLRequest {
        guard let url = URL(
            string: "\(normalizedBaseURLString)/api/models/\(Self.encodedPath(repoID))/revision/\(Self.encodedPath(revision))?blobs=true&files_metadata=true"
        ) else {
            throw NativeModelDownloadError.invalidManifestURL(repoID)
        }
        return authorizedRequest(url: url)
    }

    func downloadRequest(repoID: String, revision: String, path: String) throws -> URLRequest {
        guard let url = URL(
            string: "\(normalizedBaseURLString)/\(Self.encodedPath(repoID))/resolve/\(Self.encodedPath(revision))/\(Self.encodedPath(path))"
        ) else {
            throw NativeModelDownloadError.invalidDownloadURL(path)
        }
        return authorizedRequest(url: url)
    }

    private var normalizedBaseURLString: String {
        baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func authorizationToken(from environment: [String: String]) -> String? {
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"] {
            guard let token = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                continue
            }
            return token
        }
        return nil
    }

    private static func encodedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encodedPathSegment(String($0)) }
            .joined(separator: "/")
    }

    private static func encodedPathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
