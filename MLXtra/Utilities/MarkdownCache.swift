import Foundation
import AppKit

// MARK: - Cache key

struct MarkdownCacheKey: Hashable {
    let rawMarkdown: String
    let appearance: String        // NSApp.effectiveAppearance.name.rawValue
    let fontSize: CGFloat
    let contentScale: CGFloat
    let rendererVersion: Int      // bump when renderer logic changes

    static let currentRendererVersion = 2
}

// MARK: - Cache

/// Caches parsed Markdown blocks and rendered attributed strings.
/// Used by both SwiftUI MarkdownTextView (blocks) and NSTextView-based
/// rendering (attributed strings).
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    private let blockCache = NSCache<NSString, NSArray>()
    private let attributedCache = NSCache<NSString, NSAttributedString>()

    private init() {
        blockCache.countLimit = 40
        attributedCache.countLimit = 20
    }

    // MARK: - Blocks (for SwiftUI MarkdownTextView — old parser path)

    func blocks(for text: String) -> [MarkdownBlock]? {
        let key = cacheKey(for: text)
        return blockCache.object(forKey: key) as? [MarkdownBlock]
    }

    func setBlocks(_ blocks: [MarkdownBlock], for text: String) {
        let key = cacheKey(for: text)
        blockCache.setObject(blocks as NSArray, forKey: key)
    }

    // MARK: - Attributed string (for NSTextView final rendering)

    func attributedString(for text: String, style: MarkdownRenderStyle) -> NSAttributedString? {
        let key = attributedCacheKey(for: text, style: style)
        return attributedCache.object(forKey: key)
    }

    func setAttributedString(_ string: NSAttributedString, for text: String, style: MarkdownRenderStyle) {
        let key = attributedCacheKey(for: text, style: style)
        attributedCache.setObject(string, forKey: key)
    }

    // MARK: - Invalidation

    func invalidateAll() {
        blockCache.removeAllObjects()
        attributedCache.removeAllObjects()
    }

    func invalidateAttributed() {
        attributedCache.removeAllObjects()
    }

    // MARK: - Keys

    private func cacheKey(for text: String) -> NSString {
        // djb2 hash — fast and sufficient for content-based caching.
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return "\(hash).\(MarkdownCacheKey.currentRendererVersion)" as NSString
    }

    private func attributedCacheKey(for text: String, style: MarkdownRenderStyle) -> NSString {
        let appearance = NSApplication.shared.effectiveAppearance.name.rawValue
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let hashBase = "\(text.hashValue).\(appearance).\(style.fontSize).\(scale).\(MarkdownCacheKey.currentRendererVersion)"
        return hashBase as NSString
    }
}
