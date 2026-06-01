import Foundation

enum RuntimeComponent: String, Codable, Equatable, CaseIterable, Sendable {
    case base
    case music

    var displayName: String {
        switch self {
        case .base:
            return "Base runtime"
        case .music:
            return "Music runtime"
        }
    }

    var manifestFilename: String {
        switch self {
        case .base:
            return "runtime-manifest.json"
        case .music:
            return "runtime-music-manifest.json"
        }
    }
}
