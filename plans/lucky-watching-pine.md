# Fix: Newlines Lost During VLM Streaming Rendering

## Context

During VLM streaming, newlines between paragraphs are not rendered. However, once streaming completes and the final render runs, newlines appear correctly. The bug is in the **streaming rendering path**, specifically in how `FastStreamingTextNativeView` appends newly stable blocks to the NSTextStorage.

## Root Cause

In `MessageBubbleView.swift:1338-1385`, `applySplitterBasedUpdate` renders newly stable blocks via `MarkdownAttributedRenderer.attributedString(from: result.newBlocks, style:)` and appends them to the NSTextStorage. The block renderer at `MarkdownAttributedRenderer.swift:55-67` only adds `\n` separators **between blocks within the same array**. During streaming, blocks are committed one batch at a time, so each batch is a separate `storage.append()` call — no separator is ever inserted between consecutive stable blocks from different batches.

**Example trace** for text `Line 1\n\nLine 2\n\nLine 3`:

1. Tokens arrive for `Line 1\n\n` → splitter commits `[.paragraph("Line 1")]` as stable. Storage = `"Line 1"`.
2. Token `Line 2` arrives (text = `Line 1\n\nLine 2`) → nothing new is stable yet. Tail = `"Line 2"`. Storage = `"Line 1Line 2"` (**no newline**).
3. Token `\n\n` arrives → splitter commits `[.paragraph("Line 2")]` as new stable. Old tail `"Line 2"` removed, new block `"Line 2"` appended. Storage = `"Line 1Line 2"` (**still no newline**).

After streaming completes, `finalizeMessage` re-renders the full text from scratch, which includes all `\n\n` separators. Hence the "final render renders correctly" observation.

## Fix

**File:** `MLXtra/Views/MessageBubbleView.swift`
**Method:** `applySplitterBasedUpdate` (line ~1338)
**Location around line 1358**

When appending newly stable blocks to the NSTextStorage, if the storage already has existing content (previous stable blocks), prepend a `"\n"` separator before the new blocks' attributed string:

```swift
// 2. Append newly stable blocks
if !result.newBlocks.isEmpty {
    let blockAttr = MarkdownAttributedRenderer.attributedString(
        from: result.newBlocks,
        style: renderStyle
    )
    // Insert paragraph separator between previous stable blocks and new ones
    if storage.length > 0 {
        storage.append(NSAttributedString(string: "\n"))
    }
    storage.append(blockAttr)
}
```

This mirrors what `MarkdownAttributedRenderer.attributedString(from: [MarkdownBlock], style:)` does internally (line 60-62) when it has multiple blocks in a single array — inserting `\n` between blocks.

## Verification

1. Run the app with a VLM model
2. Send a prompt that produces multi-paragraph output (e.g., "Write a poem with three stanzas" or "List three items with descriptions")
3. Observe that during streaming, paragraph breaks (blank lines) are visible
4. Confirm the final render looks identical to the streaming render (no visual jump on completion)
5. Run existing tests: `StreamingMarkdownSplitterTests`, `MarkdownRenderingTests`, `BridgeProtocolSequenceTests`
