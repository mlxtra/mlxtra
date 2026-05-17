import Foundation

enum MusicIntentState: Equatable {
    case needsInstrumentalOrVocals
    case needsLyrics
    case awaitingLyricsApproval
    case readyToGenerate

    var systemInstruction: String {
        switch self {
        case .needsInstrumentalOrVocals:
            return "Current music intent state: ask whether the user wants instrumental music or vocals with lyrics before calling generate_music."
        case .needsLyrics:
            return "Current music intent state: the user requested vocals, but lyrics are missing. Draft concise lyrics yourself, ask for explicit approval, and wait before calling generate_music."
        case .awaitingLyricsApproval:
            return "Current music intent state: lyrics are drafted but not approved. Ask for explicit approval before calling generate_music."
        case .readyToGenerate:
            return "Current music intent state: enough information is available to call generate_music."
        }
    }

    var blockedToolMessage: String? {
        switch self {
        case .needsInstrumentalOrVocals:
            return "Do not call generate_music yet. Ask the user whether they want instrumental music or vocals with lyrics."
        case .needsLyrics:
            return "Do not call generate_music yet. Lyrics are missing for the requested vocal song. Draft concise lyrics yourself, ask the user to approve them, then wait."
        case .awaitingLyricsApproval:
            return "Do not call generate_music yet. You drafted lyrics, but the user has not explicitly approved them. Ask whether the lyrics look good or need changes."
        case .readyToGenerate:
            return nil
        }
    }

    static func forPrompt(_ prompt: String) -> MusicIntentState {
        let normalized = prompt.lowercased()
        if containsAny(normalized, ["instrumental", "no vocals", "without vocals", "beat", "backing track", "background music"]) {
            return .readyToGenerate
        }
        if containsLyricsMarkers(prompt) {
            return .readyToGenerate
        }
        if containsAny(normalized, ["lyrics", "vocal", "vocals", "sing", "sung"]) {
            return .needsLyrics
        }
        if containsApproval(normalized) {
            return .readyToGenerate
        }
        return .needsInstrumentalOrVocals
    }

    static func forToolCall(prompt: String, parameters: [String: Any]) -> MusicIntentState {
        let caption = (parameters["caption"] as? String) ?? prompt
        let lyrics = ((parameters["lyrics"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let instrumental = boolValue(parameters["instrumental"])
        let normalizedPrompt = prompt.lowercased()
        let normalizedCaption = caption.lowercased()

        if instrumental || containsAny(normalizedPrompt + " " + normalizedCaption, ["instrumental", "no vocals", "without vocals", "beat", "backing track", "background music"]) {
            return .readyToGenerate
        }

        if lyrics.isEmpty {
            if containsAny(normalizedPrompt + " " + normalizedCaption, ["lyrics", "vocal", "vocals", "sing", "sung"]) {
                return .needsLyrics
            }
            return .readyToGenerate
        }

        if userProvidedLyrics(prompt: prompt, lyrics: lyrics) || containsApproval(normalizedPrompt) {
            return .readyToGenerate
        }

        return .awaitingLyricsApproval
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            default:
                return false
            }
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func containsLyricsMarkers(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return containsAny(normalized, ["[verse]", "[chorus]", "[bridge]", "lyrics:"])
    }

    private static func containsApproval(_ text: String) -> Bool {
        let normalizedWords = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
        let paddedWords = " \(normalizedWords) "
        let approvalPhrases = [
            "yes",
            "approved",
            "looks good",
            "go ahead",
            "use those lyrics",
            "use the lyrics",
            "use them",
            "that's fine",
            "that works",
            "ok",
            "okay"
        ]
        return approvalPhrases.contains { phrase in
            let normalizedPhrase = phrase
                .split { !$0.isLetter && !$0.isNumber }
                .joined(separator: " ")
            return normalizedWords == normalizedPhrase || paddedWords.contains(" \(normalizedPhrase) ")
        }
    }

    private static func userProvidedLyrics(prompt: String, lyrics: String) -> Bool {
        if containsLyricsMarkers(prompt) {
            return true
        }
        let normalizedPrompt = prompt.lowercased()
        let lyricWords = lyrics
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 3 }
        guard lyricWords.count >= 4 else { return false }
        let matchingWords = lyricWords.filter { normalizedPrompt.contains(String($0)) }
        return matchingWords.count >= min(6, lyricWords.count)
    }
}

enum MusicVocalMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case instrumental = "Instrumental"
    case vocals = "With vocals"

    var id: String { rawValue }
}

enum MusicComposerPrompt: Equatable {
    case needsLyrics
}

struct MusicGenerationDraft {
    let vocalMode: MusicVocalMode
    let lyrics: String?
}

struct MusicComposerResolution {
    let prompt: String
    let resolvedMode: MusicVocalMode
    let promptState: MusicComposerPrompt?
    let generationDraft: MusicGenerationDraft?
}

enum ComposerDraftPrimaryAction: Equatable {
    case send
    case createSong
}

enum ComposerDraftSlotAction: String, Equatable, Identifiable {
    case attachReference
    case chooseInstrumental
    case chooseVocals
    case showLyricsEditor
    case regenerateLyrics

    var id: String { rawValue }
}

struct ComposerDraftSlotActionItem: Identifiable, Equatable {
    let action: ComposerDraftSlotAction
    let title: String
    let systemImage: String

    var id: ComposerDraftSlotAction { action }
}

struct ComposerDraftSlot: Identifiable, Equatable {
    enum Tone: Equatable {
        case neutral
        case needed
    }

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let tone: Tone
    let actions: [ComposerDraftSlotActionItem]
}

struct ComposerDraft: Equatable {
    let mode: Tool
    let placeholder: String
    let primaryTitle: String?
    let primarySystemImage: String
    let primaryHelp: String
    let disabledHelp: String
    let primaryAction: ComposerDraftPrimaryAction
    let isPrimaryEnabled: Bool
    let showsMusicControls: Bool
    let slots: [ComposerDraftSlot]
}

struct ComposerDraftContext {
    let selectedTool: Tool
    let promptIsEmpty: Bool
    let hasSelectedImages: Bool
    let selectedImageCount: Int
    let isInputDisabled: Bool
    let isDraftingMusicLyrics: Bool
    let musicLyricsText: String
    let musicPromptState: MusicComposerPrompt?
    let canCreateMusic: Bool
}

enum ComposerDraftResolver {
    static func resolve(_ context: ComposerDraftContext) -> ComposerDraft {
        let title: String?
        let icon: String
        let help: String
        let disabledHelp: String
        let action: ComposerDraftPrimaryAction
        let enabled: Bool
        let slots: [ComposerDraftSlot]

        switch context.selectedTool {
        case .auto, .chat:
            title = nil
            icon = "arrow.up"
            help = "Send message"
            disabledHelp = "Type a message or attach an image"
            action = .send
            enabled = !context.isInputDisabled && (!context.promptIsEmpty || context.hasSelectedImages)
            slots = []

        case .image:
            title = "Create image"
            icon = "photo"
            help = "Create image"
            disabledHelp = "Describe the image you want"
            action = .send
            enabled = !context.isInputDisabled && !context.promptIsEmpty
            slots = []

        case .tts:
            title = "Create speech"
            icon = "waveform"
            help = "Create speech"
            disabledHelp = "Type what you want spoken"
            action = .send
            enabled = !context.isInputDisabled && !context.promptIsEmpty
            slots = []

        case .music:
            title = context.promptIsEmpty ? nil : "Create music"
            icon = context.promptIsEmpty ? "arrow.up" : "music.note"
            help = context.musicPromptState == .needsLyrics ? "Add lyrics or choose Instrumental" : "Create music"
            disabledHelp = context.musicPromptState == .needsLyrics ? "Add lyrics or choose Instrumental" : "Describe the music you want"
            action = .createSong
            enabled = !context.isInputDisabled && !context.promptIsEmpty && context.canCreateMusic
            slots = []

        case .research:
            title = "Research"
            icon = "magnifyingglass"
            help = "Research the web"
            disabledHelp = "Enter what you want researched"
            action = .send
            enabled = !context.isInputDisabled && !context.promptIsEmpty
            slots = []
        }

        return ComposerDraft(
            mode: context.selectedTool,
            placeholder: placeholder(for: context),
            primaryTitle: title,
            primarySystemImage: icon,
            primaryHelp: help,
            disabledHelp: disabledHelp,
            primaryAction: action,
            isPrimaryEnabled: enabled,
            showsMusicControls: context.selectedTool == .music,
            slots: slots
        )
    }

    private static func placeholder(for context: ComposerDraftContext) -> String {
        switch context.selectedTool {
        case .auto, .chat:
            return context.hasSelectedImages ? "Add a note..." : "Ask anything..."
        case .image:
            return "Describe the image you want..."
        case .tts:
            return "Type what you want spoken..."
        case .music:
            return "Describe the music you want..."
        case .research:
            return "What should I research?"
        }
    }

}
