import Foundation

enum Tool: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case image = "Create image"
    case tts = "Create speech"
    case music = "Create music"
    case research = "Deep research"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .auto: return "sparkle"
        case .image: return "photo"
        case .tts: return "waveform"
        case .music: return "music.note"
        case .research: return "magnifyingglass"
        }
    }
    
    var subtitle: String {
        switch self {
        case .auto: return "Let the app decide"
        case .image: return "Generate or edit images"
        case .tts: return "Turn text into audio"
        case .music: return "Generate music locally"
        case .research: return "Use live web sources"
        }
    }
}
