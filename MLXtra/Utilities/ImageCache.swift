@preconcurrency import AppKit
import SwiftUI

/// Thread-safe image cache backed by NSCache, avoiding repeated disk I/O
/// for generated and attached images that are re-decoded on every SwiftUI body evaluation.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 50
    }

    func cachedImage(for url: URL) -> NSImage? {
        let key = url as NSURL
        return cache.object(forKey: key)
    }

    func image(for url: URL) async -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }

        let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
            NSImage(contentsOf: url)
        }.value
        guard let loaded else {
            return nil
        }
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

struct AsyncCachedImage<Content: View, Placeholder: View>: View {
    let url: URL
    let content: (NSImage) -> Content
    let placeholder: () -> Placeholder
    let onLoad: (NSImage?) -> Void
    @State private var loadedImage: NSImage?

    init(
        url: URL,
        onLoad: @escaping (NSImage?) -> Void = { _ in },
        @ViewBuilder content: @escaping (NSImage) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.onLoad = onLoad
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let loadedImage {
                content(loadedImage)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            loadedImage = ImageCache.shared.cachedImage(for: url)
            if let loadedImage {
                onLoad(loadedImage)
                return
            }
            let image = await ImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            loadedImage = image
            onLoad(image)
        }
    }
}
