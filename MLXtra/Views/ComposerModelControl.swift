import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerModelControl: View {
    @ObservedObject var viewModel: ChatViewModel
    let onOpenModels: () -> Void
    let onRestart: () -> Void
    let onFreeMemory: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @State private var isModelPickerPresented = false
    @State private var isSettingsPresented = false
    @State private var isStatusPresented = false
    @AppStorage("MLXtra.pendingDownloadModelId") private var pendingDownloadModelId = ""

    private var profile: ModelCapabilityProfile {
        viewModel.activeModelProfile
    }

    private var status: LocalEngineStatus {
        viewModel.localEngineStatus
    }

    private var isLoading: Bool {
        viewModel.isGenerating
            || status.state == .preparing
            || status.state == .preloading
            || status.state == .loadingModel
            || status.state == .terminating
            || (status.generationProgress != nil && viewModel.isGenerating)
            || (status.loadProgress != nil && (viewModel.isGenerating || viewModel.isModelLoading || viewModel.isPythonLoading))
    }

    private var isForegroundLoading: Bool {
        viewModel.isGenerating
            || status.state == .preparing
            || status.state == .loadingModel
            || status.state == .terminating
            || (status.generationProgress != nil && viewModel.isGenerating)
            || (status.loadProgress != nil && (viewModel.isGenerating || viewModel.isModelLoading || viewModel.isPythonLoading))
    }

    private var showsLoadingLine: Bool {
        isLoading || status.loadProgress != nil || status.generationProgress != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isModelPickerPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: profile.icon)
                        .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .medium))
                        .foregroundStyle(isForegroundLoading ? Color.accentColor : MLXtraDesignSystem.Palette.secondaryLabel)
                        .frame(width: 16)

                    Text(compactModelTitle)
                        .font(MLXtraDesignSystem.Typography.compactBodyMedium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "chevron.down")
                        .font(.system(size: MLXtraDesignSystem.Icon.micro, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 10)
                .padding(.trailing, 9)
                .frame(maxWidth: 188, minHeight: MLXtraDesignSystem.Icon.composerButton)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose model")
            .disabled(viewModel.isInputDisabled)
            .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
                ComposerModelPickerPopover(
                    viewModel: viewModel,
                    downloadManager: downloadManager,
                    isPresented: $isModelPickerPresented
                )
                .frame(width: 330)
            }
            .accessibilityIdentifier("composer.modelDropdown")

            segmentDivider

            Button {
                isSettingsPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .medium))
                    .foregroundStyle(MLXtraDesignSystem.Palette.secondaryLabel)
                    .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Model settings")
            .disabled(viewModel.isInputDisabled)
            .popover(isPresented: $isSettingsPresented, arrowEdge: .bottom) {
                ModelParameterPopover(viewModel: viewModel, profile: profile)
                    .frame(width: 320)
            }
            .accessibilityIdentifier("composer.modelSettings")

            segmentDivider

            Button {
                isStatusPresented.toggle()
            } label: {
                Image(systemName: status.systemImage)
                    .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .semibold))
                    .foregroundStyle(statusIconTint)
                    .frame(width: MLXtraDesignSystem.Icon.composerButton, height: MLXtraDesignSystem.Icon.composerButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(status.detail)
            .popover(isPresented: $isStatusPresented, arrowEdge: .bottom) {
                LocalEngineStatusPopover(
                    status: status,
                    canFreeMemory: viewModel.canFreeLocalEngineMemory,
                    onOpenModels: {
                        isStatusPresented = false
                        if let modelId = status.primaryActionModelId {
                            pendingDownloadModelId = modelId
                        }
                        onOpenModels()
                    },
                    onRestart: {
                        isStatusPresented = false
                        onRestart()
                    },
                    onFreeMemory: {
                        isStatusPresented = false
                        onFreeMemory()
                    }
                )
            }
            .accessibilityIdentifier("composer.modelStatus")
        }
        .frame(height: MLXtraDesignSystem.Icon.composerButton)
        .background(
            Capsule()
                .fill(MLXtraDesignSystem.Surface.controlFill(colorScheme: colorScheme))
        )
        .overlay {
            Capsule()
                .stroke(borderColor, lineWidth: MLXtraDesignSystem.Spacing.hairline)
        }
        .overlay(alignment: .bottom) {
            if showsLoadingLine {
                ZStack {
                    ComposerModelProgressLine(fractionCompleted: status.progressFractionCompleted)
                    Text(status.accessibilityProgressLabel)
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(height: 2)
                        .accessibilityLabel(status.accessibilityProgressLabel)
                        .accessibilityIdentifier("composer.modelLoadingIndicator")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 1)
            }
        }
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.modelControl")
        .onAppear {
            downloadManager.refreshStatuses()
        }
    }

    private var compactModelTitle: String {
        if status.state == .preloading {
            return profile.name
        }

        if let progress = status.loadProgress {
            return progress.compactTitle(modelName: profile.name)
        }

        if let progress = status.generationProgress {
            return progress.compactTitle(modelName: profile.name)
        }

        if viewModel.isGenerating {
            return "Generating"
        }

        if status.state == .terminating {
            return "Stopping"
        }

        if isLoading {
            return "Loading \(profile.name.split(separator: " ").first.map(String.init) ?? "model")"
        }

        return profile.name
    }

    private var statusIconTint: Color {
        switch status.state {
        case .ready, .idle, .memoryFreed, .preloading:
            return MLXtraDesignSystem.Palette.secondaryLabel
        default:
            return status.tone.color
        }
    }

    private var borderColor: Color {
        isForegroundLoading ? Color.accentColor.opacity(0.20) : MLXtraDesignSystem.Surface.quietHairline
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(MLXtraDesignSystem.Surface.quietHairline)
            .frame(width: MLXtraDesignSystem.Spacing.hairline, height: 18)
    }
}

private struct ComposerModelProgressLine: View {
    let fractionCompleted: Double?
    @State private var indeterminateOffset: CGFloat = -0.35

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.14))

                if let fraction = fractionCompleted {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.82))
                        .frame(width: max(2, width * fraction))
                } else {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.82))
                        .frame(width: max(26, width * 0.30))
                        .offset(x: width * indeterminateOffset)
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .onAppear {
            guard fractionCompleted == nil else { return }
            indeterminateOffset = -0.35
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: false)) {
                indeterminateOffset = 1.05
            }
        }
    }
}

private struct ComposerModelPickerPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var downloadManager: ModelDownloadManager
    @Binding var isPresented: Bool

    private var readyProfiles: [ModelCapabilityProfile] {
        compatibleProfiles.filter { profile in
            downloadManager.state(for: profile.downloadableModel) == .downloaded
        }
    }

    private var compatibleProfiles: [ModelCapabilityProfile] {
        viewModel.availableProfilesForCurrentMode.filter { $0.isRuntimeCompatible() }
    }

    private var hasResolvedModelStates: Bool {
        compatibleProfiles.allSatisfy { profile in
            downloadManager.states[profile.downloadableModel.id] != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if readyProfiles.isEmpty {
                Text(hasResolvedModelStates ? "No ready models" : "Checking ready models")
                    .font(MLXtraDesignSystem.Typography.captionMedium)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("composer.modelPicker.empty")
            } else {
                ForEach(readyProfiles) { profile in
                    ComposerModelProfileRow(
                        profile: profile,
                        isSelected: viewModel.isModelProfileSelected(profile),
                        action: {
                            viewModel.selectModelProfile(profile)
                            downloadManager.refreshStatuses()
                            isPresented = false
                        }
                    )
                }
            }
        }
        .padding(.vertical, 6)
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.popover)
        .shadow(
            color: Color.black.opacity(MLXtraDesignSystem.Elevation.popoverShadowOpacity),
            radius: MLXtraDesignSystem.Elevation.popoverShadowRadius,
            x: 0,
            y: MLXtraDesignSystem.Elevation.popoverShadowY
        )
        .onAppear {
            downloadManager.refreshStatuses()
        }
    }
}

private struct ComposerModelProfileRow: View {
    let profile: ModelCapabilityProfile
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: profile.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : MLXtraDesignSystem.Palette.secondaryLabel)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(MLXtraDesignSystem.Typography.compactBodyMedium)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(profile.subtitle)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? MLXtraDesignSystem.Surface.hoverFill : Color.clear)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityIdentifier("composer.modelProfile.\(profile.modelId.accessibilityIdentifierComponent)")
    }
}

private extension String {
    var accessibilityIdentifierComponent: String {
        lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    var displayNameForModelParameterOption: String {
        let cleaned = replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Auto" : cleaned.capitalized
    }
}

extension LocalEngineStatus.Tone {
    var color: Color {
        switch self {
        case .neutral:
            return .secondary
        case .accent:
            return .accentColor
        case .success:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }
}

private extension ModelCapabilityProfile {
    var isHiggsAudioV3: Bool {
        modelId == "bosonai/higgs-audio-v3-tts-4b"
    }
}


private struct ModelParameterPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showAdvanced = false
    private let explicitProfile: ModelCapabilityProfile?

    init(viewModel: ChatViewModel, profile: ModelCapabilityProfile? = nil) {
        self.viewModel = viewModel
        self.explicitProfile = profile
    }

    private var profile: ModelCapabilityProfile {
        explicitProfile ?? viewModel.activeModelProfile
    }

    private var basicParameters: [ModelParameterDefinition] {
        profile.parameters.filter { !$0.isAdvanced }
    }

    private var advancedParameters: [ModelParameterDefinition] {
        profile.parameters.filter(\.isAdvanced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: profile.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text(profile.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if profile.isHiggsAudioV3 {
                HiggsAudioV3ParameterSection(
                    viewModel: viewModel,
                    profile: profile,
                    showAdvanced: $showAdvanced
                )
            } else if !basicParameters.isEmpty {
                VStack(spacing: 10) {
                    ForEach(basicParameters) { parameter in
                        ParameterControl(
                            definition: parameter,
                            value: viewModel.parameterValue(for: profile, key: parameter.key),
                            onChange: { value in
                                viewModel.setParameterValue(value, for: parameter, profile: profile)
                            }
                        )
                    }
                }
            }

            if !profile.isHiggsAudioV3, !advancedParameters.isEmpty {
                ClickableDisclosureSection(isExpanded: $showAdvanced) {
                    VStack(spacing: 10) {
                        ForEach(advancedParameters) { parameter in
                            ParameterControl(
                                definition: parameter,
                                value: viewModel.parameterValue(for: profile, key: parameter.key),
                                onChange: { value in
                                    viewModel.setParameterValue(value, for: parameter, profile: profile)
                                }
                            )
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced")
                        .font(.caption.weight(.semibold))
                }
            }

            Divider()

            HStack {
                Menu {
                    ForEach(profile.presets) { preset in
                        Button(preset.label) {
                            viewModel.applyParameterPreset(preset, to: profile)
                        }
                    }
                } label: {
                    Text("Use preset")
                }
                .menuStyle(.borderlessButton)
                .disabled(profile.presets.isEmpty)

                Spacer()

                Button("Reset") {
                    viewModel.resetParameters(for: profile)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .designPanelSurface(cornerRadius: MLXtraDesignSystem.Radius.card)
    }
}

private struct HiggsAudioV3ParameterSection: View {
    @ObservedObject var viewModel: ChatViewModel
    let profile: ModelCapabilityProfile
    @Binding var showAdvanced: Bool

    private var voiceDefinition: ModelParameterDefinition? {
        profile.parameterDefinition(key: "voice")
    }

    private var emotionDefinition: ModelParameterDefinition? {
        profile.parameterDefinition(key: "emotion")
    }

    private var referenceAudioDefinition: ModelParameterDefinition? {
        profile.parameterDefinition(key: "ref_audio")
    }

    private var basicParameters: [ModelParameterDefinition] {
        profile.parameters.filter { parameter in
            !parameter.isAdvanced && parameter.key != "voice" && parameter.key != "emotion"
        }
    }

    private var advancedParameters: [ModelParameterDefinition] {
        profile.parameters.filter { parameter in
            parameter.isAdvanced && parameter.key != "ref_audio"
        }
    }

    private var selectedVoiceValue: String {
        viewModel.parameterValue(for: profile, key: "voice")
    }

    private var selectedEmotionValue: String {
        viewModel.parameterValue(for: profile, key: "emotion")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let voiceDefinition {
                HiggsSettingBlock(title: "Voice") {
                    HiggsVoiceMenu(
                        selectedValue: selectedVoiceValue,
                        onSelect: { value in
                            viewModel.setParameterValue(value, for: voiceDefinition, profile: profile)
                        }
                    )

                    if selectedVoiceValue == "custom_reference", let referenceAudioDefinition {
                        FilePathParameterControl(
                            definition: referenceAudioDefinition,
                            value: viewModel.parameterValue(for: profile, key: referenceAudioDefinition.key),
                            title: "Reference audio",
                            onChange: { value in
                                viewModel.setParameterValue(value, for: referenceAudioDefinition, profile: profile)
                            }
                        )
                    }
                }
            }

            if let emotionDefinition {
                HiggsSettingBlock(title: "Emotion") {
                    Picker("Emotion", selection: Binding(
                        get: { selectedEmotionValue },
                        set: { value in
                            viewModel.setParameterValue(value, for: emotionDefinition, profile: profile)
                        }
                    )) {
                        ForEach(emotionDefinition.options, id: \.self) { option in
                            Text(option.displayNameForModelParameterOption).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if !basicParameters.isEmpty {
                VStack(spacing: 10) {
                    ForEach(basicParameters) { parameter in
                        ParameterControl(
                            definition: parameter,
                            value: viewModel.parameterValue(for: profile, key: parameter.key),
                            onChange: { value in
                                viewModel.setParameterValue(value, for: parameter, profile: profile)
                            }
                        )
                    }
                }
            }

            if !advancedParameters.isEmpty {
                ClickableDisclosureSection(isExpanded: $showAdvanced) {
                    VStack(spacing: 10) {
                        ForEach(advancedParameters) { parameter in
                            ParameterControl(
                                definition: parameter,
                                value: viewModel.parameterValue(for: profile, key: parameter.key),
                                onChange: { value in
                                    viewModel.setParameterValue(value, for: parameter, profile: profile)
                                }
                            )
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced")
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

private struct HiggsSettingBlock<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            content
        }
    }
}

private struct HiggsVoiceMenu: View {
    let selectedValue: String
    let onSelect: (String) -> Void

    private var selectedOption: HiggsAudioV3VoiceOption {
        HiggsAudioV3VoiceOption.option(for: selectedValue)
    }

    var body: some View {
        Menu {
            Section("Female") {
                ForEach(HiggsAudioV3VoiceOption.femalePresets) { option in
                    voiceButton(option)
                }
            }

            Section("Male") {
                ForEach(HiggsAudioV3VoiceOption.malePresets) { option in
                    voiceButton(option)
                }
            }

            Section("Custom") {
                voiceButton(.customReference)
                voiceButton(.defaultVoice)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedOption.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedOption.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(selectedOption.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(MLXtraDesignSystem.Surface.hoverFill.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("higgs.voice.menu")
    }

    @ViewBuilder
    private func voiceButton(_ option: HiggsAudioV3VoiceOption) -> some View {
        Button {
            onSelect(option.id)
        } label: {
            Label(option.menuTitle(isSelected: selectedValue == option.id), systemImage: option.systemImage)
        }
    }
}

private struct HiggsAudioV3VoiceOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String

    func menuTitle(isSelected: Bool) -> String {
        isSelected ? "\(title) ✓" : title
    }

    static let defaultVoice = HiggsAudioV3VoiceOption(
        id: "default",
        title: "Default",
        subtitle: "Model voice without reference audio",
        systemImage: "waveform"
    )

    static let customReference = HiggsAudioV3VoiceOption(
        id: "custom_reference",
        title: "Custom Reference",
        subtitle: "Use a local WAV, MP3, or FLAC file",
        systemImage: "folder.badge.plus"
    )

    static let femalePresets: [HiggsAudioV3VoiceOption] = [
        HiggsAudioV3VoiceOption(id: "female_bright", title: "Mira (Bright)", subtitle: "Bright female", systemImage: "person.wave.2"),
        HiggsAudioV3VoiceOption(id: "female_calm", title: "Lina (Calm)", subtitle: "Calm female", systemImage: "person.wave.2"),
        HiggsAudioV3VoiceOption(id: "female_story", title: "Nora (Story)", subtitle: "Storytelling female", systemImage: "person.wave.2")
    ]

    static let malePresets: [HiggsAudioV3VoiceOption] = [
        HiggsAudioV3VoiceOption(id: "male_clear", title: "Orin (Clear)", subtitle: "Clear male", systemImage: "person.wave.2.fill"),
        HiggsAudioV3VoiceOption(id: "male_deep", title: "Damon (Deep)", subtitle: "Deep male", systemImage: "person.wave.2.fill"),
        HiggsAudioV3VoiceOption(id: "male_soft", title: "Eren (Soft)", subtitle: "Soft male", systemImage: "person.wave.2.fill")
    ]

    static var allOptions: [HiggsAudioV3VoiceOption] {
        [defaultVoice] + femalePresets + malePresets + [customReference]
    }

    static func option(for value: String) -> HiggsAudioV3VoiceOption {
        allOptions.first { $0.id == value } ?? defaultVoice
    }
}

private struct ParameterControl: View {
    let definition: ModelParameterDefinition
    let value: String
    let onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(definition.label)
                    .font(.caption.weight(.medium))
                Spacer()
                if definition.type == .decimal || definition.type == .integer {
                    Text(displayValue)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            control
        }
    }

    @ViewBuilder
    private var control: some View {
        switch definition.type {
        case .decimal, .integer:
            TicklessParameterSlider(
                value: Binding(
                    get: { Double(value) ?? Double(definition.defaultValue) ?? 0 },
                    set: { onChange(definition.clampedString($0)) }
                ),
                in: definition.range ?? 0...1,
                step: definition.step
            )
            .frame(height: 16)
        case .boolean:
            Toggle(
                "",
                isOn: Binding(
                    get: { value == "true" },
                    set: { onChange($0 ? "true" : "false") }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
        case .option:
            Picker(definition.label, selection: Binding(
                get: { value },
                set: { newValue in onChange(newValue) }
            )) {
                ForEach(definition.options, id: \.self) { option in
                    Text(option.displayNameForModelParameterOption).tag(option)
                }
            }
            .pickerStyle(.menu)
        case .text:
            TextField(definition.defaultValue, text: Binding(
                get: { value },
                set: { newValue in onChange(newValue) }
            ))
                .textFieldStyle(.roundedBorder)
        case .filePath:
            FilePathParameterControl(
                definition: definition,
                value: value,
                title: definition.label,
                onChange: onChange
            )
        }
    }

    private var displayValue: String {
        value.isEmpty ? "Auto" : value
    }
}

private struct FilePathParameterControl: View {
    let definition: ModelParameterDefinition
    let value: String
    let title: String
    let onChange: (String) -> Void

    private var selectedFileName: String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No file selected"
        }
        return URL(fileURLWithPath: value).lastPathComponent
    }

    private var allowedFormatText: String {
        guard !definition.allowedExtensions.isEmpty else { return "Any local file" }
        return definition.allowedExtensions.map { $0.uppercased() }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: value.isEmpty ? "waveform.badge.plus" : "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(selectedFileName)
                        .font(.caption)
                        .foregroundStyle(value.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    onChange("")
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear reference audio")
                .opacity(value.isEmpty ? 0 : 1)
                .disabled(value.isEmpty)

                Button {
                    chooseFile()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Choose reference audio")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(MLXtraDesignSystem.Surface.hoverFill.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Accepted formats: \(allowedFormatText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("parameter.filePath.\(definition.key)")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedContentTypes
        panel.prompt = "Choose"
        panel.message = "Choose a local reference audio file."
        if panel.runModal() == .OK, let url = panel.url {
            onChange(url.path)
        }
    }

    private var allowedContentTypes: [UTType] {
        let types = definition.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.audio] : types
    }
}

private struct TicklessParameterSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @Environment(\.isEnabled) private var isEnabled

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = Self.fraction(for: value, in: range)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(isEnabled ? 0.18 : 0.10))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.accentColor.opacity(isEnabled ? 0.95 : 0.35))
                    .frame(width: max(0, width * fraction), height: 4)

                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 14, height: 14)
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.16), lineWidth: 0.5)
                    }
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 0.5)
                    .offset(x: max(0, min(width - 14, width * fraction - 7)))
            }
            .frame(height: proxy.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        value = Self.rounded(
                            valueForLocation(gesture.location.x, width: width),
                            range: range,
                            step: step
                        )
                    }
            )
        }
        .accessibilityElement()
        .accessibilityValue(Text("\(value)"))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let delta = step > 0 ? step : (range.upperBound - range.lowerBound) / 100
            switch direction {
            case .increment:
                value = Self.rounded(value + delta, range: range, step: step)
            case .decrement:
                value = Self.rounded(value - delta, range: range, step: step)
            @unknown default:
                break
            }
        }
    }

    private func valueForLocation(_ x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max(Double(x / width), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * fraction
    }

    private static func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func fraction(for value: Double, in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (clamped(value, in: range) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private static func rounded(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let clampedValue = TicklessParameterSlider.clamped(value, in: range)
        guard step > 0 else { return clampedValue }
        let steps = ((clampedValue - range.lowerBound) / step).rounded()
        return TicklessParameterSlider.clamped(range.lowerBound + steps * step, in: range)
    }
}
