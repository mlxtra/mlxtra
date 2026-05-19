import SwiftUI

enum SettingsModelMode: String, CaseIterable, Identifiable {
    case chat
    case images
    case voice
    case music

    var id: String { rawValue }

    init(modality: ModelModality) {
        switch modality {
        case .vision:
            self = .chat
        case .image:
            self = .images
        case .audio:
            self = .voice
        case .music:
            self = .music
        }
    }

    var modality: ModelModality {
        switch self {
        case .chat: return .vision
        case .images: return .image
        case .voice: return .audio
        case .music: return .music
        }
    }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .images: return "Images"
        case .voice: return "Voice"
        case .music: return "Music"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .images: return "photo"
        case .voice: return "waveform"
        case .music: return "music.note"
        }
    }

    var defaultTitle: String {
        "Default for \(title)"
    }

    var purpose: String {
        switch self {
        case .chat: return "Conversation and image understanding"
        case .images: return "Image creation"
        case .voice: return "Voice generation"
        case .music: return "Music generation"
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case models
    case updates
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Models"
        case .updates: return "Updates"
        case .advanced: return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .models:
            return "Choose what runs locally on this Mac."
        case .updates:
            return "Keep MLXtra current."
        case .advanced:
            return "Tune prompts and tool behavior."
        }
    }
}

enum ModelSetupStatus {
    case ready
    case downloading
    case needsSetup

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .downloading: return "Downloading"
        case .needsSetup: return "Needs setup"
        }
    }

    var icon: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .needsSetup: return "arrow.down.circle"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .secondary
        case .downloading: return .accentColor
        case .needsSetup: return .orange
        }
    }
}

struct ModelSetupBadge: View {
    let status: ModelSetupStatus

    var body: some View {
        Label(status.title, systemImage: status.icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(status.tint.opacity(0.10))
            .clipShape(Capsule())
    }
}

struct ModelHeaderBadge: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(value)
                    .fontWeight(.semibold)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
        }
    }
}

struct ModelModePicker: View {
    @Binding var selectedMode: SettingsModelMode

    var body: some View {
        Picker(selection: $selectedMode) {
            ForEach(SettingsModelMode.allCases) { mode in
                Label(mode.title, systemImage: mode.icon)
                    .tag(mode)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300, alignment: .leading)
        .accessibilityIdentifier("settings.modelModePicker")
    }
}

struct CapabilitySetupItem: Identifiable {
    let title: String
    let subtitle: String
    let icon: String
    let model: DownloadableModel
    let state: ModelDownloadManager.DownloadState

    var id: String { title }
}
