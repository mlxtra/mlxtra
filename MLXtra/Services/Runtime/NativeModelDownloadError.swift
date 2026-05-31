import Foundation

enum NativeModelDownloadError: LocalizedError, Equatable {
    case emptyManifest(String)
    case invalidManifestURL(String)
    case invalidDownloadURL(String)
    case httpStatus(Int, String)
    case sizeMismatch(String, expected: Int64, actual: Int64)
    case checksumMismatch(String)
    case missingDownloadedFile(String)
    case unsupportedComponentBundle(String)

    var errorDescription: String? {
        switch self {
        case .emptyManifest(let repoID):
            return "Hugging Face did not return downloadable files for \(repoID)."
        case .invalidManifestURL(let repoID):
            return "Could not build Hugging Face manifest URL for \(repoID)."
        case .invalidDownloadURL(let path):
            return "Could not build Hugging Face download URL for \(path)."
        case .httpStatus(let statusCode, let context):
            return Self.message(forHTTPStatus: statusCode, context: context)
        case .sizeMismatch(let path, let expected, let actual):
            return "Downloaded file size mismatch for \(path): expected \(expected) bytes, got \(actual) bytes."
        case .checksumMismatch(let path):
            return "Downloaded file checksum did not match for \(path)."
        case .missingDownloadedFile(let path):
            return "Downloaded file is missing after transfer: \(path)."
        case .unsupportedComponentBundle(let modelName):
            return "\(modelName) uses an unsupported component bundle download helper."
        }
    }

    private static func message(forHTTPStatus statusCode: Int, context: String) -> String {
        switch statusCode {
        case 401:
            return "Hugging Face authentication is required for \(context)."
        case 403:
            return "Hugging Face denied access to \(context). Accept the model license or check your account access."
        case 404:
            return "Hugging Face model or file was not found: \(context)."
        case 429:
            return "Hugging Face rate limit reached while downloading \(context). Try again later."
        default:
            return "Hugging Face returned HTTP \(statusCode) for \(context)."
        }
    }
}
