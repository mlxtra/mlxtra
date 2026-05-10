# MLXHub Design System

MLXHub is a native macOS productivity app for local AI work. The interface should feel quiet, precise, and durable: standard macOS structure first, custom surfaces only where chat, media, or model workflows need them.

This document is the implementation contract for visual and interaction work. Shared tokens live in `MLXHub/Views/DesignSystem.swift`; new UI should use those tokens before adding local constants.

## References

- Apple Human Interface Guidelines: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- Apple Human Interface Guidelines: [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- Apple Human Interface Guidelines: [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- Apple Human Interface Guidelines: [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)
- Apple Developer Documentation: [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- Apple Developer Documentation: [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)

## Principles

1. Native structure beats custom chrome.
   Use `NavigationSplitView`, standard toolbar placements, menus, popovers, native search fields, segmented pickers, and system buttons before custom drawing.

2. Glass clarifies hierarchy.
   Use `nativeGlassSurface` for the floating composer and related floating controls. Do not stack multiple translucent cards inside each other just for decoration.

3. Tint is a signal, not a theme.
   Accent color is for primary action, selected intent, user bubbles, and focused controls. Status colors are semantic only; ready state stays neutral unless the user needs to act.

4. Content owns attention.
   User messages are compact accent bubbles. Assistant responses are readable text/Markdown. Tool, media, and model controls are supporting surfaces.

5. Every small detail must line up.
   Icons, text baselines, row insets, hit targets, border opacity, and truncation behavior are part of the design system, not cleanup work.

## Foundations

### Typography

Use San Francisco through system fonts. Do not add custom fonts. Do not use negative letter spacing. Prefer weight and hierarchy over size jumps. The app uses a small type scale: 34 display, 30 welcome secondary, 18 title, 15 toolbar, 14 composer/transcript, 13 UI body, 11 caption, 10 micro.

| Role | Token | Size / Weight | Use |
| --- | --- | --- | --- |
| Welcome display | `Typography.welcomeDisplay` | 34 regular | Empty-state greeting only |
| Welcome secondary | `Typography.welcomeSecondary` | 30 regular | Empty-state prompt under the greeting |
| Toolbar title | `Typography.toolbarTitle` | 15 semibold | Window/content title surfaces |
| Composer input | `Typography.nativeComposerInputFont()` | 14 regular | Main prompt entry |
| Title | `Typography.title` | 18 semibold | Panel titles and major local headings |
| Section title | `Typography.sectionTitle` | 15 semibold | Settings/model group titles |
| Body | `Typography.body` | 13 regular | General UI copy |
| Message body | `Typography.messageBody` | 14 regular | Chat transcript text and Markdown paragraphs |
| Message strong | `Typography.messageBodyStrong` | 14 semibold | Markdown emphasis/headings below H3 |
| Compact body | `Typography.compactBody` | 13 regular | Buttons, controls, popovers |
| Compact medium | `Typography.compactBodyMedium` | 13 medium | Sidebar/control labels |
| Row title | `Typography.rowTitle` | 13 medium | Sidebar chat title |
| Row preview | `Typography.rowPreview` | 11 regular | Sidebar previews |
| Caption | `Typography.caption` | 11 regular | Metadata and helper text |
| Micro | `Typography.micro` | 10 regular | Timestamps, badges, dense metrics |
| Code | `Typography.code` | 13 monospaced | Markdown code blocks |
| Code caption | `Typography.codeCaption` | 11 monospaced medium | Code labels, table metadata |

Markdown headings use `Typography.markdownHeading(level:)`: H1 20 semibold, H2 17 semibold, H3 15 semibold, lower headings 14 semibold. Markdown is rendered inside chat, not as a document page, so headings must remain proportional to transcript text.

### Color

Use semantic system colors and dynamic materials. Avoid fixed hex colors unless introducing a brand asset.

| Role | Token | Rule |
| --- | --- | --- |
| Window background | `Palette.windowBackground` | Main content background |
| Field background | `Palette.textBackground` / `Surface.fieldFill` | Composer and text-entry fields |
| Primary text | `Palette.label` or `.primary` | Main readable text |
| Secondary text | `Palette.secondaryLabel` or `.secondary` | Metadata, previews |
| Tertiary text | `Palette.tertiaryLabel` or `.tertiary` | Placeholder and low-priority metrics |
| Separator | `Palette.separator` | Hairline borders only |
| Accent | `Palette.accent` / `Color.accentColor` | Primary action, selected intent, user messages |
| Success | `Palette.success` | Rare inline confirmations only; model ready/status chrome should be neutral |
| Warning | `Palette.warning` | Paused/warning/runtime attention |
| Danger | `Palette.danger` | Delete/failure/destructive |

Surface border tokens:

- `Surface.hairline`: normal visible border, separator at 22% opacity.
- `Surface.quietHairline`: low-emphasis border, separator at 14% opacity.
- `Surface.focusHairline`: focused control border, accent at 12% opacity.
- `Surface.hoverFill`: row/popover hover fill, primary at 4.5% opacity.
- `Surface.controlFill(colorScheme:)`: compact control fill.
- `Surface.fieldFill(colorScheme:)`: text-entry fill.
- `Surface.panelFill`: quiet grouped container fill.
- `Surface.contentFill`: inner content/media fill.
- `Surface.selectedSidebarFill`: selected row fill when custom row composition is required.
- `Surface.tintFill(_:)`: selected/status fill at 10% opacity.

### Spacing

Use the spacing scale instead of one-off values.

| Token | Value | Use |
| --- | ---: | --- |
| `Spacing.hairline` | 1 | Borders, 1 pt row inset |
| `Spacing.xxs` | 2 | Tight text/icon gaps |
| `Spacing.xs` | 4 | Tiny vertical offsets |
| `Spacing.sm` | 6 | Compact control gaps |
| `Spacing.md` | 8 | Standard row/control gap |
| `Spacing.lg` | 10 | Composer/content padding |
| `Spacing.xl` | 12 | Message and popover padding |
| `Spacing.xxl` | 14 | Field horizontal padding |
| `Spacing.xxxl` | 16 | Section internal padding |
| `Spacing.section` | 20 | Panel sections |
| `Spacing.page` | 24 | Chat page padding |
| `Spacing.loose` | 32 | Large empty-state spacing |

### Radius

Use continuous corners.

| Token | Value | Use |
| --- | ---: | --- |
| `Radius.control` | 8 | Buttons, badges, code blocks |
| `Radius.row` | 8 | Sidebar rows and hover fills |
| `Radius.card` | 10 | Small panels and media controls |
| `Radius.media` | 12 | Generated media and typing surfaces |
| `Radius.popover` | 14 | Popover panels |
| `Radius.messageBubble` | 18 | User bubbles |
| `Radius.composerField` | 20 | Composer text field |
| `Radius.composer` | 26 | Floating composer container |

### Iconography

Use SF Symbols. Icon-only controls need `.help(...)` and accessibility labels when the symbol is not self-evident.

| Token | Value | Use |
| --- | ---: | --- |
| `Icon.micro` | 10 | Chevron, tiny badges |
| `Icon.small` | 12 | Badge/action symbols |
| `Icon.regular` | 13 | Sidebar rows, prompt chips |
| `Icon.medium` | 14 | Avatars, tool rows |
| `Icon.large` | 16 | Composer plus |
| `Icon.hero` | 24 | Empty media placeholder |
| `Icon.sidebarRowFrame` | 20 | Sidebar icon frame |
| `Icon.avatar` | 28 | Row action hit visual |
| `Icon.composerButton` | 32 | Composer circular controls |
| `Icon.toolbarButton` | 30 | Compact toolbar icon buttons |
| `Icon.mediaPrimaryButton` | 40 | Generated audio play/pause |
| `Icon.mediaActionButton` | 32 | Generated media reveal/download |

Icon alignment rules:

- Sidebar icons use a fixed 20 pt frame and align to the first text line visually.
- Composer add/send/stop buttons are circular, 32 pt, and sit on the same baseline as the tool selector.
- Toolbar icons use standard toolbar/menu button styles when possible.

### Elevation And Motion

Elevation is functional: only floating accessories and popovers cast shadows.

| Token | Value | Use |
| --- | --- | --- |
| `Elevation.floatingShadowOpacity` | 0.055 | Floating composer |
| `Elevation.floatingShadowRadius` | 12 | Floating composer |
| `Elevation.floatingShadowY` | 4 | Floating composer |
| `Elevation.popoverShadowOpacity` | 0.08 | Custom popovers |
| `Elevation.popoverShadowRadius` | 16 | Custom popovers |
| `Elevation.popoverShadowY` | 4 | Custom popovers |

Motion:

- `Motion.hoverDuration`: 0.12s.
- `Motion.controlDuration`: 0.14s.
- `Motion.focusDuration`: 0.18s.
- Avoid decorative animations. Use motion for hover, focus, streaming, loading, and generation state only.

## Layout Tokens

| Token | Value | Rule |
| --- | ---: | --- |
| `Layout.transcriptMaxWidth` | 740 | Centered transcript rail; matches the visible composer input box |
| `Layout.messageMaxWidth` | 740 | Max user/assistant message content width; derived from composer width minus surface padding |
| `Layout.generatedMediaMaxWidth` | 580 | Generated media card width |
| `Layout.composerMaxWidth` | 760 | Floating composer width |
| `Layout.composerSurfacePadding` | 10 | Inset between the outer glass composer and the visible text field |
| `Layout.chatHorizontalPadding` | 24 | Composer/transcript side padding and transcript top padding |
| `Layout.transcriptHorizontalPadding` | 34 | Transcript side padding; equals outer chat padding plus composer surface padding |
| `Layout.floatingAccessoryBottomPadding` | 14 | Composer bottom inset |
| `Layout.defaultTranscriptBottomSpacer` | 92 | Default scroll spacer below messages |
| `Layout.composerTranscriptGap` | 18 | Gap between transcript and composer |
| `Layout.composerMinTextHeight` | 52 | Empty/default composer field height |
| `Layout.composerMaxTextHeight` | 208 | Expanded input cap |
| `Layout.composerTextLineHeight` | 19 | Input height line step |
| `Layout.composerTextContainerInset` | 10 | Native text-view vertical inset |
| `Layout.composerPlaceholderCaretGap` | 2 | Focused placeholder breathing room beside the insertion point |
| `Layout.composerMinimumVisibleInputLines` | 2 | Input stays at default height through two logical lines |
| `Layout.composerMaxVisibleInputLines` | 8 | Input expands up to 8 logical lines, then scrolls |
| `Layout.compactSidebarBreakpoint` | 900 | Window width where sidebar switches to compact metrics |
| `Layout.sidebarMinWidth` | 184 | Sidebar minimum width |
| `Layout.sidebarCompactIdealWidth` | 210 | Compact-window sidebar ideal width |
| `Layout.sidebarCompactMaxWidth` | 228 | Compact-window sidebar maximum width |
| `Layout.sidebarIdealWidth` | 250 | Sidebar ideal width |
| `Layout.sidebarMaxWidth` | 280 | Sidebar maximum width |

Text limits:

- `TextLimit.generatedTitle`: 30 characters, word-safe truncation.
- `TextLimit.windowTitle`: 80 characters, word-safe truncation.
- `TextLimit.renameTitle`: 80 characters, word-safe truncation.
- `TextLimit.sidebarPreview`: 90 characters, word-safe truncation.
- Multi-line prompts must collapse to single-line display text before title/sidebar/window use.

## Components

### Window And Toolbar

- Use `NavigationSplitView` for sidebar/detail.
- The toolbar title is the selected chat title or fallback, normalized through `ChatDisplayText.singleLine`.
- Leading toolbar: New Chat with `square.and.pencil`, `Command-N`.
- Trailing toolbar: model parameters, model selector, local engine status, Settings.
- Do not add a fake chat title row inside the transcript.
- Toolbar controls must remain compact and avoid long labels.

### Sidebar

- Use `.listStyle(.sidebar)` and `.searchable(..., placement: .sidebar)`.
- Custom row selection uses `Surface.selectedSidebarFill` as the only selected surface. Do not paint a second selected rectangle inside the row.
- Row anatomy: 20 pt icon in a tight leading gutter; title owns the first line; preview and timestamp share the second line. Rows should read as a dense native sidebar list, not as padded cards.
- Row title uses `Typography.rowTitle`; preview uses `Typography.rowPreview`; timestamp uses `Typography.micro`.
- Hover state uses `Surface.hoverFill`; destructive confirmation uses a red circular confirmation button.
- Sidebar titles and previews are always single line with tail truncation.

### Transcript

- Transcript column is centered and capped by `Layout.transcriptMaxWidth`; assistant content aligns to the visible composer input box, not the text inset inside it.
- User messages align right and use `Palette.accent` with white text.
- Assistant responses align left and use plain readable text without a persistent assistant avatar in regular chat turns.
- Assistant metrics, hover timestamp, and copy action share a single tertiary metadata row. Do not add a persistent blank copy row below the message.
- Long messages must scroll behind the bottom spacer without colliding with the composer.

### Composer

- Composer is a bottom floating accessory with `nativeGlassSurface(cornerRadius: Radius.composer, interactive: true)`.
- Composer shadow uses `Elevation.floating*` tokens.
- Inner text field uses `Surface.fieldFill`, `Radius.composerField`, and `Surface.focusHairline`.
- Text input expands from `Layout.composerMinTextHeight` to `Layout.composerMaxTextHeight`, up to 8 explicit lines, then scrolls internally.
- A single-line draft must keep the default composer height even if it wraps visually. Height growth starts only when the draft contains explicit line breaks.
- Tool selector sits below the text area next to the add button, not beside the transcript.
- Primary send/stop action is a 32 pt circular control on the trailing side.
- The send button is the only filled accent control in the composer.
- Avoid neon borders, gradient borders, or thick focus rings.
- Music vocal controls are compact composer accessories below the main prompt. Do not turn the composer into a form: show the lyrics editor only when vocals are explicitly selected, lyrics exist, or generation needs lyrics, and keep its action inside a small lyrics header.

### Generated Media

- Image, speech, and music outputs use the same generated-media card language: `Radius.media`, `designContentSurface`, 13 pt title, 11 pt filename, and 32 pt icon-only reveal/download controls.
- Audio/music cards use a 40 pt accent play button and a quiet waveform scrubber.
- Media cards stay inside `Layout.generatedMediaMaxWidth` and must clear the floating composer in screenshots.
- Generated outputs should feel like transcript content, not settings panels.

### Welcome

- Welcome screen is an operational start surface, not a landing page.
- Greeting uses `Typography.welcomeDisplay`; no other hero-scale text should appear inside controls or cards.
- Prompt chips are command surfaces, not passive labels: use compact semibold typography, SF Symbols, a visible resting fill/border, accent-tinted hover/press feedback, and one-line labels.
- The composer remains visible as the primary action target.

### Popovers And Menus

- Prefer system `Menu`, `Picker`, and `.popover` behavior.
- Custom popovers use `Radius.popover`, `designPanelSurface`, and `Elevation.popover*`.
- Tool/model rows use icon, label, subtitle, readiness badge, and checkmark.
- Selected row fill is `Surface.tintFill(Palette.accent)`, not a saturated block.

### Media And Tool Results

- Generated media and audio controls use `designPanelSurface` or `designTintSurface`.
- The actual media preview carries visual interest; cards should not add gradients.
- Code blocks use `Typography.code`, `Palette.textBackground`, `Radius.control`, and a quiet hairline.
- Missing media states use secondary text and an SF Symbol placeholder.

### Settings

- Settings is a dense operational surface.
- Model search uses `NativeSearchField`.
- Model rows should be scannable: name, purpose, fit/status badges, primary action.
- Technical details belong in disclosure sections.
- Ready and recommendation badges are neutral. Use blue for selected defaults and primary actions only.
- Paused/downloading rows use one clear primary action plus compact icon-only secondary actions for pause/cancel.
- Do not turn Settings into a marketing page or add large hero sections.

## States

| State | Treatment |
| --- | --- |
| Hover | `Surface.hoverFill`; 0.12s ease in/out |
| Focus | `Surface.focusHairline`; no glow unless native system focus ring appears |
| Selected | Native list selection or `Surface.tintFill(Palette.accent)` for custom popover rows |
| Disabled | Secondary/tertiary text, low-contrast fill, no shadow |
| Loading/streaming | Subtle progress text or dots; no decorative looping animations |
| Ready/success | Neutral secondary text with icon + concise label; reserve `Palette.success` for rare confirmations |
| Warning/paused | `Palette.warning` with icon + concise label |
| Error/destructive | `Palette.danger`; destructive action requires clear confirmation |

## Accessibility

- Use native controls where possible for keyboard, focus, and VoiceOver behavior.
- Icon-only buttons require `.help(...)`; add explicit accessibility labels for ambiguous controls.
- Minimum practical hit target is 28 pt; primary composer controls are 32 pt.
- Text must not overlap controls at narrow widths.
- Dynamic system colors must remain readable in light, dark, and Increased Contrast.
- Do not rely on color alone for status: pair color with an icon and short label.

## Screenshot Review Checklist

Run UI tests and inspect the newest timestamped folders under `MLXHubChatLayoutScreenshots` and `MLXHubDownloadStateScreenshots`. Do not compare against mixed screenshots from older runs.

Check every screenshot for:

- Sidebar selection: native selected row, no nested selected card, no clipped title/preview.
- Sidebar icon placement: icon frame aligns with the title/preview block and does not drift low.
- Toolbar: title is single line, commands are compact, status/model/settings do not crowd.
- Transcript: user bubble is right aligned, assistant content is left aligned, metrics are tertiary.
- Composer: container, text field, plus/tool/send controls share one visual language.
- Composer focus: border is calm, not neon; text field fill is not a separate white slab.
- Long input: field expands up to the cap, scrolls internally, and does not cover messages.
- Long sent prompt: toolbar/sidebar/title collapse to single-line display text.
- Markdown: rendered Markdown does not expose raw fences and uses message typography.
- Empty state: greeting scale is reserved for the page, not reused in chips/cards.
- Model states: ready/recommended are neutral, warning/error states are semantic, and pause/cancel controls are not clipped text.
- Dark mode and Increased Contrast: borders remain visible but not heavy.

## Adoption Rules

- New UI must use `MLXHubDesignSystem` tokens for typography, color, spacing, radius, icon sizes, text limits, motion, and elevation.
- A new local constant is acceptable only when it is truly component-specific; promote it to the design system if reused twice.
- Avoid broad refactors when adopting tokens. Convert the touched component and leave unrelated behavior intact.
- Visual changes require a fresh UI screenshot run and direct screenshot inspection.
