import SwiftUI

struct FirstRunExperienceView: View {
    @ObservedObject var runtimeUpdateManager: RuntimeUpdateManager
    let starterModels: [FirstRunStarterModel]
    let onOpenModel: (DownloadableModel) -> Void
    let onOpenModels: () -> Void
    let onContinue: () -> Void

    @State private var selectedStep: FirstRunStep = .intro

    private let columns = [
        GridItem(.adaptive(minimum: 178), spacing: MLXtraDesignSystem.Spacing.xl)
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                stepContent
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 32)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MLXtraDesignSystem.Palette.windowBackground)
        .onAppear {
            runtimeUpdateManager.bootstrapStableRuntimeInBackground(reportFailures: true)
        }
    }

    private var topBar: some View {
        HStack(spacing: MLXtraDesignSystem.Spacing.xxl) {
            HStack(spacing: MLXtraDesignSystem.Spacing.md) {
                FirstRunAppIcon(size: 32)

                Text("MLXtra")
                    .font(MLXtraDesignSystem.Typography.toolbarTitle)
            }

            Spacer(minLength: MLXtraDesignSystem.Spacing.xxl)

            HStack(spacing: MLXtraDesignSystem.Spacing.md) {
                ForEach(FirstRunStep.allCases) { step in
                    FirstRunStepButton(step: step, isSelected: step == selectedStep) {
                        withAnimation(.easeInOut(duration: MLXtraDesignSystem.Motion.focusDuration)) {
                            selectedStep = step
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, MLXtraDesignSystem.Spacing.xxl)
        .background(.bar)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch selectedStep {
        case .intro:
            introStep
        case .runtime:
            runtimeStep
        case .models:
            modelsStep
        }
    }

    private var introStep: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 36) {
                FirstRunHeroVisual()
                    .frame(width: 180, height: 180)

                heroCopy
                    .frame(maxWidth: 500, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.loose) {
                FirstRunHeroVisual()
                    .frame(width: 128, height: 128)
                heroCopy
            }
        }
    }

    private var runtimeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.md) {
                Text("Getting MLXtra ready")
                    .font(.system(size: 28, weight: .semibold))

                Text("Required local files download in the background. Choose your first model while setup finishes.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RuntimeSetupStatusView(runtimeUpdateManager: runtimeUpdateManager, isCompact: false)
        }
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.md) {
                    Text("Choose your first model")
                        .font(.system(size: 28, weight: .semibold))

                    Text("Start with the recommended Chat model for this Mac, or choose another local generation model.")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MLXtraDesignSystem.Spacing.xxl)

                Button {
                    onOpenModels()
                } label: {
                    Label("Browse Models", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
            }

            if let bestChatModel = FirstRunStarterModel.bestChatForThisMac() {
                FirstRunBestChatModelView(item: bestChatModel) {
                    onOpenModel(bestChatModel.model)
                }
            }

            if !starterModels.isEmpty {
                VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xl) {
                    Text("More local capabilities")
                        .font(MLXtraDesignSystem.Typography.sectionTitle)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xl) {
                        ForEach(starterModels.filter { $0.model.modality != .vision }) { item in
                            FirstRunStarterModelButton(item: item) {
                                onOpenModel(item.model)
                            }
                        }
                    }
                }
            }
        }
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xxl) {
            VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.md) {
                Text("Set up local AI")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Chat, create images, generate speech, and make music with models that run on your Mac.")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: MLXtraDesignSystem.Spacing.md) {
                FirstRunCapabilityPill(title: "Private", icon: "lock")
                FirstRunCapabilityPill(title: "Local", icon: "apple.logo")
                FirstRunCapabilityPill(title: "Extensible", icon: "slider.horizontal.3")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: MLXtraDesignSystem.Spacing.md) {
            if selectedStep != .intro {
                Button {
                    goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            }

            Text("Local generation becomes available as downloads finish.")
                .font(MLXtraDesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button {
                goForwardOrFinish()
            } label: {
                Label(primaryActionTitle, systemImage: selectedStep == .models ? "checkmark" : "arrow.right")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, MLXtraDesignSystem.Spacing.xxl)
        .background(.bar)
    }

    private var primaryActionTitle: String {
        selectedStep == .models ? "Start MLXtra" : "Continue"
    }

    private func goBack() {
        withAnimation(.easeInOut(duration: MLXtraDesignSystem.Motion.focusDuration)) {
            selectedStep = selectedStep.previous ?? .intro
        }
    }

    private func goForwardOrFinish() {
        guard let nextStep = selectedStep.next else {
            onContinue()
            return
        }

        withAnimation(.easeInOut(duration: MLXtraDesignSystem.Motion.focusDuration)) {
            selectedStep = nextStep
        }
    }

}

private enum FirstRunStep: String, CaseIterable, Identifiable {
    case intro
    case runtime
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .intro:
            return "Intro"
        case .runtime:
            return "Setup"
        case .models:
            return "Models"
        }
    }

    var systemImage: String {
        switch self {
        case .intro:
            return "sparkles"
        case .runtime:
            return "arrow.down.circle"
        case .models:
            return "square.grid.2x2"
        }
    }

    var next: FirstRunStep? {
        switch self {
        case .intro:
            return .runtime
        case .runtime:
            return .models
        case .models:
            return nil
        }
    }

    var previous: FirstRunStep? {
        switch self {
        case .intro:
            return nil
        case .runtime:
            return .intro
        case .models:
            return .runtime
        }
    }
}

private struct FirstRunStepButton: View {
    let step: FirstRunStep
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: MLXtraDesignSystem.Spacing.xs) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 11, weight: .semibold))

                Text(step.title)
                    .font(MLXtraDesignSystem.Typography.captionMedium)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .padding(.horizontal, MLXtraDesignSystem.Spacing.md)
            .frame(height: 28)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.22) : MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(step.title)
    }
}
