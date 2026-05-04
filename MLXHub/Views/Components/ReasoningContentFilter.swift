import Foundation

enum ReasoningContentFilter {
    private static let tagPairs: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>")
    ]

    static func visibleText(from text: String) -> String? {
        // Fast path: no reasoning tag markers at all.
        guard text.contains("<think") || text.contains("<thinking") else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var sanitized = text

        for tagPair in tagPairs {
            sanitized = removeCompleteTaggedSections(from: sanitized, tagPair: tagPair)

            let nsSanitized = sanitized as NSString
            let openRange = nsSanitized.range(of: tagPair.open)
            if openRange.location != NSNotFound {
                sanitized = nsSanitized.substring(to: openRange.location)
            }

            var searchStart = 0
            while true {
                let nsCurrent = sanitized as NSString
                let closeRange = nsCurrent.range(of: tagPair.close, range: NSRange(location: searchStart, length: nsCurrent.length - searchStart))
                guard closeRange.location != NSNotFound else { break }
                sanitized = nsCurrent.substring(from: closeRange.location + closeRange.length)
                searchStart = 0
            }
        }

        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removeCompleteTaggedSections(
        from text: String,
        tagPair: (open: String, close: String)
    ) -> String {
        var result = text
        var searchStart = 0

        while true {
            let nsResult = result as NSString
            let openRange = nsResult.range(of: tagPair.open, range: NSRange(location: searchStart, length: nsResult.length - searchStart))
            guard openRange.location != NSNotFound else { break }

            let closeSearchStart = openRange.location + openRange.length
            let closeRange = nsResult.range(of: tagPair.close, range: NSRange(location: closeSearchStart, length: nsResult.length - closeSearchStart))
            guard closeRange.location != NSNotFound else {
                searchStart = openRange.location + 1
                continue
            }

            let removalRange = NSRange(location: openRange.location, length: closeRange.location + closeRange.length - openRange.location)
            result = nsResult.replacingCharacters(in: removalRange, with: "")
            searchStart = openRange.location
        }

        return result
    }
}
