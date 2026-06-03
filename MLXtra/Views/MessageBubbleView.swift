import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
@preconcurrency import AVFoundation

struct MessageBubble: View {
    let message: Message
    let isStreaming: Bool
    let streamingContent: StreamingMessageContent?
    @State private var isHovered = false
    @State private var cursorVisible = true
    @State private var showCopyFeedback = false
    @State private var cursorAnimationTask: Task<Void, Never>?
    @State private var copyFeedbackTask: Task<Void, Never>?
    let onOpenModels: (() -> Void)?
    let onRestartLocalEngine: (() -> Void)?
    private let messageMaxWidth: CGFloat = MLXtraDesignSystem.Layout.messageMaxWidth
    private let generatedMediaColumnWidth: CGFloat = MLXtraDesignSystem.Layout.generatedMediaMaxWidth
    private let messageMetaRowReservedHeight: CGFloat = 20

    init(
        message: Message,
        isStreaming: Bool = false,
        streamingContent: StreamingMessageContent? = nil,
        onOpenModels: (() -> Void)? = nil,
        onRestartLocalEngine: (() -> Void)? = nil
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.streamingContent = streamingContent
        self.onOpenModels = onOpenModels
        self.onRestartLocalEngine = onRestartLocalEngine
    }

    var body: some View {
        HStack(alignment: .top, spacing: message.isUser ? 8 : 0) {
            if message.isUser {
                Spacer(minLength: 72)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: MLXtraDesignSystem.Spacing.xs) {
                ForEach(message.toolCalls) { toolCall in
                    ToolCallView(
                        toolCall: toolCall,
                        isStreaming: isStreaming,
                        hasGeneratedMedia: !message.imageURLs.isEmpty || !message.audioURLs.isEmpty
                    )
                    .frame(
                        maxWidth: (!message.imageURLs.isEmpty || !message.audioURLs.isEmpty) ? generatedMediaColumnWidth : messageMaxWidth,
                        alignment: message.isUser ? .trailing : .leading
                    )
                }

                if !message.isUser {
                    if !message.imageURLs.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220, maximum: generatedMediaColumnWidth), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(message.imageURLs, id: \.self) { imageURL in
                                GeneratedImageAttachmentView(imageURL: imageURL)
                            }
                        }
                        .frame(maxWidth: generatedMediaColumnWidth, alignment: .leading)
                    }

                    if !message.audioURLs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(message.audioURLs, id: \.self) { audioURL in
                                GeneratedAudioAttachmentView(audioURL: audioURL)
                            }
                        }
                        .frame(maxWidth: generatedMediaColumnWidth, alignment: .leading)
                    }

                    if !message.content.isEmpty || isStreaming {
                        VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.xxs) {
                            assistantBodyContent
                                .contextMenu {
                                    Button("Copy") {
                                        copyToClipboard()
                                    }
                                }
                                .frame(maxWidth: messageMaxWidth, alignment: .leading)
                                .clipped()

                            assistantMetaRowSlot
                        }
                        .frame(maxWidth: messageMaxWidth, alignment: .leading)
#if DEBUG
                        .overlay {
                            uiTestAssistantContentRailAnchor
                        }
#endif
                    }
                } else {
                    VStack(alignment: .trailing, spacing: MLXtraDesignSystem.Spacing.xxs) {
                        UserMessageContent(
                            message: message,
                            isStreaming: isStreaming,
                            cursorVisible: cursorVisible
                        )
                        .frame(maxWidth: messageMaxWidth, alignment: .trailing)

                        userMetaRowSlot
                    }
                    .frame(maxWidth: messageMaxWidth, alignment: .trailing)
                }
            }
            .frame(maxWidth: messageMaxWidth, alignment: message.isUser ? .trailing : .leading)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: MLXtraDesignSystem.Motion.hoverDuration)) {
                    isHovered = hovering
                }
            }

            if !message.isUser {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .onAppear {
            if isStreaming && message.isUser {
                startCursorAnimation()
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming && message.isUser {
                startCursorAnimation()
            } else {
                stopCursorAnimation()
            }
        }
        .onDisappear {
            stopCursorAnimation()
            stopCopyFeedbackTask()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(message.isUser ? "message.user" : "message.assistant")
        .accessibilityValue(message.content)
    }

    @ViewBuilder
    private var assistantBodyContent: some View {
        if isStreaming, let streamingContent {
            StreamingAIContentView(
                streamingContent: streamingContent,
                onOpenModels: onOpenModels,
                onRestartLocalEngine: onRestartLocalEngine
            )
        } else {
            AIContentView(
                content: message.content,
                isStreaming: isStreaming,
                cursorVisible: cursorVisible,
                onCopy: copyToClipboard,
                onOpenModels: onOpenModels,
                onRestartLocalEngine: onRestartLocalEngine
            )
        }
    }

    @ViewBuilder
    private var assistantMetaRowSlot: some View {
        if shouldReserveAssistantMetaRowSpace {
            ZStack(alignment: .leading) {
                Color.clear

                assistantHoverAccessory
            }
            .frame(
                maxWidth: messageMaxWidth,
                minHeight: messageMetaRowReservedHeight,
                maxHeight: messageMetaRowReservedHeight,
                alignment: .leading
            )
        }
    }

    private var hasCopyableAssistantContent: Bool {
        !message.isUser
            && (!message.content.isEmpty || !message.imageURLs.isEmpty || !message.audioURLs.isEmpty)
    }

    private var hasCopyableUserContent: Bool {
        message.isUser
            && (!message.content.isEmpty || !message.imageURLs.isEmpty || !message.audioURLs.isEmpty)
    }

    private var shouldShowAssistantMetaRow: Bool {
        !message.isUser
            && !isStreaming
            && (
                (isHovered && message.performanceMetrics != nil)
                    || (hasCopyableAssistantContent && (isHovered || showCopyFeedback))
            )
    }

    private var shouldReserveAssistantMetaRowSpace: Bool {
        !message.isUser
            && !isStreaming
            && (hasCopyableAssistantContent || message.performanceMetrics != nil || showCopyFeedback)
    }

    private var shouldShowUserMetaRow: Bool {
        message.isUser
            && !isStreaming
            && (isHovered || showCopyFeedback)
    }

    private var shouldReserveUserMetaRowSpace: Bool {
        message.isUser
            && !isStreaming
    }

    @ViewBuilder
    private var assistantHoverAccessory: some View {
        if shouldShowAssistantMetaRow {
            AssistantMessageMetaRow(
                metrics: isHovered ? message.performanceMetrics : nil,
                timestamp: message.timestamp,
                showsTimestamp: isHovered,
                showsCopyButton: hasCopyableAssistantContent && isHovered,
                showCopyFeedback: showCopyFeedback,
                onCopy: copyToClipboard
            )
            .frame(maxWidth: messageMaxWidth, alignment: .leading)
            .transition(.opacity)
#if DEBUG
            .overlay {
                uiTestHoverAccessoryAnchor
            }
#endif
        }
    }

    @ViewBuilder
    private var userMetaRowSlot: some View {
        if shouldReserveUserMetaRowSpace {
            ZStack(alignment: .trailing) {
                Color.clear

                userHoverAccessory
            }
            .frame(
                maxWidth: messageMaxWidth,
                minHeight: messageMetaRowReservedHeight,
                maxHeight: messageMetaRowReservedHeight,
                alignment: .trailing
            )
        }
    }

    @ViewBuilder
    private var userHoverAccessory: some View {
        if shouldShowUserMetaRow {
            UserMessageMetaRow(
                timestamp: message.timestamp,
                showsTimestamp: isHovered,
                showsCopyButton: hasCopyableUserContent && isHovered,
                showCopyFeedback: showCopyFeedback,
                onCopy: copyToClipboard
            )
            .frame(maxWidth: messageMaxWidth, alignment: .trailing)
            .transition(.opacity)
#if DEBUG
            .overlay {
                uiTestUserHoverAccessoryAnchor
            }
#endif
        }
    }

#if DEBUG
    @ViewBuilder
    private var uiTestAssistantContentRailAnchor: some View {
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            Color.primary.opacity(0.001)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Assistant content")
                .accessibilityIdentifier("message.assistant.content")
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var uiTestHoverAccessoryAnchor: some View {
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            Color.primary.opacity(0.001)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Assistant hover accessories")
                .accessibilityIdentifier("message.hoverAccessories")
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var uiTestUserHoverAccessoryAnchor: some View {
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            Color.primary.opacity(0.001)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("User message hover accessories")
                .accessibilityIdentifier("message.user.hoverAccessories")
                .allowsHitTesting(false)
        }
    }
#endif

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()

        var clipboardText = streamingContent?.text ?? message.content
        if !message.imageURLs.isEmpty {
            let attachments = message.imageURLs.map { $0.lastPathComponent }.joined(separator: ", ")
            clipboardText += clipboardText.isEmpty ? "Attachments: \(attachments)" : "\n\nAttachments: \(attachments)"
        }
        if !message.audioURLs.isEmpty {
            let attachments = message.audioURLs.map { $0.lastPathComponent }.joined(separator: ", ")
            clipboardText += clipboardText.isEmpty ? "Audio: \(attachments)" : "\n\nAudio: \(attachments)"
        }

        NSPasteboard.general.setString(clipboardText, forType: .string)

        withAnimation {
            showCopyFeedback = true
        }

        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation {
                showCopyFeedback = false
            }
        }
    }

    private func startCursorAnimation() {
        cursorAnimationTask?.cancel()
        cursorAnimationTask = Task { @MainActor in
            while !Task.isCancelled && isStreaming {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                if isStreaming {
                    cursorVisible.toggle()
                }
            }
            guard !Task.isCancelled else { return }
            cursorVisible = false
        }
    }

    private func stopCursorAnimation() {
        cursorAnimationTask?.cancel()
        cursorAnimationTask = nil
        cursorVisible = false
    }

    private func stopCopyFeedbackTask() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        showCopyFeedback = false
    }
}

private struct AssistantMessageMetaRow: View {
    let metrics: GenerationPerformanceMetrics?
    let timestamp: Date
    let showsTimestamp: Bool
    let showsCopyButton: Bool
    let showCopyFeedback: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: MLXtraDesignSystem.Spacing.xs) {
            if showsCopyButton || showCopyFeedback {
                Button(action: onCopy) {
                    HStack(spacing: MLXtraDesignSystem.Spacing.xs) {
                        Image(systemName: showCopyFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: MLXtraDesignSystem.Icon.micro, weight: .medium))

                        if showCopyFeedback {
                            Text("Copied")
                                .font(MLXtraDesignSystem.Typography.microMedium)
                        }
                    }
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: showCopyFeedback ? 54 : 18, minHeight: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy response")
                .accessibilityIdentifier("message.copy")
            }

            if let metrics {
                GenerationMetricsLabel(metrics: metrics)
            }

            if showsTimestamp {
                Text(timestamp, style: .time)
                    .font(MLXtraDesignSystem.Typography.microMedium)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 18)
    }
}

private struct UserMessageMetaRow: View {
    let timestamp: Date
    let showsTimestamp: Bool
    let showsCopyButton: Bool
    let showCopyFeedback: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: MLXtraDesignSystem.Spacing.xs) {
            if showsTimestamp {
                Text(timestamp, style: .time)
                    .font(MLXtraDesignSystem.Typography.microMedium)
                    .foregroundStyle(.tertiary)
            }

            if showsCopyButton || showCopyFeedback {
                Button(action: onCopy) {
                    HStack(spacing: MLXtraDesignSystem.Spacing.xs) {
                        if showCopyFeedback {
                            Text("Copied")
                                .font(MLXtraDesignSystem.Typography.microMedium)
                        }

                        Image(systemName: showCopyFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: MLXtraDesignSystem.Icon.micro, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: showCopyFeedback ? 54 : 18, minHeight: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy sent message")
                .accessibilityIdentifier("message.user.copy")
            }
        }
        .frame(height: 18)
    }
}

private struct GenerationMetricsLabel: View {
    let metrics: GenerationPerformanceMetrics

    private var summary: String {
        var parts: [String] = []
        if let ttft = metrics.timeToFirstToken {
            parts.append("TTFT \(formatSeconds(ttft))")
        }
        if let tokensPerSecond = metrics.tokensPerSecond {
            parts.append("\(formatNumber(tokensPerSecond)) tok/s")
        }
        if parts.isEmpty {
            parts.append("Completed in \(formatSeconds(metrics.totalDuration))")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        if let accelerationState = metrics.accelerationState {
            return "\(summary). \(accelerationState.displayText)"
        }
        return summary
    }

    var body: some View {
        HStack(spacing: MLXtraDesignSystem.Spacing.xs) {
            Image(systemName: "speedometer")
                .font(.system(size: MLXtraDesignSystem.Icon.micro, weight: .medium))

            Text(summary)
                .font(MLXtraDesignSystem.Typography.microMedium)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("message.performanceMetrics")

            if let accelerationState = metrics.accelerationState {
                Image(systemName: accelerationIcon(for: accelerationState))
                    .font(.system(size: MLXtraDesignSystem.Icon.micro, weight: .semibold))
                    .foregroundStyle(accelerationTint(for: accelerationState))
                    .help(accelerationState.displayText)
                    .accessibilityIdentifier("message.accelerationState")
            }
        }
        .foregroundStyle(.tertiary)
        .help(accessibilitySummary)
        .accessibilityLabel(accessibilitySummary)
    }

    private func accelerationIcon(for state: GenerationAccelerationState) -> String {
        switch state {
        case .active:
            return "bolt.fill"
        case .fallback, .unavailable:
            return "bolt.slash.fill"
        }
    }

    private func accelerationTint(for state: GenerationAccelerationState) -> Color {
        switch state {
        case .active:
            return .green
        case .fallback:
            return .orange
        case .unavailable:
            return .secondary
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        seconds < 10
            ? String(format: "%.2fs", max(seconds, 0))
            : String(format: "%.1fs", max(seconds, 0))
    }

    private func formatNumber(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }
}


#Preview {
    VStack(spacing: 16) {
        MessageBubble(message: Message(
            content: "Hello! How can I help you today?",
            isUser: false,
            timestamp: Date()
        ))

        MessageBubble(message: Message(
            content: "I need help with SwiftUI",
            isUser: true,
            timestamp: Date()
        ))
    }
    .padding()
}
