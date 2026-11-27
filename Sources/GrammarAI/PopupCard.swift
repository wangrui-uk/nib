import SwiftUI

/// The one look shared by the live-checking popup and the suggestion panel:
/// a compact card with a coloured left border, the change in the same diff colours,
/// a small caption line, and a row of buttons with keycaps.
enum PopupStyle {
    /// The chosen text size; everything else scales from it (13 pt = 1.0).
    static var size: CGFloat { CGFloat(Settings.shared.popupFontSize) }
    static var scale: CGFloat { size / 13 }

    /// The chosen font at a size, falling back to the system font if the family isn't installed.
    static func font(_ pt: CGFloat, weight: Font.Weight = .regular) -> Font {
        let family = Settings.shared.popupFont
        if family.isEmpty { return .system(size: pt, weight: weight) }
        if family == "__mono__" { return .system(size: pt, weight: weight, design: .monospaced) }
        guard NSFont(name: family, size: pt) != nil || NSFontManager.shared.availableMembers(ofFontFamily: family) != nil else {
            return .system(size: pt, weight: weight)
        }
        return .custom(family, size: pt).weight(weight)
    }

    /// The chosen font's real italic face, or nil if it has none (many fonts, e.g. YuGothic, don't,
    /// and SwiftUI won't synthesise one): then callers slant the view instead (`SlantIfNeeded`).
    static func italicFont(_ pt: CGFloat) -> Font? {
        let family = Settings.shared.popupFont
        if family.isEmpty { return .system(size: pt).italic() }
        if family == "__mono__" { return .system(size: pt, design: .monospaced).italic() }
        guard let base = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: pt) ?? NSFont(name: family, size: pt)
        else { return nil }
        let converted = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        return converted.fontDescriptor.symbolicTraits.contains(.italic) ? Font(converted as CTFont) : nil
    }

    static var textFont: Font { font(size) }
    static var captionFont: Font { font(size * 11 / 13) }
    static var cornerRadius: CGFloat { 9 * min(scale, 1.3) }
    /// Width at which long diffs wrap.
    static var wrapWidth: CGFloat { 380 * scale }

    static func color(for kind: String) -> Color {
        kind == "spelling" ? .red : kind == "grammar" ? .orange : kind == "wording" ? .secondary : .accentColor
    }

    /// What's taken out: grey with a red strike.
    static func removed(_ s: String) -> Text {
        Text(s).strikethrough(true, color: .red).foregroundColor(.secondary)
    }

    /// What goes in: bold, normal text colour.
    static func added(_ s: String) -> Text {
        Text(s).fontWeight(.semibold).foregroundColor(.primary)
    }

    static func caption(_ s: String) -> some View {
        Text(s).font(captionFont).foregroundColor(.secondary)
    }
}

struct PopupCard<Content: View>: View {
    var accent: Color
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 6 * PopupStyle.scale) { content() }
                .padding(.horizontal, 10 * PopupStyle.scale).padding(.vertical, 8 * PopupStyle.scale)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: PopupStyle.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PopupStyle.cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .padding(10)
    }
}

/// A small macOS-style keycap shown on the right of a button.
struct Keycap: View {
    let glyph: String
    var onAccent = false
    var tinted = false
    var body: some View {
        Text(glyph)
            .font(.system(size: 10 * PopupStyle.scale, weight: .medium, design: .rounded))
            .foregroundColor(onAccent ? .white.opacity(0.9) : tinted ? Color(nsColor: .controlAccentColor) : .secondary)
            .padding(.horizontal, 4 * PopupStyle.scale).frame(minWidth: 16 * PopupStyle.scale, minHeight: 14 * PopupStyle.scale)
            .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(onAccent ? Color.white.opacity(0.2) : tinted ? Color(nsColor: .controlAccentColor).opacity(0.15) : Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .stroke(onAccent ? Color.white.opacity(0.35) : tinted ? Color(nsColor: .controlAccentColor).opacity(0.45) : Color.primary.opacity(0.18), lineWidth: 0.5))
    }
}

/// Buttons that look the same whether or not the panel is key (the popups never are, so they can't
/// take focus from the user's field; system button styles would draw them as inactive).
struct PopupButtonStyle: ButtonStyle {
    var prominent = false
    /// A positive secondary action (Apply All): accent-tinted, between the solid primary and the grey neutral.
    var tinted = false
    func makeBody(configuration: Configuration) -> some View {
        PopupButtonBody(configuration: configuration, prominent: prominent, tinted: tinted)
    }
}

private struct PopupButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    var tinted = false
    @Environment(\.isEnabled) private var enabled
    private var accent: Color { Color(nsColor: .controlAccentColor) }
    var body: some View {
        configuration.label
            .font(PopupStyle.font(12 * PopupStyle.scale, weight: prominent || tinted ? .semibold : .regular))
            .foregroundColor(prominent ? .white : tinted ? accent : .primary)
            .padding(.leading, 9 * PopupStyle.scale).padding(.trailing, 5 * PopupStyle.scale).padding(.vertical, 3 * PopupStyle.scale)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(prominent ? accent : tinted ? accent.opacity(0.17) : Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(prominent ? Color.clear : tinted ? accent.opacity(0.35) : Color.primary.opacity(0.14), lineWidth: 0.5))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

struct KeyLabel: View {
    let title: String
    let glyph: String
    var onAccent = false
    var tinted = false
    var body: some View {
        HStack(spacing: 6 * PopupStyle.scale) { Text(title); Keycap(glyph: glyph, onAccent: onAccent, tinted: tinted) }
    }
}

/// Slants a view like italic type, for fonts without an italic face.
struct SlantIfNeeded: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.2, d: 1, tx: 3, ty: 0))
        } else {
            content
        }
    }
}
