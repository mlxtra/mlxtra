import AppKit

/// Thread-safe image cache backed by NSCache, avoiding repeated disk I/O
/// for generated and attached images that are re-decoded on every SwiftUI body evaluation.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 50
    }

    func image(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let loaded = NSImage(contentsOf: url) else { return nil }
        cache.setObject(loaded, forKey: key)
        return loaded
    }

    func invalidate(url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func invalidateAll() {
        cache.removeAllObjects()
    }
}
