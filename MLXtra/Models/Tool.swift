import Foundation

enum Tool: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case chat = "Chat"
    case image = "Image"
    case tts = "Speech"
    case music = "Music"
    case research = "Research"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .chat: return "bubble.left.and.bubble.right"
        case .image: return "photo"
        case .tts: return "waveform"
        case .music: return "music.note"
        case .research: return "magnifyingglass"
        }
    }
    
    var subtitle: String {
        switch self {
        case .auto: return "Let the app choose tools"
        case .chat: return "Plain local conversation"
        case .image: return "Create or edit images"
        case .tts: return "Turn text into speech"
        case .music: return "Create local music"
        case .research: return "Use live web sources"
        }
    }

}
