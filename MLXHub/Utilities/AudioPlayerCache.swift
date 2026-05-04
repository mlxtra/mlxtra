import AVFoundation

/// Caches AVAudioPlayer instances keyed by URL to avoid reloading audio files
/// from disk when GeneratedAudioAttachmentView scrolls in/out of a LazyVStack.
@MainActor
final class AudioPlayerCache {
    static let shared = AudioPlayerCache()

    private var players: [URL: AVAudioPlayer] = [:]

    private init() {}

    func player(for url: URL) -> AVAudioPlayer? {
        if let cached = players[url] {
            cached.currentTime = 0
            cached.prepareToPlay()
            return cached
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[url] = player
        return player
    }

    func invalidate(url: URL) {
        players[url]?.stop()
        players[url] = nil
    }

    func invalidateAll() {
        for player in players.values {
            player.stop()
        }
        players.removeAll()
    }
}
