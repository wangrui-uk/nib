import AppKit
import SwiftUI

/// Where floating cards go: every card (live popup, suggestion, rewrite card, ✨ chip, HUD) is kept fully on the
/// screen that holds its anchor, 8 pt inside the visible frame (below the menu bar, beside the Dock).
enum CardPlacement {
    static let margin: CGFloat = 8

    /// The screen containing the point, else the nearest one.
    static func screen(for p: NSPoint) -> NSScreen {
        if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) { return s }
        func distance(_ f: NSRect) -> CGFloat {
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            return dx * dx + dy * dy
        }
        return NSScreen.screens.min { distance($0.frame) < distance($1.frame) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Moves a panel frame so its card (the frame minus `padding` of transparent margin) lies within `visible`
    /// inset by the margin: shifted left/right/up/down as needed, never off-screen. A card larger than the area
    /// keeps its top-left corner on screen. Pure, for self-tests.
    static func clamp(_ frame: NSRect, padding: CGFloat = 0, in visible: NSRect) -> NSRect {
        let area = visible.insetBy(dx: margin, dy: margin)
        var card = frame.insetBy(dx: padding, dy: padding)
        if card.maxX > area.maxX { card.origin.x = area.maxX - card.width }
        if card.minX < area.minX { card.origin.x = area.minX }
        if card.minY < area.minY { card.origin.y = area.minY }
        if card.maxY > area.maxY { card.origin.y = area.maxY - card.height }
        return card.insetBy(dx: -padding, dy: -padding)
    }

    /// `clamp` on the screen holding the anchor point.
    static func clamp(_ frame: NSRect, padding: CGFloat = 0, anchor: NSPoint) -> NSRect {
        clamp(frame, padding: padding, in: screen(for: anchor).visibleFrame)
    }
}

/// A change shown in place: word diff, refined to characters where only punctuation (or an added/removed
/// ending) changed, so a lone "?" or "," stands out. Long unchanged stretches are shortened to "…".
enum InlineDiff {
    enum Seg: Equatable { case same(String), removed(String), added(String) }

    static func segments(_ a: String, _ b: String) -> [Seg] {
        let pieces = WordDiff.diff(a, b)
        var out: [Seg] = []
        func push(_ s: Seg) {
            switch (out.last, s) {
            case (.same(let x)?, .same(let y)): out[out.count - 1] = .same(x + y)
            case (_, .same(let y)) where y.isEmpty, (_, .removed(let y)) where y.isEmpty, (_, .added(let y)) where y.isEmpty: break
            default: out.append(s)
            }
        }
        var i = 0
        while i < pieces.count {
            switch pieces[i] {
            case .same(let s): push(.same(s))
            case .removed(let x):
                if i + 1 < pieces.count, case .added(let y) = pieces[i + 1] {
                    for s in refine(x, y) { push(s) }
                    i += 1
                } else { push(.removed(x)) }
            case .added(let y): push(.added(y))
            }
            i += 1
        }
        return out
    }

    /// "role." → "role?": same "role", removed ".", added "?". Only when what differs is punctuation/space,
    /// or one side just extends the other ("apple" → "apples"); "was" → "were" stays a whole-word change.
    static func refine(_ x: String, _ y: String) -> [Seg] {
        let a = Array(x), b = Array(y)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let am = String(a[p ..< a.count - s]), bm = String(b[p ..< b.count - s])
        let wordy = { (t: String) in t.contains { $0.isLetter || $0.isNumber } }
        guard p + s > 0, am.isEmpty || bm.isEmpty || (!wordy(am) && !wordy(bm)) else { return [.removed(x), .added(y)] }
        return [.same(String(a[..<p])), .removed(am), .added(bm), .same(String(a[(a.count - s)...]))]
    }

    /// Shortens unchanged stretches longer than `keep` words on each side of a change to "…".
    static func compact(_ segs: [Seg], keep: Int = 3) -> [Seg] {
        segs.enumerated().map { (k, seg) in
            guard case .same(let s) = seg else { return seg }
            let words = WordDiff.tokens(s)
            let wordCount = words.filter { !$0.allSatisfy(\.isWhitespace) }.count
            let first = k == 0, last = k == segs.count - 1
            if first, wordCount > keep { return .same("… " + tail(words, keep)) }
            if last, wordCount > keep { return .same(head(words, keep) + " …") }
            if !first, !last, wordCount > keep * 2 + 1 { return .same(head(words, keep) + " … " + tail(words, keep)) }
            return seg
        }
    }

    private static func head(_ tokens: [String], _ n: Int) -> String {
        var out = "", words = 0
        for t in tokens {
            if words == n { break }
            if !t.allSatisfy(\.isWhitespace) { words += 1 }
            out += t
        }
        return out // keeps the leading space, drops the one after the last kept word
    }

    private static func tail(_ tokens: [String], _ n: Int) -> String {
        var out = "", words = 0
        for t in tokens.reversed() {
            if words == n { break }
            if !t.allSatisfy(\.isWhitespace) { words += 1 }
            out = t + out
        }
        return out // keeps the trailing space, starts at the first kept word
    }

    static func plain(_ segs: [Seg]) -> String {
        segs.map { switch $0 { case .same(let s), .removed(let s), .added(let s): return s } }.joined()
    }

    private static var accent: Color { Color(nsColor: .controlAccentColor) }

    /// The whole change in place: unchanged text plain, removed struck through in red, added bold in the accent colour.
    static func text(_ segs: [Seg]) -> Text {
        let wordy = { (t: String) in t.contains { $0.isLetter || $0.isNumber } }
        var t = Text("")
        for (k, seg) in segs.enumerated() {
            switch seg {
            case .same(let s): t = t + Text(s).foregroundColor(.primary)
            case .removed(let s):
                // Removed punctuation is tiny under a strike: red and bold so it's seen.
                t = t + (wordy(s) ? Text(visible(s)).foregroundColor(.secondary)
                                  : Text(visible(s)).fontWeight(.bold).foregroundColor(.red))
                    .strikethrough(true, color: .red)
            case .added(let s):
                // "that" struck + "what" added read as one word without a gap.
                if k > 0, case .removed(let r) = segs[k - 1], wordy(r), wordy(s), r.last?.isWhitespace == false, s.first?.isWhitespace == false {
                    t = t + Text(" ")
                }
                t = t + Text(visible(s)).fontWeight(.bold).foregroundColor(accent)
            }
        }
        return t
    }

    /// The fix alone, bold, with the changed characters in the accent colour.
    static func fixText(_ a: String, _ b: String) -> Text {
        segments(a, b).reduce(Text("")) { t, seg in
            switch seg {
            case .same(let s): return t + Text(s).fontWeight(.semibold).foregroundColor(.primary)
            case .removed: return t
            case .added(let s): return t + Text(s).fontWeight(.bold).foregroundColor(accent)
            }
        }
    }

    /// A removed or added space alone would be invisible.
    private static func visible(_ s: String) -> String { s.allSatisfy(\.isWhitespace) ? s.replacingOccurrences(of: " ", with: "␣") : s }
}

extension PopupStyle {
    /// The popup font as an NSFont, for measuring text before layout.
    static func nsFont(_ pt: CGFloat, bold: Bool = false) -> NSFont {
        let family = Settings.shared.popupFont
        let weight: NSFont.Weight = bold ? .semibold : .regular
        if family.isEmpty { return .systemFont(ofSize: pt, weight: weight) }
        if family == "__mono__" { return .monospacedSystemFont(ofSize: pt, weight: weight) }
        return NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: pt)
            ?? NSFont(name: family, size: pt) ?? .systemFont(ofSize: pt, weight: weight)
    }

    static func width(_ s: String, _ pt: CGFloat, bold: Bool = false) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: nsFont(pt, bold: bold)]).width) + 2
    }

    /// The widest a popup's text column gets before it wraps.
    static var maxTextWidth: CGFloat { 460 * scale }
}

/// Text that keeps its natural width when it fits, and wraps at `maxTextWidth` when it doesn't.
struct Wrapping<V: View>: View {
    let natural: CGFloat
    var maxWidth: CGFloat = PopupStyle.maxTextWidth
    @ViewBuilder var content: () -> V
    var body: some View {
        if natural > maxWidth {
            content().frame(width: maxWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        } else {
            content().fixedSize()
        }
    }
}
