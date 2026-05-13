import AppKit
@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

private func copyGeneratedMediaFile(from sourceURL: URL, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    let temporaryURL = destinationURL
        .deletingLastPathComponent()
        .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")

    defer {
        try? fileManager.removeItem(at: temporaryURL)
    }

    try fileManager.copyItem(at: sourceURL, to: temporaryURL)
    if fileManager.fileExists(atPath: destinationURL.path) {
        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
    } else {
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
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
                            sound?.currentTime = seekTime
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
            if loadedSound != nil {
                startTimer()
            }
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
                if let player {
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
                } else if let sound {
                    if !isSeeking {
                        currentTime = sound.currentTime
                    }

                    if !sound.isPlaying {
                        if isPlaying {
                            isPlaying = false
                            currentTime = 0
                            sound.currentTime = 0
                        }
                        playbackProgress = 0
                        break
                    }
                } else {
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
        panel.allowedContentTypes = [UTType(filenameExtension: audioURL.pathExtension) ?? .wav]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = audioURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            do {
                try copyGeneratedMediaFile(from: audioURL, to: destinationURL)
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
