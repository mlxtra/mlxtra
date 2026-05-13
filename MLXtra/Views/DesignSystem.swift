import AppKit
import SwiftUI

enum MLXtraDesignSystem {
    enum Palette {
        static var windowBackground: Color { Color(NSColor.windowBackgroundColor) }
        static var textBackground: Color { Color(NSColor.textBackgroundColor) }
        static var label: Color { Color(NSColor.labelColor) }
        static var secondaryLabel: Color { Color(NSColor.secondaryLabelColor) }
        static var tertiaryLabel: Color { Color(NSColor.tertiaryLabelColor) }
        static var separator: Color { Color(NSColor.separatorColor) }
        static var accent: Color { Color.accentColor }
        static var success: Color { Color.green }
        static var warning: Color { Color.orange }
        static var danger: Color { Color.red }
    }

    enum Radius {
        static let control: CGFloat = 8
        static let row: CGFloat = 8
        static let card: CGFloat = 10
        static let media: CGFloat = 12
        static let popover: CGFloat = 14
        static let messageBubble: CGFloat = 18
        static let composer: CGFloat = 26
        static let composerField: CGFloat = 20
    }

    enum Spacing {
        static let hairline: CGFloat = 1
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 14
        static let xxxl: CGFloat = 16
        static let section: CGFloat = 20
        static let page: CGFloat = 24
        static let loose: CGFloat = 32
    }

    enum Layout {
        static let composerMaxWidth: CGFloat = 760
        static let composerSurfacePadding: CGFloat = 10
        static let messageMaxWidth: CGFloat = composerMaxWidth - composerSurfacePadding * 2
        static let generatedMediaMaxWidth: CGFloat = 580
        static let chatHorizontalPadding: CGFloat = 24
        static let transcriptHorizontalPadding: CGFloat = chatHorizontalPadding + composerSurfacePadding
        static let transcriptMaxWidth: CGFloat = messageMaxWidth
        static let floatingAccessoryBottomPadding: CGFloat = 14
        static let composerTranscriptGap: CGFloat = 18
        static let composerMinTextHeight: CGFloat = 52
        static let composerMaxTextHeight: CGFloat = 208
        static let composerTextLineHeight: CGFloat = 19
        static let composerTextContainerInset: CGFloat = 10
        static let composerPlaceholderCaretGap: CGFloat = 2
        static let composerMinimumVisibleInputLines = 2
        static let composerMaxVisibleInputLines = 8
        static let musicLyricsTextHeight: CGFloat = 86
        static let compactSidebarBreakpoint: CGFloat = 900
        static let sidebarMinWidth: CGFloat = 184
        static let sidebarCompactIdealWidth: CGFloat = 210
        static let sidebarCompactMaxWidth: CGFloat = 228
        static let sidebarIdealWidth: CGFloat = 250
        static let sidebarMaxWidth: CGFloat = 280
    }

    enum Typography {
        static let toolbarTitle = Font.system(size: 15, weight: .semibold)
        static let welcomeDisplay = Font.system(size: 34, weight: .regular)
        static let welcomeSecondary = Font.system(size: 30, weight: .regular)
        static let composerPlaceholder = Font.system(size: 14)
        static let title = Font.system(size: 18, weight: .semibold)
        static let sectionTitle = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13)
        static let messageBody = Font.system(size: 14)
        static let messageBodyStrong = Font.system(size: 14, weight: .semibold)
        static let compactBody = Font.system(size: 13)
        static let compactBodyMedium = Font.system(size: 13, weight: .medium)
        static let compactBodySemibold = Font.system(size: 13, weight: .semibold)
        static let rowTitle = Font.system(size: 13, weight: .medium)
        static let rowPreview = Font.system(size: 11)
        static let caption = Font.system(size: 11)
        static let captionMedium = Font.system(size: 11, weight: .medium)
        static let micro = Font.system(size: 10)
        static let microMedium = Font.system(size: 10, weight: .medium)
        static let code = Font.system(size: 13, design: .monospaced)
        static let codeCaption = Font.system(size: 11, weight: .medium, design: .monospaced)

        static func nativeSearchFieldFont() -> NSFont {
            NSFont.systemFont(ofSize: 13)
        }

        static func nativeComposerInputFont() -> NSFont {
            NSFont.systemFont(ofSize: 14)
        }

        static func markdownHeading(level: Int) -> Font {
            Font.system(size: markdownHeadingSize(level: level), weight: .semibold)
        }

        static func markdownHeadingSize(level: Int) -> CGFloat {
            switch level {
            case 1: return 20
            case 2: return 17
            case 3: return 15
            default: return 14
            }
        }
    }

    enum Icon {
        static let micro: CGFloat = 10
        static let small: CGFloat = 12
        static let regular: CGFloat = 13
        static let medium: CGFloat = 14
        static let large: CGFloat = 16
        static let hero: CGFloat = 24

        static let sidebarRowFrame: CGFloat = 20
        static let avatar: CGFloat = 28
        static let composerButton: CGFloat = 32
        static let toolbarButton: CGFloat = 30
        static let mediaPrimaryButton: CGFloat = 40
        static let mediaActionButton: CGFloat = 32
    }

    enum TextLimit {
        static let generatedTitle = 30
        static let windowTitle = 80
        static let renameTitle = 80
        static let sidebarPreview = 90
    }

    enum Motion {
        static let hoverDuration: TimeInterval = 0.12
        static let focusDuration: TimeInterval = 0.18
        static let controlDuration: TimeInterval = 0.14
    }

    enum Elevation {
        static let floatingShadowOpacity: Double = 0.055
        static let floatingShadowRadius: CGFloat = 12
        static let floatingShadowY: CGFloat = 4
        static let popoverShadowOpacity: Double = 0.08
        static let popoverShadowRadius: CGFloat = 16
        static let popoverShadowY: CGFloat = 4
    }

    enum Surface {
        static var hairline: Color {
            Palette.separator.opacity(0.22)
        }

        static var quietHairline: Color {
            Palette.separator.opacity(0.14)
        }

        static var focusHairline: Color {
            Palette.accent.opacity(0.12)
        }

        static var hoverFill: Color {
            Color.primary.opacity(0.045)
        }

        static func controlFill(colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.white.opacity(0.055)
                : Color(NSColor.controlBackgroundColor).opacity(0.72)
        }

        static func fieldFill(colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.white.opacity(0.07)
                : Color(NSColor.textBackgroundColor).opacity(0.94)
        }

        static var panelFill: Color {
            Color(NSColor.controlBackgroundColor).opacity(0.72)
        }

        static var contentFill: Color {
            Color(NSColor.textBackgroundColor).opacity(0.78)
        }

        static var selectedSidebarFill: Color {
            Color.primary.opacity(0.055)
        }

        static func tintFill(_ tint: Color) -> Color {
            tint.opacity(0.10)
        }
    }
}

extension View {
    @ViewBuilder
    func nativeGlassSurface(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self.background(
            .regularMaterial,
            in: shape
        )
    }

    func designPanelSurface(cornerRadius: CGFloat = MLXtraDesignSystem.Radius.card) -> some View {
        self
            .background(MLXtraDesignSystem.Surface.panelFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
            }
    }

    func designContentSurface(cornerRadius: CGFloat = MLXtraDesignSystem.Radius.card) -> some View {
        self
            .background(MLXtraDesignSystem.Surface.contentFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MLXtraDesignSystem.Surface.quietHairline, lineWidth: 1)
            }
    }

    func designTintSurface(
        _ tint: Color,
        cornerRadius: CGFloat = MLXtraDesignSystem.Radius.control
    ) -> some View {
        self
            .background(MLXtraDesignSystem.Surface.tintFill(tint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
    }

    func designHairline(cornerRadius: CGFloat) -> some View {
        self.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(MLXtraDesignSystem.Surface.hairline, lineWidth: 1)
        }
    }
}

struct NativeSearchField: NSViewRepresentable {
    var placeholder: String = "Search"
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.font = MLXtraDesignSystem.Typography.nativeSearchFieldFont()
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct ClickableDisclosureSection<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    private let content: () -> Content
    private let label: () -> Label

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self._isExpanded = isExpanded
        self.content = content
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10, height: 12)

                    label()

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content()
            }
        }
    }
}
