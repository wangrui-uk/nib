import AppKit
import ApplicationServices

/// Text positions through the WebKit/Chromium text-marker API, for editors where AXBoundsForRange gives
/// nothing (e.g. Slack's composer and other rich editors in Electron/Chromium apps).
///
/// A character offset is turned into a marker by walking AXNextTextMarkerForTextMarker from the field's start
/// marker. Walks are lazy (only as far as needed), cached per field and text version, checked against
/// AXLengthForTextMarkerRange, and capped.
enum TextMarkers {
    static let maxWalk = 3000

    private struct Walk {
        var element: AXUIElement
        var version: Int
        var markers: [AXTextMarker] // markers[i] = position before character i
        var verified: Bool?
        /// Whether rects come back in AX (top-left) or Cocoa (bottom-left) screen coordinates.
        var flipped: Bool?
    }

    private static var walk: Walk?
    /// Bumped whenever the text of the field changes (LiveChecker sets it).
    static var version = 0
    /// The field's layout (frame, plus a one-second bucket for scrolling inside it): position caches are keyed by it,
    /// so a page scroll, a resize or a scroll inside the field never reuses old positions.
    static var layout = ""

    /// The character index at a screen point (AX coordinates), if the app answers; for verifying underlines.
    static func indexAt(_ el: AXUIElement, _ p: CGPoint) -> Int? { index(el, at: p) }

    private static func param(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var out: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &out) == .success else { return nil }
        return out
    }

    /// Asks the page element (if any) instead of the field: for position queries and per-character rects.
    private static func pageParam(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        guard let w = webArea(of: el) else { return nil }
        return param(w, name, arg)
    }

    private static var supportCache: (AXUIElement, Bool, Date)?

    /// Whether an AXBoundsForRange rect can be used as is: it lies in (or near) the field. Decided once per field,
    /// so native fields pay for the frame check only the first time.
    private static var plainTrust: (AXUIElement, Bool, Date)?

    static func isPlainTrusted(_ el: AXUIElement, _ rect: CGRect, frame: () -> CGRect?) -> Bool {
        if let t = plainTrust, CFEqual(t.0, el), fresh(t.2) { return t.1 }
        guard let f = frame() else { return true }
        let ok = f.insetBy(dx: -40, dy: -40).intersects(rect)
        plainTrust = (el, ok, Date())
        if !ok { log("live: AXBoundsForRange gives positions outside the field; using text markers when possible") }
        return ok
    }

    /// Per-field answers are kept for a while only: an Electron tree that wasn't ready yet mustn't stick.
    static func fresh(_ at: Date, now: Date = Date()) -> Bool { now.timeIntervalSince(at) < LiveChecker.negativeCacheLifetime }

    /// Drops the per-field answers so the next check asks again.
    static func forget() { supportCache = nil; plainTrust = nil; webAreaCache = nil }

    static func supported(_ el: AXUIElement) -> Bool {
        if let c = supportCache, CFEqual(c.0, el), c.1 || fresh(c.2) { return c.1 }
        let ok = supportedUncached(el)
        supportCache = (el, ok, Date())
        return ok
    }

    private static func supportedUncached(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(el, &names)
        let list = (names as? [String]) ?? []
        return list.contains("AXBoundsForTextMarkerRange") && list.contains("AXNextTextMarkerForTextMarker")
            && list.contains("AXTextMarkerRangeForUIElement")
    }

    private static func startMarker(_ el: AXUIElement) -> AXTextMarker? {
        guard let r = param(el, "AXTextMarkerRangeForUIElement", el), CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        return AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
    }

    /// The marker before character `index`, walking (and caching) as needed.
    private static func marker(_ el: AXUIElement, at index: Int) -> AXTextMarker? {
        guard index >= 0, index <= maxWalk else { return nil }
        if walk == nil || !CFEqual(walk!.element, el) || walk!.version != version {
            guard let start = startMarker(el) else { return nil }
            walk = Walk(element: el, version: version, markers: [start], verified: nil, flipped: nil)
        }
        while walk!.markers.count <= index {
            guard let next = param(el, "AXNextTextMarkerForTextMarker", walk!.markers.last!),
                  CFGetTypeID(next) == AXTextMarkerGetTypeID() else { return nil }
            let m = next as! AXTextMarker
            // The end of the text: the walk stops moving.
            if let last = walk!.markers.last, CFEqual(last, m) { return nil }
            walk!.markers.append(m)
        }
        return walk!.markers[index]
    }

    private static func markerRange(_ el: AXUIElement, _ range: NSRange) -> AXTextMarkerRange? {
        guard let a = marker(el, at: range.location), let b = marker(el, at: NSMaxRange(range)) else { return nil }
        return AXTextMarkerRangeCreate(nil, a, b)
    }

    /// Checks once per text version that walking n steps really covers n characters.
    private static func verify(_ el: AXUIElement, upTo n: Int) -> Bool {
        if let v = walk?.verified { return v }
        guard n > 0, let r = markerRange(el, NSRange(location: 0, length: n)),
              let len = param(el, "AXLengthForTextMarkerRange", r) as? NSNumber else { return false }
        let ok = len.intValue == n
        walk?.verified = ok
        if !ok { log("live: text markers don't line up with characters (\(len.intValue) vs \(n)); no positions") }
        return ok
    }

    /// The raw rect for a marker range (AX coordinates, flipped if this field needs it).
    private static func rawRect(_ el: AXUIElement, _ range: NSRange, fieldFrame: CGRect?, page: Bool = false) -> CGRect? {
        guard let r = markerRange(el, range),
              let v = page ? pageParam(el, "AXBoundsForTextMarkerRange", r) : param(el, "AXBoundsForTextMarkerRange", r),
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        // Normally top-left screen coordinates like every AX rect; if the rect only fits the field when flipped,
        // the app uses bottom-left ones.
        if let f = fieldFrame {
            if walk?.flipped == nil {
                let h = NSScreen.screens.first?.frame.height ?? 0
                let alt = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
                let slack = f.insetBy(dx: -40, dy: -40)
                if slack.intersects(rect) { walk?.flipped = false }
                else if slack.intersects(alt) { walk?.flipped = true; log("live: text-marker rects are bottom-left based; flipping") }
            }
            if walk?.flipped == true {
                let h = NSScreen.screens.first?.frame.height ?? 0
                rect = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
            }
        }
        return rect
    }

    /// A rect is believable for `length` characters if it isn't (nearly) the whole field: some editors answer
    /// a short range with the line's or the field's box.
    static func plausible(_ r: CGRect, length: Int, textLength: Int, field: CGRect?) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        guard let f = field else { return true }
        let wholeWidth = r.width >= f.width * 0.9
        let wholeHeight = r.height >= f.height * 0.9 && f.height > 30
        if (wholeWidth || wholeHeight) && length < max(3, textLength * 3 / 4) { return false }
        return true
    }

    /// The character index at a screen point (AX coordinates), via AXTextMarkerForPosition + AXLengthForTextMarkerRange.
    private static func index(_ el: AXUIElement, at p: CGPoint) -> Int? {
        var pt = p
        guard let pv = AXValueCreate(.cgPoint, &pt),
              let m = param(el, "AXTextMarkerForPosition", pv) ?? pageParam(el, "AXTextMarkerForPosition", pv),
              CFGetTypeID(m) == AXTextMarkerGetTypeID(), let start = marker(el, at: 0) else { return nil }
        let r = AXTextMarkerRangeCreate(nil, start, m as! AXTextMarker)
        return ((param(el, "AXLengthForTextMarkerRange", r) ?? pageParam(el, "AXLengthForTextMarkerRange", r)) as? NSNumber)?.intValue
    }

    /// Leftmost x on the line `y` where the character index reaches `target` (binary search, ~12 probes).
    private static func x(forIndex target: Int, _ el: AXUIElement, y: CGFloat, field f: CGRect) -> CGFloat? {
        var lo = f.minX, hi = f.maxX
        guard let atEnd = index(el, at: CGPoint(x: hi - 1, y: y)), atEnd >= target else { return nil }
        for _ in 0..<13 {
            let mid = (lo + hi) / 2
            guard let i = index(el, at: CGPoint(x: mid, y: y)) else { return nil }
            if i >= target { hi = mid } else { lo = mid }
        }
        return hi
    }

    private static var positionCache: [String: CGRect] = [:]
    /// Which method produced the last position (for diagnostics).
    static var lastMethod = "-"

    /// Screen rect (AX coordinates: top-left origin) of `range`, or nil. Tries, in order: the range's own rect;
    /// joined single-character rects at its start and end; and finding the x positions by hit-testing the line.
    static func bounds(_ el: AXUIElement, _ range: NSRange, fieldFrame: CGRect?) -> CGRect? {
        guard range.length > 0, NSMaxRange(range) <= maxWalk, supported(el),
              verify(el, upTo: max(1, min(NSMaxRange(range), 64))) else { return nil }
        let key = "\(CFHash(el))|\(version)|\(layout)|\(range.location)|\(range.length)"
        if let c = positionCache[key] { return c }
        if positionCache.count > 500 { positionCache.removeAll() }
        let textLength = TextTarget.number(el, kAXNumberOfCharactersAttribute) ?? NSMaxRange(range)
        // 1. The range's own rect.
        if let r = rawRect(el, range, fieldFrame: fieldFrame), plausible(r, length: range.length, textLength: textLength, field: fieldFrame) {
            lastMethod = "text-marker range"
            positionCache[key] = r
            return r
        }
        // 2. Single characters at both ends, joined (same line only).
        if let a = rawRect(el, NSRange(location: range.location, length: 1), fieldFrame: fieldFrame),
           let b = rawRect(el, NSRange(location: NSMaxRange(range) - 1, length: 1), fieldFrame: fieldFrame),
           plausible(a, length: 1, textLength: textLength, field: fieldFrame),
           plausible(b, length: 1, textLength: textLength, field: fieldFrame) {
            let r = abs(a.midY - b.midY) < a.height / 2 ? a.union(b) : a
            lastMethod = "joined character rects"
            positionCache[key] = r
            return r
        }
        // 2b. The same two through the page element (Chromium answers there for rich editors).
        if let r = rawRect(el, range, fieldFrame: fieldFrame, page: true), plausible(r, length: range.length, textLength: textLength, field: fieldFrame) {
            positionCache[key] = r
            return r
        }
        if let a = rawRect(el, NSRange(location: range.location, length: 1), fieldFrame: fieldFrame, page: true),
           let b = rawRect(el, NSRange(location: NSMaxRange(range) - 1, length: 1), fieldFrame: fieldFrame, page: true),
           plausible(a, length: 1, textLength: textLength, field: fieldFrame), plausible(b, length: 1, textLength: textLength, field: fieldFrame) {
            let r = abs(a.midY - b.midY) < a.height / 2 ? a.union(b) : a
            positionCache[key] = r
            return r
        }
        // 2c. The editor's text runs (Chromium exposes each run as an AXStaticText child with its own frame):
        // place the range proportionally inside the run that holds it (single-line runs only).
        if let r = runBounds(el, range) {
            lastMethod = "text runs"
            positionCache[key] = r
            return r
        }
        // 3. Hit-test: find the line the range starts on, then where on it the range starts and ends. Only the part
        // of the field inside its window counts (a full-width web editor can be wider than the screen).
        guard let whole = fieldFrame else { return nil }
        let f = windowClipped(el, whole)
        guard let line = self.line(containing: range.location, el, field: f) else { return nil }
        let endOnLine = min(NSMaxRange(range), line.nextStart ?? NSMaxRange(range))
        guard let x0 = x(forIndex: range.location + 1, el, y: line.y, field: f),
              let x1 = x(forIndex: endOnLine, el, y: line.y, field: f) else { return nil }
        // x(forIndex: i + 1) is the right edge of character i; step back one character width for the start.
        let chars = max(1, endOnLine - range.location)
        let charWidth = chars > 1 ? max(4, (x1 - x0) / CGFloat(chars - 1)) : 7
        let h = min(max(line.height, 12), 28)
        let r = CGRect(x: x0 - charWidth, y: line.y - h / 2, width: max(charWidth, x1 - x0 + charWidth), height: h)
        lastMethod = "line hit-testing"
        positionCache[key] = r
        return r
    }

    /// The page element (AXWebArea) the field sits in: Chromium answers position queries there.
    private static var webAreaCache: (AXUIElement, AXUIElement?, Date)?
    static func webArea(of el: AXUIElement) -> AXUIElement? {
        if let c = webAreaCache, CFEqual(c.0, el), c.1 != nil || fresh(c.2) { return c.1 }
        var cur = el, found: AXUIElement?
        for _ in 0..<60 {
            guard let p = TextAccess.attr(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            cur = p as! AXUIElement
            if TextAccess.attr(cur, kAXRoleAttribute) as? String == "AXWebArea" { found = cur; break }
        }
        webAreaCache = (el, found, Date())
        return found
    }

    /// The field's frame clipped to its window (AX coordinates).
    static func windowClipped(_ el: AXUIElement, _ f: CGRect) -> CGRect {
        var cur = el
        for _ in 0..<40 {
            guard let p = TextAccess.attr(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            cur = p as! AXUIElement
            if TextAccess.attr(cur, kAXRoleAttribute) as? String == "AXWindow" {
                if let wf = LiveChecker.frame(cur) { let c = f.intersection(wf); return c.isNull || c.width < 10 ? f : c }
                break
            }
        }
        return f
    }

    private struct Run { let start: Int; let length: Int; let frame: CGRect }
    private static var runCache: (String, [Run])?

    /// Monaco's visible lines vs the textarea's text, for diagnostics and for checking only what's on screen.
    struct LineMatch { var textLines = 0; var visualLines = 0; var matchedLines = 0; var visibleRanges: [NSRange] = [] }
    private(set) static var lastLineMatch: (String, LineMatch)?

    /// The field's text runs in order, with their character offsets. Cached per field and text version.
    /// Ordinary fields (Slack, Chrome): each run's text is found left to right. Monaco's main editor: the visible
    /// lines are matched to the textarea's text by content (see `matchLines`), because its text may be just a page
    /// of the file, the view may be scrolled, and a highlighted file (Markdown) splits each line into tokens.
    private static func runs(_ el: AXUIElement) -> [Run] {
        let key = "\(CFHash(el))|\(version)|\(layout)"
        if let c = runCache, c.0 == key { return c.1 }
        var out: [Run] = []
        guard let full = TextTarget.text(el)?.0 else { runCache = (key, out); return out }
        let ns = full as NSString
        // Monaco's hidden textarea has no visible text: the visible lines live in the editor area around it.
        let monaco = Monaco.isMainEditor(el) && (TextAccess.attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []).isEmpty
        let area = monaco ? (Monaco.editorArea(of: el) ?? el) : el
        let root = monaco ? (Monaco.viewLines(in: area) ?? area) : el
        var pieces: [Piece] = []
        var queue: [AXUIElement] = (TextAccess.attr(root, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        var seen = 0
        while !queue.isEmpty, seen < 3000 {
            let c = queue.removeFirst(); seen += 1
            if monaco, Monaco.isNonText(c) { continue } // sticky scroll, line numbers, breadcrumbs, widgets
            let role = TextAccess.attr(c, kAXRoleAttribute) as? String ?? ""
            if role == "AXStaticText", let t = TextAccess.attr(c, kAXValueAttribute) as? String, !t.isEmpty,
               let f = LiveChecker.frame(c) {
                pieces.append(Piece(text: t, frame: f))
                continue
            }
            // Depth-first, keeping document order.
            if let kids = TextAccess.attr(c, kAXChildrenAttribute) as? [AXUIElement] { queue.insert(contentsOf: kids, at: 0) }
        }
        if monaco {
            let (starts, match) = matchLines(pieces, in: full)
            for (p, st) in zip(pieces, starts) { if let st { out.append(Run(start: st, length: (p.text as NSString).length, frame: p.frame)) } }
            lastLineMatch = (key, match)
        } else {
            var cursor = 0
            for p in pieces {
                let r = ns.range(of: p.text, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
                if r.location != NSNotFound { out.append(Run(start: r.location, length: r.length, frame: p.frame)); cursor = NSMaxRange(r) }
            }
        }
        runCache = (key, out)
        return out
    }

    static func runCount(_ el: AXUIElement) -> Int { runs(el).count }

    /// Monaco only: the parts of the text that are on screen (whole text lines), or nil if unknown.
    static func visibleRanges(_ el: AXUIElement) -> [NSRange]? {
        _ = runs(el)
        guard let m = lastLineMatch, m.0 == "\(CFHash(el))|\(version)|\(layout)", m.1.matchedLines > 0 else { return nil }
        return m.1.visibleRanges
    }

    /// Monaco only: textarea lines, visible lines, matched lines (for Copy Diagnostics).
    static func lineMatch(_ el: AXUIElement) -> LineMatch? {
        _ = runs(el)
        guard let m = lastLineMatch, m.0 == "\(CFHash(el))|\(version)|\(layout)" else { return nil }
        return m.1
    }

    struct Piece { let text: String; let frame: CGRect }

    /// Matches Monaco's rendered text pieces to the text by content, line by line. Pieces are grouped into visual
    /// lines by their vertical position; each visual line (its pieces joined left to right) is looked up in the
    /// text, forward from the previous match; then each piece is placed inside it. Line numbers (digit-only pieces)
    /// and lines that aren't in the text (outside the textarea's page) are skipped instead of derailing the rest.
    /// Pure, for self-tests. Returns each piece's start offset (or nil) and the match stats.
    static func matchLines(_ pieces: [Piece], in full: String) -> ([Int?], LineMatch) {
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        let text = norm(full) as NSString
        var match = LineMatch()
        match.textLines = full.components(separatedBy: "\n").count
        var starts = [Int?](repeating: nil, count: pieces.count)
        // Visual lines: (indexes of pieces, mid y, height).
        var groups: [(idx: [Int], midY: CGFloat, h: CGFloat)] = []
        for (k, p) in pieces.enumerated() {
            let t = norm(p.text).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.allSatisfy(\.isNumber) { continue } // line numbers
            if let g = groups.firstIndex(where: { abs($0.midY - p.frame.midY) <= max(3, min($0.h, p.frame.height) / 2) }) {
                groups[g].idx.append(k)
            } else {
                groups.append(([k], p.frame.midY, max(1, p.frame.height)))
            }
        }
        groups.sort { $0.midY < $1.midY }
        let len = text.length
        var cursor = 0
        func lineRange(at i: Int) -> NSRange { text.lineRange(for: NSRange(location: min(i, max(0, len - 1)), length: 0)) }
        /// Where `needle` is, from `from`: forward first; short needles only within the next few lines.
        func find(_ needle: String, from: Int) -> NSRange? {
            let n = (needle as NSString).length
            guard n > 0, len > 0 else { return nil }
            var end = len
            if n < 4 {
                var lines = 0, i = from
                while i < len, lines < 3 { let r = lineRange(at: i); i = NSMaxRange(r); lines += 1 }
                end = max(from, min(len, i))
            }
            let fwd = text.range(of: needle, options: [], range: NSRange(location: from, length: end - from))
            if fwd.location != NSNotFound { return fwd }
            guard n >= 8, from > 0 else { return nil }
            let back = text.range(of: needle, options: [], range: NSRange(location: 0, length: from))
            return back.location == NSNotFound ? nil : back
        }
        for g in groups {
            let idx = g.idx.sorted { pieces[$0].frame.minX < pieces[$1].frame.minX }
            let joined = idx.map { norm(pieces[$0].text) }.joined()
            let core = joined.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { continue }
            match.visualLines += 1
            // The whole visual line, else anchored on its longest piece (in case whitespace-only pieces are missing).
            var anchor: Int?
            if let r = find(core, from: cursor) { anchor = r.location }
            else {
                let longest = idx.map { norm(pieces[$0].text).trimmingCharacters(in: .whitespaces) }.max { ($0 as NSString).length < ($1 as NSString).length } ?? ""
                if (longest as NSString).length >= 4, let r = find(longest, from: cursor) { anchor = lineRange(at: r.location).location }
            }
            guard let a = anchor else { continue }
            let line = lineRange(at: a)
            let leading = (joined as NSString).length - (String(joined.drop { $0 == " " }) as NSString).length
            var p = max(line.location, a - leading)
            var placed = false
            for k in idx {
                let t = norm(pieces[k].text)
                guard !t.trimmingCharacters(in: .whitespaces).isEmpty, p <= NSMaxRange(line) else { continue }
                let r = text.range(of: t, options: [], range: NSRange(location: p, length: NSMaxRange(line) - p))
                if r.location != NSNotFound { starts[k] = r.location; p = NSMaxRange(r); placed = true }
            }
            guard placed else { continue }
            match.matchedLines += 1
            var content = line
            if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            if match.visibleRanges.last.map({ NSEqualRanges($0, content) }) != true { match.visibleRanges.append(content) }
            cursor = max(cursor, p)
        }
        return (starts, match)
    }

    /// The run's text (from the field's text, by the run's offsets).
    private static func runText(_ el: AXUIElement, _ run: Run) -> NSString? {
        guard let full = TextTarget.text(el)?.0 as NSString?, NSMaxRange(NSRange(location: run.start, length: run.length)) <= full.length else { return nil }
        return full.substring(with: NSRange(location: run.start, length: run.length)) as NSString
    }

    /// Where a range lies inside a run of `width` points, by measured text width rather than character count, so
    /// wide characters (Chinese, Korean, Japanese) and narrow ones (i, l, spaces) are placed right. Pure, for self-tests.
    static func proportionalSpan(_ text: NSString, _ r: NSRange, width: CGFloat) -> (CGFloat, CGFloat) {
        let font = NSFont.systemFont(ofSize: 13)
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let total = w(text as String)
        guard total > 0 else { return (0, width) }
        let a = w(text.substring(to: r.location)), b = w(text.substring(to: min(text.length, NSMaxRange(r))))
        return (width * a / total, width * b / total)
    }

    private static func runBounds(_ el: AXUIElement, _ range: NSRange) -> CGRect? {
        guard let run = runs(el).first(where: { $0.start <= range.location && range.location < $0.start + $0.length }),
              run.frame.height > 0, run.frame.height < 8 * 40, run.length > 0 else { return nil }
        let local = range.location - run.start
        let len = min(range.length, run.start + run.length - range.location)
        guard let text = runText(el, run) else {
            guard run.frame.height < 26 else { return nil } // a wrapped run can't be placed without its text
            let w = run.frame.width / CGFloat(run.length)
            return CGRect(x: run.frame.minX + w * CGFloat(local), y: run.frame.minY, width: max(4, w * CGFloat(len)), height: run.frame.height)
        }
        return wrappedRunRect(text, NSRange(location: local, length: len), frame: run.frame)
    }

    /// Where a range lies inside a run that may wrap over several lines (a paragraph in a rich editor is one run
    /// whose frame is several lines tall). The number of lines and the font size are found together: for n lines,
    /// the line height is frame height / n and the font about line height / 1.2; the n whose simulated word wrap at
    /// the run's width also gives n lines wins. x is scaled so the widest simulated line matches the run's width.
    /// Returns the rect on the range's line (the union of rows if it spans several). Pure, for self-tests.
    static func wrappedRunRect(_ text: NSString, _ r: NSRange, frame: CGRect) -> CGRect {
        func single() -> CGRect {
            let (x0, x1) = proportionalSpan(text, r, width: frame.width)
            return CGRect(x: frame.minX + x0, y: frame.minY, width: max(4, x1 - x0), height: frame.height)
        }
        guard frame.height >= 26, text.length > 1 else { return single() }
        var chosen: (n: Int, font: NSFont, rows: [NSRange])?
        for n in 2...8 {
            let lineH = frame.height / CGFloat(n)
            guard lineH >= 10 else { break }
            let font = NSFont.systemFont(ofSize: lineH / 1.2)
            let rows = wrap(text, width: frame.width, font: font)
            if rows.count == n { chosen = (n, font, rows); break }
        }
        guard let c = chosen else { return single() }
        func w(_ x: String) -> CGFloat { (x as NSString).size(withAttributes: [.font: c.font]).width }
        let widest = c.rows.map { w(text.substring(with: $0).trimmingCharacters(in: .whitespaces)) }.max() ?? frame.width
        let scale = widest > 0 ? frame.width / widest : 1
        let lineH = frame.height / CGFloat(c.n)
        func row(of i: Int) -> Int { c.rows.lastIndex { $0.location <= i } ?? 0 }
        let first = row(of: r.location), last = row(of: max(r.location, NSMaxRange(r) - 1))
        var out = CGRect.null
        for k in first...last {
            let rr = c.rows[k]
            let from = max(r.location, rr.location), to = min(NSMaxRange(r), NSMaxRange(rr))
            let x0 = w(text.substring(with: NSRange(location: rr.location, length: from - rr.location))) * scale
            let x1 = w(text.substring(with: NSRange(location: rr.location, length: to - rr.location))) * scale
            out = out.union(CGRect(x: frame.minX + x0, y: frame.minY + CGFloat(k) * lineH, width: max(4, x1 - x0), height: lineH))
        }
        return out
    }

    /// Greedy word wrap (breaking after spaces; CJK anywhere) at `width` in `font`: the rows' ranges.
    static func wrap(_ text: NSString, width: CGFloat, font: NSFont) -> [NSRange] {
        func w(_ r: NSRange) -> CGFloat { (text.substring(with: r) as NSString).size(withAttributes: [.font: font]).width }
        var rows: [NSRange] = []
        var start = 0, lastBreak = -1, i = 0
        while i < text.length {
            let cr = text.rangeOfComposedCharacterSequence(at: i)
            let end = NSMaxRange(cr)
            let isSpace = text.character(at: i) == 32
            let wide = Unicode.Scalar(text.character(at: i)).map(Lang.isWide) ?? false
            // Trailing spaces may hang past the edge, as in browsers.
            if !isSpace, w(NSRange(location: start, length: end - start)) > width + 0.5, i > start {
                let brk = lastBreak > start ? lastBreak : i
                rows.append(NSRange(location: start, length: brk - start))
                start = brk; lastBreak = -1
                continue
            }
            if isSpace || wide { lastBreak = end }
            i = end
        }
        rows.append(NSRange(location: start, length: text.length - start))
        return rows
    }

    private struct Line { let y: CGFloat; let height: CGFloat; let start: Int; let nextStart: Int? }
    private static var lineTables: [String: [Line]] = [:]

    /// The field's visible lines: probing down its left edge, where the character index at the left jumps,
    /// a new line starts. Cached per field and text version.
    private static func lines(_ el: AXUIElement, field f: CGRect) -> [Line] {
        let key = "\(CFHash(el))|\(version)|\(layout)"
        if let t = lineTables[key] { return t }
        if lineTables.count > 50 { lineTables.removeAll() }
        var bands: [(start: Int, top: CGFloat, bottom: CGFloat)] = []
        var y = f.minY + 2
        while y < f.maxY - 1 && bands.count < 200 {
            if let i = index(el, at: CGPoint(x: f.minX + 3, y: y)) {
                if let last = bands.last, last.start == i { bands[bands.count - 1].bottom = y }
                else if bands.last.map({ i > $0.start }) ?? true { bands.append((i, y, y)) }
            }
            y += 4
        }
        let table = bands.enumerated().map { (k, b) in
            Line(y: (b.top + b.bottom) / 2, height: max(b.bottom - b.top + 4, 12), start: b.start,
                 nextStart: k + 1 < bands.count ? bands[k + 1].start : nil)
        }
        lineTables[key] = table
        return table
    }

    private static func line(containing index: Int, _ el: AXUIElement, field f: CGRect) -> Line? {
        lines(el, field: f).last { $0.start <= index }
    }

    /// For diagnostics: what each method returns for a range (numbers only).
    static func describe(_ el: AXUIElement, _ range: NSRange, fieldFrame: CGRect?) -> String {
        func fmt(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "none" }
        let textLength = TextTarget.number(el, kAXNumberOfCharactersAttribute) ?? NSMaxRange(range)
        let raw = rawRect(el, range, fieldFrame: fieldFrame)
        let first = rawRect(el, NSRange(location: range.location, length: 1), fieldFrame: fieldFrame)
        let ok = raw.map { plausible($0, length: range.length, textLength: textLength, field: fieldFrame) } ?? false
        let pageRect = rawRect(el, range, fieldFrame: fieldFrame, page: true)
        var hit = ""
        if let whole = fieldFrame {
            let f = windowClipped(el, whole)
            let pts = [CGPoint(x: f.minX + 3, y: f.midY), CGPoint(x: f.minX + 60, y: f.midY), CGPoint(x: f.minX + 200, y: f.midY)]
            var pv = pts[0]
            let raw = AXValueCreate(.cgPoint, &pv).flatMap { param(el, "AXTextMarkerForPosition", $0) }
            hit = "; clipped field \(fmt(f)); marker at point: \(raw == nil ? "none" : "yes"); index at points: "
                + pts.map { p in index(el, at: p).map(String.init) ?? "nil" }.joined(separator: ",")
                + "; lines found: \(lines(el, field: f).count)"
        }
        return "range \(range.location)+\(range.length): marker rect \(fmt(raw))\(raw == nil ? "" : ok ? " (plausible)" : " (too big: line/field box)"), first char \(fmt(first)), via page element: \(webArea(of: el) == nil ? "no web area" : fmt(pageRect)), text runs: \(runs(el).count) (\(fmt(runBounds(el, range)))), used \(fmt(bounds(el, range, fieldFrame: fieldFrame)))\(hit)"
    }
}
