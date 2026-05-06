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
    private let avatarSize: CGFloat = 28
    private let messageMaxWidth: CGFloat = 820
    private let generatedMediaColumnWidth: CGFloat = 540

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
        HStack(alignment: .top, spacing: 12) {
            if message.isUser {
                Spacer(minLength: 40)
            }

            if !message.isUser {
                avatar(systemName: "sparkle", background: Color.accentColor)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
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
                        Group {
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
                        .contextMenu {
                            Button("Copy") {
                                copyToClipboard()
                            }
                        }
                    }
                } else {
                    UserMessageContent(
                        message: message,
                        isStreaming: isStreaming,
                        cursorVisible: cursorVisible
                    )
                    .frame(maxWidth: messageMaxWidth, alignment: .trailing)
                }

                if !message.isUser && !message.content.isEmpty && !isStreaming {
                    ResponseActionsToolbar(
                        showCopyFeedback: showCopyFeedback,
                        onCopy: copyToClipboard
                    )
                    .opacity(isHovered || showCopyFeedback ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered || showCopyFeedback)
                }

                if !message.isUser, !isStreaming, let metrics = message.performanceMetrics {
                    GenerationMetricsView(metrics: metrics)
                        .frame(maxWidth: messageMaxWidth, alignment: .leading)
                }

                if !isStreaming {
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: messageMaxWidth, alignment: message.isUser ? .trailing : .leading)
                }
            }
            .frame(maxWidth: messageMaxWidth, alignment: message.isUser ? .trailing : .leading)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }

            if !message.isUser {
                Spacer(minLength: 40)
            }

            if message.isUser {
                avatar(systemName: "person.fill", background: Color(NSColor.secondaryLabelColor))
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
    }

    private func avatar(systemName: String, background: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14))
            .foregroundStyle(Color.white)
            .frame(width: avatarSize, height: avatarSize)
            .background(background)
            .clipShape(Circle())
    }

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

private struct GenerationMetricsView: View {
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
        Label(summary, systemImage: "speedometer")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
            .accessibilityIdentifier("message.performanceMetrics")
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
    private let controlButtonSize: CGFloat = 34
    private let playButtonSize: CGFloat = 44

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
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: playButtonSize, height: playButtonSize)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color.accentColor,
                                    Color(red: 0.08, green: 0.46, blue: 0.94)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .shadow(color: Color.accentColor.opacity(0.16), radius: 7, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 3) {
                    Text(mediaTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(audioURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
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
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formattedDuration)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [
                    Color(NSColor.controlBackgroundColor).opacity(0.92),
                    Color.accentColor.opacity(0.08),
                    Color(NSColor.windowBackgroundColor).opacity(0.9)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 5)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: controlButtonSize, height: controlButtonSize)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.28), lineWidth: 1)
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
            .onChange(of: size.width) { newWidth in
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
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )

            Text(imageURL.lastPathComponent)
                .font(.system(size: 10))
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

struct ResponseActionsToolbar: View {
    let showCopyFeedback: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCopy) {
                Label(showCopyFeedback ? "Copied" : "Copy", systemImage: showCopyFeedback ? "checkmark" : "doc.on.doc")
            }
            .help("Copy response")

            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

struct GeneratedImageAttachmentView: View {
    let imageURL: URL
    @State private var downloadError: String?
    @State private var showLightbox = false
    private let controlButtonSize: CGFloat = 38

    private var loadedImage: NSImage? {
        ImageCache.shared.image(for: imageURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.045))

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
                            .font(.system(size: 11))
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
                        .font(.system(size: 13, weight: .semibold))
                    Text(imageURL.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button(action: revealImage) {
                    Label("Reveal", systemImage: "folder")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                Button(action: downloadImage) {
                    Label("Download", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help("Download image")
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(NSColor.controlBackgroundColor),
                    Color.accentColor.opacity(0.055)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 1)
        )
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
                    if isStreaming || AIContentRenderingPolicy.shouldUseFastPlainText(for: mainContent) {
                        StreamingPlainTextView(text: mainContent + (isStreaming && cursorVisible ? "▊" : ""))
                    } else {
                        MarkdownTextView(
                            text: mainContent,
                            isStreaming: false
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
    private var lastScrollTime = Date.distantPast
    private var pendingScrollToBottom = false

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
        scheduleScrollToBottom()
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
        if autoScroll {
            scheduleScrollToBottom()
        }
    }

    private func configureTextView() {
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
        textView.font = NSFont.systemFont(ofSize: 14.5)
        textView.textColor = NSColor.labelColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    private func configureContainer(width: CGFloat) {
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

    private func scheduleScrollToBottom() {
        guard !pendingScrollToBottom else { return }
        pendingScrollToBottom = true

        let minimumScrollInterval: TimeInterval = 1.0 / 30.0
        let delay = max(0, minimumScrollInterval - Date().timeIntervalSince(lastScrollTime))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pendingScrollToBottom = false
            self.lastScrollTime = Date()
            self.scrollEnclosingViewToBottom()
        }
    }

    private func scrollEnclosingViewToBottom() {
        guard let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else { return }

        let maxY = max(documentView.bounds.height - scrollView.contentView.bounds.height, 0)
        let targetY = documentView.isFlipped ? maxY : 0
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func attributedString(_ string: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        return NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14.5),
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 26, height: 26)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 6) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))

                Text(notice.detail)
                    .font(.system(size: 13))
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
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(content)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                Text("Thinking")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parsedBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineText(content)
                .font(.system(size: headingSize(for: level), weight: .semibold))
                .lineSpacing(4)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let content):
            inlineText(content)
                .font(.system(size: 14.5))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let lines):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    inlineText(line)
                        .font(.system(size: 14.5))
                        .lineSpacing(5)
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
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        inlineText(item)
                            .font(.system(size: 14.5))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        inlineText(item)
                            .font(.system(size: 14.5))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .taskList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.isComplete ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(item.isComplete ? Color.accentColor : .secondary)
                            .frame(width: 18, alignment: .trailing)
                        inlineText(item.text)
                            .font(.system(size: 14.5))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .codeBlock(let language, let content):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 1)
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

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 19
        case 3: return 17
        default: return 15
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
}

private struct MarkdownTableView: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownInlineSegment.inlineAttributedString(cell))
                                .font(.system(size: 13, weight: rowIndex == 0 ? .semibold : .regular))
                                .lineSpacing(3)
                                .frame(minWidth: 92, maxWidth: 220, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(rowIndex == 0 ? Color.accentColor.opacity(0.08) : Color.clear)
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 1)
            )
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MarkdownMathBlockView: View {
    let content: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(LatexRenderer.render(content))
                .font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
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
                        .fill(statusColor.opacity(0.14))
                        .frame(width: 26, height: 26)

                    Image(systemName: toolCall.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                Text(toolCall.toolName)
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Text(headerStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.1))
                    .clipShape(Capsule())

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if isExpanded, shouldShowDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detailTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(toolCall.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !toolCall.details.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(toolCall.details.enumerated()), id: \.offset) { _, detail in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(detail.label)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(detail.value)
                                        .font(.system(size: 11))
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
            LinearGradient(
                colors: [
                    Color(NSColor.controlBackgroundColor),
                    statusColor.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.16), lineWidth: 1)
        )
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
