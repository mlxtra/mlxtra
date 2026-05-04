# Fix Multi-Line Text Selection in Streaming Markdown View

## Context

The streaming markdown text view (`FastStreamingTextNativeView`) only allows selecting the current line. Dragging the mouse across multiple lines doesn't extend the selection. This is because `NSTextView` is added directly as a subview of a bare `NSView`, bypassing AppKit's expected `NSScrollView → NSClipView → NSTextView` hierarchy. `NSTextView`'s internal mouse-drag selection tracking relies on `enclosingScrollView`/`enclosingClipView` for coordinate transforms when extending selection across line boundaries.

Additionally, `isRichText = false` strips all font/color/paragraph attributes from the rich `NSAttributedString` values produced by `MarkdownAttributedRenderer`, degrading the markdown rendering.

## Fix

Three changes in `FastStreamingTextNativeView` (`MLXHub/Views/MessageBubbleView.swift`):

### Change 1: Add `scrollView` property (after `textView` declaration, ~line 1230)

```swift
private let scrollView = NSScrollView()
```

Declared after `textView` so `textView` initializes first (Swift stored property init order is top-to-bottom). `configureTextView()` (called from `init`) will set it as the document view.

### Change 2: Modify `configureTextView()` (~line 1423)

- Change `textView.isRichText = false` → `true` so rich attributed strings render correctly
- Remove `textView.autoresizingMask = [.width]` — when textView is a documentView of NSScrollView, the scroll view manages sizing via `isVerticallyResizable`/`isHorizontallyResizable`
- Configure `scrollView`: no background, no scrollers, no border, no content insets
- Set `scrollView.documentView = textView` (this internally handles view hierarchy)
- Replace `addSubview(textView)` with `addSubview(scrollView)`

### Change 3: Modify `layout()` (~line 1268)

Replace `textView.frame = bounds` with `scrollView.frame = bounds`.

## What does NOT change

- `textView.textStorage` — all direct mutations to text storage continue to work identically
- `refreshMeasuredHeight` — uses `textView.layoutManager` directly, valid through scroll view
- `configureContainer(width:)` — sets text container size, still works inside scroll view
- `intrinsicContentSize` — still based on `cachedHeight` from layout manager
- `scrollEnclosingViewToBottom()` — walks UP to parent SwiftUI scroll view, inner scroll view doesn't interfere
- `applySplitterBasedUpdate` — all `NSTextStorage` operations unchanged

## Height management remains correct

The NSScrollView fills the outer NSView bounds. Since the outer view's height grows via `intrinsicContentSize` (driven by `cachedHeight`), the scroll view's content area always matches or exceeds the text content height. With `hasVerticalScroller = false` and `isVerticallyResizable = true` on the textView, no internal scrolling occurs — the view simply grows.

## Verification

1. Build: `xcodebuild -project MLXHub.xcodeproj -scheme MLXHub -destination 'platform=macOS' build`
2. Run the app and send a message that produces multi-line markdown output
3. Click and drag across multiple lines — selection should extend across lines
4. Verify text selection includes proper highlighting for headings, code blocks, bold/italic
5. Verify streaming content still grows the view height correctly (no internal scrollbar)
6. Verify copy (Cmd+C) works on multi-line selections
