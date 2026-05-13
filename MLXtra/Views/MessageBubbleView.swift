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
            }
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

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation {
                    showCopyFeedback = false
                }
            }
        }
    }

    private func startCursorAnimation() {
        Task { @MainActor in
            while isStreaming {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if isStreaming {
                    cursorVisible.toggle()
                }
            }
            cursorVisible = false
        }
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

    var body: some View {
        HStack(spacing: MLXtraDesignSystem.Spacing.xs) {
            Image(systemName: "speedometer")
                .font(.system(size: MLXtraDesignSystem.Icon.micro, weight: .medium))

            Text(summary)
                .font(MLXtraDesignSystem.Typography.microMedium)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("message.performanceMetrics")
        }
        .foregroundStyle(.tertiary)
        .help(summary)
        .accessibilityLabel(summary)
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

struct GeneratedAudioAttachmentView: View {
    let audioURL: URL
    @State private var sound: NSSound?
    @State private var isPlaying = false
    @State private var downloadError: String?
    @State private var player: AVAudioPlayer?
    @State private var playbackProgress: Double = 0
    @State private var isSeeking = false
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var playbackTask: Task<Void, Never>?
    private let controlButtonSize: CGFloat = MLXtraDesignSystem.Icon.mediaActionButton
    private let playButtonSize: CGFloat = MLXtraDesignSystem.Icon.mediaPrimaryButton

    private var isMusic: Bool {
        audioURL.path.localizedCaseInsensitiveContains("music")
    }

    private var mediaTitle: String {
        isMusic ? "Generated music" : "Generated speech"
    }

    private var displayedProgress: Double {
        isSeeking ? playbackProgress : (duration > 0 ? currentTime / duration : 0)
    }

    private var formattedCurrentTime: String {
        formatTime(isSeeking ? playbackProgress * duration : currentTime)
    }

    private var formattedDuration: String {
        formatTime(duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: MLXtraDesignSystem.Icon.large, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: playButtonSize, height: playButtonSize)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 3) {
                    Text(mediaTitle)
                        .font(MLXtraDesignSystem.Typography.compactBodySemibold)
                        .foregroundStyle(.primary)

                    Text(audioURL.lastPathComponent)
                        .font(MLXtraDesignSystem.Typography.captionMedium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    audioActionButton(systemImage: "folder", help: "Reveal in Finder", action: revealAudio)
                    audioActionButton(systemImage: "square.and.arrow.down", help: "Download audio", action: downloadAudio)
                }
            }

            VStack(spacing: 5) {
                AudioWaveformScrubber(
                    progress: displayedProgress,
                    seed: audioURL.lastPathComponent,
                    onSeek: { newProgress, isFinal in
                        let clampedProgress = min(max(newProgress, 0), 1)
                        isSeeking = !isFinal
                        playbackProgress = clampedProgress
                        let seekTime = clampedProgress * duration
                        currentTime = seekTime
                        if isFinal {
                            player?.currentTime = seekTime
                        }
                    }
                )
                .frame(height: 20)

                HStack {
                    Text(formattedCurrentTime)
                        .font(MLXtraDesignSystem.Typography.codeCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formattedDuration)
                        .font(MLXtraDesignSystem.Typography.codeCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .designContentSurface(cornerRadius: MLXtraDesignSystem.Radius.media)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(audioURL.lastPathComponent)
        .accessibilityIdentifier(
            isMusic ? "generated.audio.music" : "generated.audio.speech"
        )
        .accessibilityValue(audioURL.path)
        .contextMenu {
            Button(isPlaying ? "Pause Audio" : "Play Audio", action: togglePlayback)
            Button("Reveal in Finder", action: revealAudio)
            Button("Download Audio", action: downloadAudio)
        }
        .onAppear {
            loadPlayer()
        }
        .onDisappear {
            stopPlayback()
            sound?.stop()
            isPlaying = false
        }
        .alert("Download failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "Unable to save the audio.")
        }
    }

    private func audioActionButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: MLXtraDesignSystem.Icon.regular, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: controlButtonSize, height: controlButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func loadPlayer() {
        if let cached = AudioPlayerCache.shared.player(for: audioURL) {
            player = cached
            duration = cached.duration
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: audioURL)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        } catch {
            sound = NSSound(contentsOf: audioURL, byReference: true)
            duration = sound?.duration ?? 0
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        if let player {
            player.play()
            isPlaying = true
            startTimer()
        } else {
            let loadedSound = sound ?? NSSound(contentsOf: audioURL, byReference: true)
            sound = loadedSound
            sound?.play()
            isPlaying = loadedSound != nil
        }
    }

    private func pausePlayback() {
        player?.pause()
        sound?.stop()
        stopTimer()
        isPlaying = false
    }

    private func stopPlayback() {
        player?.stop()
        player?.currentTime = 0
        sound?.stop()
        stopTimer()
        isPlaying = false
        currentTime = 0
        playbackProgress = 0
    }

    private func startTimer() {
        stopTimer()
        playbackTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let player else { break }

                if !isSeeking {
                    currentTime = player.currentTime
                }

                if !player.isPlaying {
                    if isPlaying {
                        isPlaying = false
                        currentTime = 0
                        player.currentTime = 0
                    }
                    playbackProgress = 0
                    break
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func stopTimer() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func formatTime(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    private func downloadAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = audioURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: audioURL, to: destinationURL)
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private func revealAudio() {
        NSWorkspace.shared.activateFileViewerSelecting([audioURL])
    }
}

private struct AudioWaveformScrubber: View {
    let progress: Double
    let seed: String
    let onSeek: (Double, Bool) -> Void

    private let barCount = 42
    private let barSpacing: CGFloat = 3

    @State private var barRatios: [CGFloat] = []
    @State private var barWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let clampedProgress = min(max(progress, 0), 1)
            let activeWidth = geometry.size.width * clampedProgress
            let size = geometry.size

            ZStack(alignment: .leading) {
                waveformBars(size: size, color: Color(NSColor.separatorColor).opacity(0.42))
                waveformBars(size: size, color: Color.accentColor)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: activeWidth)
                    }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(value.location.x / max(size.width, 1), false)
                    }
                    .onEnded { value in
                        onSeek(value.location.x / max(size.width, 1), true)
                    }
            )
            .onAppear {
                let availableWidth = max(size.width - CGFloat(barCount - 1) * barSpacing, 1)
                barWidth = max(availableWidth / CGFloat(barCount), 2)
                if barRatios.isEmpty || barRatios.count != barCount {
                    barRatios = precomputeRatios()
                }
            }
            .onChange(of: size.width) { _, newWidth in
                let availableWidth = max(newWidth - CGFloat(barCount - 1) * barSpacing, 1)
                barWidth = max(availableWidth / CGFloat(barCount), 2)
            }
        }
        .accessibilityLabel("Audio progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }

    private func waveformBars(size: CGSize, color: Color) -> some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let ratio = barRatios[safe: index] ?? 0.5
                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                    .fill(color)
                    .frame(width: barWidth, height: AudioWaveformScrubberMetrics.barHeight(ratio: ratio, maxHeight: size.height))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func precomputeRatios() -> [CGFloat] {
        let stableSeed = seed.unicodeScalars.reduce(17) { p, s in (p &* 31) &+ Int(s.value) }
        return (0..<barCount).map { index in
            let base = stableSeed + index * 37
            let wave = abs(sin(Double(base) * 0.41))
            let accent = abs(cos(Double(base) * 0.17))
            return 0.28 + (wave * 0.47) + (accent * 0.2)
        }
    }
}

enum AudioWaveformScrubberMetrics {
    static func barHeight(ratio: CGFloat, maxHeight: CGFloat) -> CGFloat {
        max(7, maxHeight * ratio)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct UserMessageContent: View {
    let message: Message
    let isStreaming: Bool
    let cursorVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.imageURLs.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(message.imageURLs, id: \.self) { imageURL in
                        SentImageAttachmentView(imageURL: imageURL)
                    }
                }
                .frame(maxWidth: 300, alignment: .leading)
            }

            if !message.content.isEmpty || isStreaming {
                Text(message.content + (isStreaming && cursorVisible ? "▊" : ""))
                    .font(MLXtraDesignSystem.Typography.messageBody)
                    .lineSpacing(4)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
#if DEBUG
        .overlay {
            if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
                Color.primary.opacity(0.001)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("User message bubble")
                    .accessibilityIdentifier("message.user.bubble")
            }
        }
#endif
    }
}

struct SentImageAttachmentView: View {
    let imageURL: URL

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(nsImage: ImageCache.shared.image(for: imageURL) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 112, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )

            Text(imageURL.lastPathComponent)
                .font(MLXtraDesignSystem.Typography.micro)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: 112, alignment: .leading)
                .background(Color.black.opacity(0.45))
        }
        .help(imageURL.lastPathComponent)
    }
}

struct GeneratedImageAttachmentView: View {
    let imageURL: URL
    @State private var downloadError: String?
    @State private var showLightbox = false
    private let controlButtonSize: CGFloat = MLXtraDesignSystem.Icon.mediaActionButton

    private var loadedImage: NSImage? {
        ImageCache.shared.image(for: imageURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.media, style: .continuous)
                    .fill(Color.primary.opacity(0.035))

                if let loadedImage {
                    Image(nsImage: loadedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 320)
                        .padding(12)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("Image not available")
                            .font(MLXtraDesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 320)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 320)
            .contentShape(Rectangle())
            .onTapGesture {
                if loadedImage != nil {
                    showLightbox = true
                }
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generated image")
                        .font(MLXtraDesignSystem.Typography.compactBodySemibold)
                    Text(imageURL.lastPathComponent)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button(action: revealImage) {
                    Label("Reveal", systemImage: "folder")
                        .labelStyle(.iconOnly)
                        .font(.system(size: MLXtraDesignSystem.Icon.regular, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(
                            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                Button(action: downloadImage) {
                    Label("Download", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.system(size: MLXtraDesignSystem.Icon.regular, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(
                            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                }
                .buttonStyle(.plain)
                .help("Download image")
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .designContentSurface(cornerRadius: MLXtraDesignSystem.Radius.media)
        .help(imageURL.lastPathComponent)
        .accessibilityIdentifier("generated.image")
        .accessibilityValue(imageURL.path)
        .contextMenu {
            Button("Open Image", action: { showLightbox = true })
            Button("Reveal in Finder", action: revealImage)
            Button("Download Image", action: downloadImage)
        }
        .alert("Download failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "Unable to save the image.")
        }
        .onChange(of: showLightbox) { _, show in
            if show {
                ImageLightboxWindowController.show(imageURL: imageURL, onClose: { showLightbox = false })
            }
        }
    }

    private func downloadImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = imageURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: imageURL, to: destinationURL)
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private func revealImage() {
        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
    }
}

struct ImageLightboxView: View {
    let imageURL: URL
    let onClose: () -> Void
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var loadedImage: NSImage? {
        ImageCache.shared.image(for: imageURL)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                let newScale = lastScale * value.magnification
                                scale = min(max(newScale, 1), 5)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.0 {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1.0 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if scale > 1.0 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Image not available")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            VStack {
                HStack {
                    Spacer()

                    HStack(spacing: 12) {
                        if scale > 1.0 {
                            Button(action: resetZoom) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }

                        Button(action: revealImage) {
                            Image(systemName: "folder")
                                .font(.system(size: 14, weight: .medium))
                        }

                        Button(action: downloadImage) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 14, weight: .medium))
                        }

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(20)

                Spacer()

                HStack {
                    Text(imageURL.lastPathComponent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    if let loadedImage {
                        Text("\(Int(loadedImage.size.width))×\(Int(loadedImage.size.height))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Text("Double-click to zoom · Pinch to scale")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .keyboardShortcut(KeyEquivalent.escape, modifiers: [])
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.25)) {
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }

    private func downloadImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = imageURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.copyItem(at: imageURL, to: destinationURL)
        }
    }

    private func revealImage() {
        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
    }
}

private final class LightboxWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class ImageLightboxWindowController {
    private static var activeWindow: LightboxWindow?

    static func show(imageURL: URL, onClose: @escaping () -> Void) {
        close()

        let screen = NSScreen.main!
        let window = LightboxWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.isReleasedWhenClosed = false
        window.onCancel = {
            close()
            DispatchQueue.main.async { onClose() }
        }

        let hostingView = NSHostingView(
            rootView: ImageLightboxView(imageURL: imageURL, onClose: {
                close()
                DispatchQueue.main.async { onClose() }
            })
        )
        hostingView.frame = window.contentView?.bounds ?? screen.visibleFrame
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        window.makeKeyAndOrderFront(nil)
        activeWindow = window
    }

    static func close() {
        activeWindow?.close()
        activeWindow = nil
    }
}

// MARK: - AI Content View with Markdown
struct AIContentView: View {
    let content: String
    let isStreaming: Bool
    let cursorVisible: Bool
    let onCopy: () -> Void
    let onOpenModels: (() -> Void)?
    let onRestartLocalEngine: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let recoveryNotice = RecoveryNotice(content: content), !isStreaming {
                RecoveryNoticeView(
                    notice: recoveryNotice,
                    onOpenModels: onOpenModels,
                    onRestartLocalEngine: onRestartLocalEngine
                )
            } else {
                if let mainContent = ReasoningContentFilter.visibleText(from: content), !mainContent.isEmpty {
                    if isStreaming {
                        StreamingPlainTextView(text: mainContent + (isStreaming && cursorVisible ? "▊" : ""))
                    } else if AIContentRenderingPolicy.shouldUseFastPlainText(for: mainContent) {
                        PlainAssistantTextView(text: mainContent)
                    } else {
                        MarkdownTextView(
                            text: mainContent,
                            isStreaming: false
                        )
                    }
                }
            }
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlainAssistantTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(MLXtraDesignSystem.Typography.messageBody)
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("message.assistant.plainText")
    }
}

enum AIContentRenderingPolicy {
    static func shouldUseFastPlainText(for content: String) -> Bool {
        // Fast path: scan for structural Markdown markers.
        // Uses line-by-line prefix checks to avoid regex overhead in the hot path.

        let hasHeading = content.contains("\n# ") || content.hasPrefix("# ")
        let hasBold = content.contains("**")
        let hasItalic = content.contains("*") && hasItalicPair(content)
        let hasCodeBlock = content.contains("```")
        let hasUnorderedList = content.contains("\n- ") || content.hasPrefix("- ")
            || content.contains("\n* ") || content.hasPrefix("* ")
            || content.contains("\n+ ") || content.hasPrefix("+ ")
        let hasOrderedList = hasOrderedListPrefix(content)
        let hasTable = content.contains("|") && hasTableSeparator(content)
        let hasBlockquote = content.contains("\n> ") || content.hasPrefix("> ")
        let hasMath = content.contains("$$") || content.contains("\\[")
        let hasLink = content.contains("](")
        return !hasHeading && !hasBold && !hasItalic && !hasCodeBlock
            && !hasUnorderedList && !hasOrderedList && !hasTable
            && !hasBlockquote && !hasMath && !hasLink
    }

    private static func hasItalicPair(_ text: String) -> Bool {
        var openSingleStar = false
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "*" else {
                index = text.index(after: index)
                continue
            }

            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "*" {
                index = text.index(after: next)
                continue
            }

            if openSingleStar { return true }
            openSingleStar = true
            index = next
        }
        return false
    }

    private static func hasOrderedListPrefix(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmed = line.trimmingPrefix(while: { $0 == " " })
            guard let markerEnd = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else {
                continue
            }
            if let num = Int(trimmed[..<markerEnd]), num > 0, markerEnd < trimmed.endIndex {
                let next = trimmed[trimmed.index(after: markerEnd)]
                if next == " " { return true }
            }
        }
        return false
    }

    private static func hasTableSeparator(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") && s.hasSuffix("|") && s.contains("-") {
                let inner = s.dropFirst().dropLast()
                let parts = inner.split(separator: "|")
                if parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).allSatisfy({ ch in ch == "-" || ch == ":" || ch == " " }) }) {
                    return true
                }
            }
        }
        return false
    }
}

private struct StreamingPlainTextView: View {
    let text: String

    var body: some View {
        FastStreamingTextView(text: text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
    }
}

private struct StreamingAIContentView: View {
    let streamingContent: StreamingMessageContent
    let onOpenModels: (() -> Void)?
    let onRestartLocalEngine: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FastStreamingTextView(streamingContent: streamingContent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FastStreamingTextView: NSViewRepresentable {
    private let text: String?
    private let streamingContent: StreamingMessageContent?

    init(text: String) {
        self.text = text
        self.streamingContent = nil
    }

    init(streamingContent: StreamingMessageContent) {
        self.text = nil
        self.streamingContent = streamingContent
    }

    func makeNSView(context: Context) -> FastStreamingTextNativeView {
        FastStreamingTextNativeView()
    }

    func updateNSView(_ nsView: FastStreamingTextNativeView, context: Context) {
        if let streamingContent {
            nsView.bind(to: streamingContent)
        } else {
            nsView.updateStaticText(text ?? "")
        }
    }

    static func dismantleNSView(_ nsView: FastStreamingTextNativeView, coordinator: ()) {
        nsView.unbindStreamingContent()
    }
}

private final class FastStreamingTextNativeView: NSView {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var currentText = ""
    private var lastMeasuredWidth: CGFloat = 0
    private var cachedHeight: CGFloat = 18
    private var appliedRevision: Int?
    private var streamingCancellable: AnyCancellable?
    private var boundStreamingContentId: UUID?
    private var lastHeightMeasurementTime = Date.distantPast

    // Reasoning-filter cache — avoids full-string filter on every streaming token.
    private var lastFilterInput = ""
    private var lastFilterOutput = ""

    // Hybrid streaming Markdown state
    private let markdownState = StreamingMarkdownState()
    private let splitter = StreamingMarkdownSplitter()
    private let renderStyle = MarkdownRenderStyle.default

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTextView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTextView()
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: cachedHeight)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = max(bounds.width, 1)
        if abs(width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = width
            configureContainer(width: width)
            refreshMeasuredHeight(width: width, force: true)
        }
    }

    func bind(to streamingContent: StreamingMessageContent) {
        if boundStreamingContentId != streamingContent.id {
            unbindStreamingContent()
            boundStreamingContentId = streamingContent.id
            currentText = ""
            appliedRevision = nil
            markdownState.reset()
            textView.textStorage?.setAttributedString(NSAttributedString())
        }

        apply(streamingContent: streamingContent)

        if streamingCancellable == nil {
            streamingCancellable = streamingContent.$revision
                .dropFirst()
                .sink { [weak self, weak streamingContent] _ in
                    guard let streamingContent else { return }
                    self?.apply(streamingContent: streamingContent)
                }
        }
    }

    func unbindStreamingContent() {
        streamingCancellable?.cancel()
        streamingCancellable = nil
        boundStreamingContentId = nil
        lastFilterInput = ""
        lastFilterOutput = ""
        markdownState.reset()
    }

    func updateStaticText(_ text: String) {
        unbindStreamingContent()
        updateText(text, mutation: .replace(text), revision: nil, autoScroll: false, forceHeight: true)
    }

    private func apply(streamingContent: StreamingMessageContent) {
        let text: String
        if streamingContent.containsReasoningMarkup {
            let raw = streamingContent.text
            if raw == lastFilterInput {
                text = lastFilterOutput
            } else {
                let filtered = ReasoningContentFilter.visibleText(from: raw) ?? ""
                text = filtered
                lastFilterInput = raw
                lastFilterOutput = filtered
            }
        } else {
            text = streamingContent.text
            lastFilterInput = ""
            lastFilterOutput = ""
        }

        applySplitterBasedUpdate(
            text: text,
            revision: streamingContent.revision
        )
    }

    private func applySplitterBasedUpdate(text: String, revision: Int) {
        guard appliedRevision != revision else { return }
        appliedRevision = revision

        let result = splitter.splitStablePrefix(
            text,
            committedEndIndex: markdownState.committedEndIndex
        )

        guard let storage = textView.textStorage else { return }

        // Correct mutation order: [stable blocks][old tail] → [stable blocks][new stable][new tail]
        //
        // 1. Remove old tail first — otherwise stable blocks get appended after stale tail text
        let oldTailRange = markdownState.tailRange(storageLength: storage.length)
        if oldTailRange.length > 0 {
            storage.replaceCharacters(in: oldTailRange, with: NSAttributedString())
        }

        // 2. Append newly stable blocks (rendered once, never touched again)
        if !result.newBlocks.isEmpty {
            let blockAttr = MarkdownAttributedRenderer.attributedString(
                from: result.newBlocks,
                style: renderStyle
            )
            // Insert paragraph separator between existing stable blocks and new ones,
            // matching what MarkdownAttributedRenderer does between blocks within a batch.
            if storage.length > 0 {
                storage.append(NSAttributedString(string: "\n"))
            }
            storage.append(blockAttr)
        }

        // 3. Update stable end after stable blocks are appended
        markdownState.stableStorageEndLocation = storage.length
        markdownState.committedEndIndex = result.newCommittedEndIndex
        markdownState.committedUTF16Offset = result.newCommittedUTF16Offset

        // 4. Append new tail
        let tailAttr = MarkdownAttributedRenderer.tailAttributedString(
            from: result.tail,
            style: renderStyle
        )
        if tailAttr.length > 0 {
            storage.append(tailAttr)
        }

        currentText = text
        configureContainer(width: max(bounds.width, 1))
        refreshMeasuredHeight(width: max(bounds.width, 1), force: true)
        needsLayout = true
    }

    private func updateText(
        _ newText: String,
        mutation: StreamingMessageContentMutation,
        revision: Int?,
        autoScroll: Bool,
        forceHeight: Bool
    ) {
        if let revision {
            guard appliedRevision != revision else { return }
            appliedRevision = revision
        } else {
            guard newText != currentText else { return }
        }

        switch mutation {
        case .append(let delta) where !currentText.isEmpty || newText == delta:
            textView.textStorage?.append(attributedString(delta))
        case .replace(let text):
            textView.textStorage?.setAttributedString(attributedString(text))
        case .append:
            if newText.hasPrefix(currentText) {
                let delta = String(newText.dropFirst(currentText.count))
                textView.textStorage?.append(attributedString(delta))
            } else {
                textView.textStorage?.setAttributedString(attributedString(newText))
            }
        }

        currentText = newText
        configureContainer(width: max(bounds.width, 1))
        refreshMeasuredHeight(width: max(bounds.width, 1), force: forceHeight)
        needsLayout = true
    }

    private func configureTextView() {
        wantsLayer = true
        layer?.masksToBounds = true

        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView
        addSubview(scrollView)

#if DEBUG
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            scrollView.setAccessibilityIdentifier("message.assistant.nativeTextScroll")
            textView.setAccessibilityIdentifier("message.assistant.nativeTextView")
        }
#endif
    }

    private func configureContainer(width: CGFloat) {
        let height = max(cachedHeight, bounds.height, 18)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    }

    private func refreshMeasuredHeight(width: CGFloat, force: Bool) {
        let now = Date()
        let isEarlyContent = currentText.count < 200
        let effectiveInterval: TimeInterval = isEarlyContent ? 1.0 / 60.0 : 1.0 / 30.0
        guard force || now.timeIntervalSince(lastHeightMeasurementTime) >= effectiveInterval else {
            return
        }
        lastHeightMeasurementTime = now

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        configureContainer(width: width)
        layoutManager.ensureLayout(for: textContainer)
        let height = max(18, ceil(layoutManager.usedRect(for: textContainer).height))
        guard abs(height - cachedHeight) > 0.5 else { return }

        cachedHeight = height
        invalidateIntrinsicContentSize()
    }

    private func shouldForceHeightRefresh(for mutation: StreamingMessageContentMutation) -> Bool {
        switch mutation {
        case .append(let delta):
            return delta.contains("\n") || delta.count > 120
        case .replace:
            return true
        }
    }

    private func attributedString(_ string: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
    }
}

private enum RecoveryAction {
    case openModels
    case restart
}

private struct RecoveryNotice {
    let title: String
    let detail: String
    let systemImage: String
    let actionTitle: String?
    let action: RecoveryAction?

    init?(content: String) {
        switch content {
        case "The local engine stopped before it could finish. Restart it, then try again.":
            title = "Local engine stopped"
            detail = content
            systemImage = "exclamationmark.triangle"
            actionTitle = "Restart"
            action = .restart
        case "The selected model could not be loaded. Open Models to check the download, then try again.":
            title = "Model needs attention"
            detail = content
            systemImage = "arrow.down.circle"
            actionTitle = "Open Models"
            action = .openModels
        case "This took longer than expected. Please try again.":
            title = "Request timed out"
            detail = content
            systemImage = "clock"
            actionTitle = nil
            action = nil
        case "Please send your message again.",
             "The request could not be completed. Please try again.":
            title = "Request not completed"
            detail = content
            systemImage = "arrow.clockwise"
            actionTitle = nil
            action = nil
        default:
            return nil
        }
    }
}

private struct RecoveryNoticeView: View {
    let notice: RecoveryNotice
    let onOpenModels: (() -> Void)?
    let onRestartLocalEngine: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.systemImage)
                .font(.system(size: MLXtraDesignSystem.Icon.medium, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 26, height: 26)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 6) {
                Text(notice.title)
                    .font(MLXtraDesignSystem.Typography.compactBodySemibold)

                Text(notice.detail)
                    .font(MLXtraDesignSystem.Typography.compactBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = notice.actionTitle, let action = actionHandler {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var actionHandler: (() -> Void)? {
        switch notice.action {
        case .openModels:
            return onOpenModels
        case .restart:
            return onRestartLocalEngine
        case nil:
            return nil
        }
    }
}

// MARK: - Thinking View
struct ThinkingView: View {
    let content: String
    let isStreaming: Bool
    @State private var isExpanded: Bool
    
    init(content: String, isStreaming: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
        // Start expanded while streaming, collapsed when complete
        self._isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        ClickableDisclosureSection(isExpanded: $isExpanded) {
            Text(content)
                .font(MLXtraDesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: MLXtraDesignSystem.Icon.small))
                Text("Thinking")
                    .font(MLXtraDesignSystem.Typography.captionMedium)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)
    }
}

// MARK: - Markdown Text View
struct MarkdownTextView: View {
    let text: String
    let isStreaming: Bool

    private var parsedBlocks: [MarkdownBlock] {
        if let cached = MarkdownCache.shared.blocks(for: text) {
            return cached
        }
        let blocks = MarkdownBlockRenderer.blocks(from: text)
        MarkdownCache.shared.setBlocks(blocks, for: text)
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MLXtraDesignSystem.Spacing.md + 1) {
            ForEach(Array(parsedBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .accessibilityIdentifier(markdownAccessibilityIdentifier(for: block))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown.content")
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineText(content)
                .font(MLXtraDesignSystem.Typography.markdownHeading(level: level))
                .lineSpacing(4)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let content):
            inlineText(content)
                .font(MLXtraDesignSystem.Typography.messageBody)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let lines):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    inlineText(line)
                        .font(MLXtraDesignSystem.Typography.messageBody)
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
            }

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(MLXtraDesignSystem.Typography.messageBodyStrong)
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        inlineText(item)
                            .font(MLXtraDesignSystem.Typography.messageBody)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(MLXtraDesignSystem.Typography.messageBodyStrong)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        inlineText(item)
                            .font(MLXtraDesignSystem.Typography.messageBody)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .taskList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.isComplete ? "checkmark.square.fill" : "square")
                            .font(.system(size: MLXtraDesignSystem.Icon.regular))
                            .foregroundStyle(item.isComplete ? Color.accentColor : .secondary)
                            .frame(width: 18, alignment: .trailing)
                        inlineText(item.text)
                            .font(MLXtraDesignSystem.Typography.messageBody)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .codeBlock(let language, let content):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(MLXtraDesignSystem.Typography.codeCaption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(MLXtraDesignSystem.Typography.code)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                    .stroke(MLXtraDesignSystem.Surface.hairline, lineWidth: 1)
            )

        case .table(let rows):
            MarkdownTableView(rows: rows)

        case .mathBlock(let content):
            MarkdownMathBlockView(content: content)

        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func inlineText(_ content: String) -> Text {
        MarkdownInlineSegment.parseSegments(content).reduce(Text("")) { partial, segment in
            switch segment {
            case .text(let value):
                return partial + Text(MarkdownInlineSegment.inlineAttributedString(value))
            case .math(let value):
                return partial + Text(LatexRenderer.render(value))
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundColor(.accentColor)
            }
        }
    }

    private func markdownAccessibilityIdentifier(for block: MarkdownBlock) -> String {
        switch block {
        case .heading:
            return "markdown.heading"
        case .paragraph:
            return "markdown.paragraph"
        case .quote:
            return "markdown.quote"
        case .unorderedList, .orderedList, .taskList:
            return "markdown.list"
        case .codeBlock:
            return "markdown.codeBlock"
        case .table:
            return "markdown.table"
        case .mathBlock:
            return "markdown.mathBlock"
        case .divider:
            return "markdown.divider"
        }
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                            Text(MarkdownInlineSegment.inlineAttributedString(cell))
                                .font(rowIndex == 0 ? MLXtraDesignSystem.Typography.compactBodySemibold : MLXtraDesignSystem.Typography.compactBody)
                                .lineSpacing(3)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: columnWidths[columnIndex], alignment: .topLeading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(rowIndex == 0 ? Color.accentColor.opacity(0.08) : Color.clear)
                                .overlay(alignment: .trailing) {
                                    if columnIndex < columnCount - 1 {
                                        Rectangle()
                                            .fill(MLXtraDesignSystem.Surface.hairline)
                                            .frame(width: 1)
                                    }
                                }
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous)
                    .stroke(MLXtraDesignSystem.Surface.hairline, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.control, style: .continuous))
    }

    private var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    private var normalizedRows: [[String]] {
        rows.map { row in
            let missingCells = max(0, columnCount - row.count)
            return row + Array(repeating: "", count: missingCells)
        }
    }

    private var columnWidths: [CGFloat] {
        guard columnCount > 0 else { return [] }

        return (0..<columnCount).map { columnIndex in
            let longestCellLength = normalizedRows
                .map { $0[columnIndex].count }
                .max() ?? 0
            let measuredWidth = CGFloat(min(longestCellLength, 46)) * 7.4 + 32
            let minimumWidth: CGFloat = columnIndex == 0 ? 140 : 112
            let maximumWidth: CGFloat = longestCellLength > 34 ? 360 : 260
            return min(max(measuredWidth, minimumWidth), maximumWidth)
        }
    }
}

private struct MarkdownMathBlockView: View {
    let content: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(LatexRenderer.render(content))
                .font(.system(size: 15, weight: .medium, design: .serif))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .designTintSurface(Color.accentColor, cornerRadius: MLXtraDesignSystem.Radius.control)
        .accessibilityIdentifier("markdown.mathBlock")
    }
}

enum LatexRenderer {
    private static let commandReplacements: [(String, String)] = [
        ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\Rightarrow", "⇒"),
        ("\\Leftarrow", "⇐"), ("\\times", "×"), ("\\cdot", "·"),
        ("\\leq", "≤"), ("\\geq", "≥"), ("\\neq", "≠"), ("\\approx", "≈"),
        ("\\pm", "±"), ("\\infty", "∞"), ("\\sum", "∑"), ("\\prod", "∏"),
        ("\\int", "∫"), ("\\partial", "∂"), ("\\nabla", "∇"), ("\\alpha", "α"),
        ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"), ("\\epsilon", "ε"),
        ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ"), ("\\pi", "π"),
        ("\\sigma", "σ"), ("\\omega", "ω"), ("\\Delta", "Δ"), ("\\Omega", "Ω")
    ]

    private static let superscriptMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ"
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ"
    ]

    static func render(_ input: String) -> String {
        var result = input.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result
            .replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")

        result = replaceCommand("\\frac", arity: 2, in: result) { values in
            "\(render(values[0]))⁄\(render(values[1]))"
        }
        result = replaceCommand("\\sqrt", arity: 1, in: result) { values in
            "√(\(render(values[0])))"
        }
        result = replaceCommand("\\text", arity: 1, in: result) { values in
            values[0]
        }

        for (source, replacement) in commandReplacements {
            result = result.replacingOccurrences(of: source, with: replacement)
        }

        result = replaceScript(marker: "^", map: superscriptMap, in: result)
        result = replaceScript(marker: "_", map: subscriptMap, in: result)
        return result.replacingOccurrences(of: "\\", with: "")
    }

    private static func replaceCommand(
        _ command: String,
        arity: Int,
        in text: String,
        transform: ([String]) -> String
    ) -> String {
        var output = text

        while let commandRange = output.range(of: command) {
            var cursor = commandRange.upperBound
            var values: [String] = []

            for _ in 0..<arity {
                while cursor < output.endIndex, output[cursor].isWhitespace {
                    cursor = output.index(after: cursor)
                }
                guard let parsed = parseBracedGroup(in: output, from: cursor) else {
                    return output
                }
                values.append(parsed.content)
                cursor = parsed.endIndex
            }

            output.replaceSubrange(commandRange.lowerBound..<cursor, with: transform(values))
        }

        return output
    }

    private static func parseBracedGroup(in text: String, from start: String.Index) -> (content: String, endIndex: String.Index)? {
        guard start < text.endIndex, text[start] == "{" else { return nil }

        var depth = 0
        var cursor = start
        let contentStart = text.index(after: start)

        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(text[contentStart..<cursor]), text.index(after: cursor))
                }
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func replaceScript(marker: Character, map: [Character: Character], in text: String) -> String {
        var result = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard text[cursor] == marker else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }

            let valueStart = text.index(after: cursor)
            guard valueStart < text.endIndex else {
                result.append(marker)
                cursor = valueStart
                continue
            }

            let parsed: (content: String, endIndex: String.Index)
            if text[valueStart] == "{", let group = parseBracedGroup(in: text, from: valueStart) {
                parsed = group
            } else {
                parsed = (String(text[valueStart]), text.index(after: valueStart))
            }

            if let mapped = mappedScript(parsed.content, map: map) {
                result += mapped
            } else {
                result += "\(marker)(\(parsed.content))"
            }
            cursor = parsed.endIndex
        }

        return result
    }

    private static func mappedScript(_ value: String, map: [Character: Character]) -> String? {
        var result = ""
        for character in value {
            guard let mapped = map[character] else { return nil }
            result.append(mapped)
        }
        return result
    }
}

// MARK: - Tool Call View
struct ToolCallView: View {
    let toolCall: ToolCall
    let isStreaming: Bool
    let hasGeneratedMedia: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(iconTint.opacity(isComplete ? 0.08 : 0.14))
                        .frame(width: 26, height: 26)

                    Image(systemName: toolCall.icon)
                        .font(.system(size: MLXtraDesignSystem.Icon.small, weight: .semibold))
                        .foregroundStyle(iconTint)
                }

                Text(toolCall.toolName)
                    .font(MLXtraDesignSystem.Typography.captionMedium)

                Spacer()

                Text(headerStatus)
                    .font(MLXtraDesignSystem.Typography.captionMedium)
                    .foregroundStyle(statusBadgeForeground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusBadgeFill)
                    .clipShape(Capsule())

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: MLXtraDesignSystem.Icon.micro))
                    .foregroundStyle(.secondary)
            }

            if isExpanded, shouldShowDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detailTitle)
                        .font(MLXtraDesignSystem.Typography.microMedium)
                        .foregroundStyle(.secondary)
                    Text(toolCall.status)
                        .font(MLXtraDesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !toolCall.details.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(toolCall.details.enumerated()), id: \.offset) { _, detail in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(detail.label)
                                        .font(MLXtraDesignSystem.Typography.microMedium)
                                        .foregroundStyle(.secondary)
                                    Text(detail.value)
                                        .font(MLXtraDesignSystem.Typography.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                .fill(isComplete ? MLXtraDesignSystem.Surface.contentFill : MLXtraDesignSystem.Surface.tintFill(statusColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.card, style: .continuous)
                .stroke(isComplete ? MLXtraDesignSystem.Surface.quietHairline : statusColor.opacity(0.16), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    private var isImageGeneration: Bool {
        toolCall.icon == "photo" || toolCall.toolName.localizedCaseInsensitiveContains("image")
    }

    private var isWebSearch: Bool {
        toolCall.icon == "magnifyingglass" || toolCall.toolName.localizedCaseInsensitiveContains("search")
    }

    private var isAudioGeneration: Bool {
        toolCall.icon == "waveform" || toolCall.icon == "music.note" || toolCall.toolName.localizedCaseInsensitiveContains("speech") || toolCall.toolName.localizedCaseInsensitiveContains("music")
    }

    private var shouldShowDetails: Bool {
        !toolCall.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !toolCall.details.isEmpty
    }

    private var isComplete: Bool {
        hasGeneratedMedia || !isStreaming
    }

    private var headerStatus: String {
        if hasGeneratedMedia || !isStreaming {
            if isWebSearch {
                return "Searched"
            }

            if isImageGeneration {
                return "Generated"
            }

            if isAudioGeneration {
                return "Created"
            }

            return "Done"
        }

        if isImageGeneration {
            return "Generating"
        }

        if isAudioGeneration {
            return "Creating"
        }

        if isWebSearch {
            return "Searching"
        }

        return toolCall.status
    }

    private var detailTitle: String {
        if isImageGeneration {
            return "Prompt"
        }

        if isWebSearch {
            return "Query"
        }

        return "Details"
    }

    private var statusColor: Color {
        if isWebSearch {
            return Color(red: 0.28, green: 0.55, blue: 0.95)
        }

        if isImageGeneration {
            return Color(red: 0.88, green: 0.34, blue: 0.68)
        }

        if isAudioGeneration {
            return Color(red: 0.42, green: 0.68, blue: 0.42)
        }

        return Color.accentColor
    }

    private var iconTint: Color {
        isComplete ? MLXtraDesignSystem.Palette.secondaryLabel : statusColor
    }

    private var statusBadgeForeground: Color {
        isComplete ? MLXtraDesignSystem.Palette.secondaryLabel : statusColor
    }

    private var statusBadgeFill: Color {
        isComplete ? Color.primary.opacity(0.045) : statusColor.opacity(0.10)
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
