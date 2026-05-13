import AppKit
import SwiftUI

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
        status.state == .preparing
            || status.state == .loadingModel
            || (status.loadProgress != nil && (viewModel.isGenerating || viewModel.isModelLoading || viewModel.isPythonLoading))
    }

    private var showsLoadingLine: Bool {
        isLoading || status.loadProgress != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isModelPickerPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: profile.icon)
                        .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .medium))
                        .foregroundStyle(isLoading ? Color.accentColor : MLXtraDesignSystem.Palette.secondaryLabel)
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
                    ComposerModelLoadProgressLine(progress: status.loadProgress)
                    Text("Model loading")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(height: 2)
                        .accessibilityLabel("Model loading")
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
        if let progress = status.loadProgress {
            return progress.compactTitle(modelName: profile.name)
        }

        if isLoading {
            return "Loading \(profile.name.split(separator: " ").first.map(String.init) ?? "model")"
        }

        return profile.name
    }

    private var statusIconTint: Color {
        switch status.state {
        case .ready, .idle, .memoryFreed:
            return MLXtraDesignSystem.Palette.secondaryLabel
        default:
            return status.tone.color
        }
    }

    private var borderColor: Color {
        isLoading ? Color.accentColor.opacity(0.20) : MLXtraDesignSystem.Surface.quietHairline
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(MLXtraDesignSystem.Surface.quietHairline)
            .frame(width: MLXtraDesignSystem.Spacing.hairline, height: 18)
    }
}

private struct ComposerModelLoadProgressLine: View {
    let progress: ModelLoadProgress?
    @State private var indeterminateOffset: CGFloat = -0.35

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.14))

                if let fraction = progress?.fractionCompleted {
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
            guard progress?.fractionCompleted == nil else { return }
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
                    Text(option.isEmpty ? "Auto" : option.capitalized).tag(option)
                }
            }
            .pickerStyle(.menu)
        case .text:
            TextField(definition.defaultValue, text: Binding(
                get: { value },
                set: { newValue in onChange(newValue) }
            ))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var displayValue: String {
        value.isEmpty ? "Auto" : value
    }
}

private struct TicklessParameterSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        self._value = value
        self.range = range
        self.step = step
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.controlSize = .small
        slider.focusRingType = .none
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        nsView.numberOfTickMarks = 0
        nsView.allowsTickMarkValuesOnly = false
        nsView.isEnabled = context.environment.isEnabled

        let clampedValue = Self.clamped(value, in: range)
        if abs(nsView.doubleValue - clampedValue) > 0.000_001 {
            nsView.doubleValue = clampedValue
        }
        context.coordinator.value = $value
        context.coordinator.range = range
        context.coordinator.step = step
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, range: range, step: step)
    }

    private static func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>
        var range: ClosedRange<Double>
        var step: Double

        init(value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
            self.value = value
            self.range = range
            self.step = step
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let steppedValue = Self.rounded(sender.doubleValue, range: range, step: step)
            if abs(sender.doubleValue - steppedValue) > 0.000_001 {
                sender.doubleValue = steppedValue
            }
            value.wrappedValue = steppedValue
        }

        private static func rounded(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
            let clampedValue = TicklessParameterSlider.clamped(value, in: range)
            guard step > 0 else { return clampedValue }
            let steps = ((clampedValue - range.lowerBound) / step).rounded()
            return TicklessParameterSlider.clamped(range.lowerBound + steps * step, in: range)
        }
    }
}
