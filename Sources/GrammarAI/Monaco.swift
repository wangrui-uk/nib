import AppKit
import ApplicationServices

/// The main editor of Monaco-based code editors (VS Code, Cursor, Windsurf). Typing goes into a hidden
/// 1-pixel textarea whose text is a window of lines around the cursor (more with accessibility on); the
/// visible lines are rendered separately. Experimental, behind Settings → Allow underlines in code editors.
enum Monaco {
    static let proseExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "qmd", "rmd", "txt", "text", "rst", "adoc", "asciidoc", "org", "tex", "textile", "wiki"]

    /// The hidden textarea of a code editor's main editor. Only ever true in VS Code / Cursor / Windsurf: the
    /// shape test alone would also match Slack's composer (one line tall, can hold a newline), which broke Slack in
    /// 2.0.11–2.0.14.
    static func isMainEditor(_ el: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid), TextAccess.isCodeEditor(app),
              let f = LiveChecker.frame(el) else { return false }
        return mainEditorShape(isCodeEditor: true, frame: f, text: TextTarget.text(el)?.0 ?? "",
                               description: TextAccess.attr(el, kAXDescriptionAttribute) as? String ?? "")
    }

    /// The pure shape test (self-tested with Slack's, VS Code's and Cursor's real numbers).
    static func mainEditorShape(isCodeEditor: Bool, frame f: CGRect, text: String, description: String) -> Bool {
        guard isCodeEditor else { return false }
        if f.width <= 12 || f.height <= 12 { return true }
        if description.lowercased().contains("editor content") { return true }
        return f.height < 40 && text.contains("\n")
    }

    /// The open file's name and where it came from. The window's AXDocument (the file VS Code shows in the
    /// title-bar proxy icon) is used first; the window title is the fallback. No AXDocument usually means an
    /// unsaved Untitled editor, whose title may be its first line of text (VS Code's default untitled label).
    struct FileInfo { let name: String?; let source: String; let onDisk: Bool }

    static func fileInfo(_ app: NSRunningApplication, _ axApp: AXUIElement) -> FileInfo {
        guard let w = TextAccess.attr(axApp, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else {
            return FileInfo(name: nil, source: "no focused window", onDisk: false)
        }
        let win = w as! AXUIElement
        if let doc = TextAccess.attr(win, kAXDocumentAttribute) as? String, !doc.isEmpty {
            let name = URL(string: doc)?.lastPathComponent ?? (doc as NSString).lastPathComponent
            if !name.isEmpty { return FileInfo(name: name, source: "window document", onDisk: true) }
        }
        guard let title = TextAccess.attr(win, kAXTitleAttribute) as? String else { return FileInfo(name: nil, source: "no window title", onDisk: false) }
        return FileInfo(name: fileName(fromTitle: title), source: "window title", onDisk: false)
    }

    static func fileName(_ app: NSRunningApplication, _ axApp: AXUIElement) -> String? { fileInfo(app, axApp).name }

    /// "● notes.md — project — Visual Studio Code" → "notes.md"; also " - " separators and VS Code's bracketed
    /// prefixes ("[Restricted Mode]", "[Extension Development Host]") and suffixes ("(Working Tree)", "(Preview)").
    static func fileName(fromTitle title: String) -> String? {
        var t = title.trimmingCharacters(in: .whitespaces)
        for dirty in ["● ", "• ", "* "] where t.hasPrefix(dirty) { t = String(t.dropFirst(dirty.count)) }
        while t.hasPrefix("["), let close = t.firstIndex(of: "]") { t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
        for dirty in ["● ", "• "] where t.hasPrefix(dirty) { t = String(t.dropFirst(dirty.count)) }
        var first = t.components(separatedBy: " — ").first ?? t
        first = first.components(separatedBy: " – ").first ?? first
        first = first.components(separatedBy: " - ").first ?? first
        if let r = first.range(of: " (", options: .backwards), first.hasSuffix(")") { first = String(first[..<r.lowerBound]) }
        first = first.trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? nil : first
    }

    /// Files with no extension that are code or config, not prose.
    static let codeNames: Set<String> = ["makefile", "dockerfile", "gemfile", "rakefile", "podfile", "procfile", "vagrantfile",
        "brewfile", "jenkinsfile", "cmakelists", "justfile", "codeowners", "containerfile", "caddyfile"]

    /// Prose files are checked; code files aren't (never send identifiers-only content).
    static func isProse(_ file: String?, onDisk: Bool = true) -> Bool { proseVerdict(file, onDisk: onDisk).0 }

    /// Whether the file is checked, and why (for Copy Diagnostics).
    static func proseVerdict(_ file: String?, onDisk: Bool = true) -> (Bool, String) {
        guard let f = file?.lowercased(), !f.isEmpty else { return (false, "no file name") }
        if f.hasPrefix("untitled") { return (true, "untitled document") }
        let ext = (f as NSString).pathExtension
        if proseExtensions.contains(ext) { return (true, ".\(ext) is a prose type") }
        if ext.isEmpty || f.hasPrefix(".") {
            if f.hasPrefix(".") { return (false, "dotfile (config)") }
            if codeNames.contains(f) { return (false, "\(f) is a code/config file") }
            // No extension: a README-style text file, or an unsaved editor titled by its first line.
            return (true, onDisk ? "no extension: treated as plain text" : "unsaved editor (title is its first line)")
        }
        // A title like "Meeting notes. Draft" of an unsaved editor isn't a file extension.
        if !onDisk, ext.count > 8 || ext.contains(" ") { return (true, "unsaved editor (title is its first line)") }
        return (false, ".\(ext) isn't a prose type (checked: \(proseExtensions.sorted().map { "." + $0 }.joined(separator: " ")), untitled, no extension)")
    }

    /// Chromium's DOM class list for an element (AXDOMClassList), if exposed.
    static func classes(_ el: AXUIElement) -> [String] { TextAccess.attr(el, "AXDOMClassList") as? [String] ?? [] }

    /// Monaco's container of the rendered file lines (class "view-lines"), if Chromium exposes DOM classes.
    static func viewLines(in area: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(area, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 1500 {
            let (c, depth) = queue.removeFirst(); seen += 1
            let cls = classes(c)
            if cls.contains("view-lines") { return c }
            if isNonTextClass(cls) { continue }
            guard depth < 12, let kids = TextAccess.attr(c, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: kids.map { ($0, depth + 1) })
        }
        return nil
    }

    /// Editor parts that show text which isn't the file's lines (or repeats some of them).
    static let nonTextClasses: Set<String> = ["sticky-widget", "sticky-scroll-focus-line", "margin", "margin-view-overlays",
        "line-numbers", "breadcrumbs-control", "minimap", "codelens-decoration", "overlayWidgets", "contentWidgets",
        "decorationsOverviewRuler", "monaco-hover", "suggest-widget", "find-widget", "inline-completion-text-to-replace", "ghost-text"]
    static func isNonTextClass(_ cls: [String]) -> Bool { cls.contains { nonTextClasses.contains($0) } }
    static func isNonText(_ el: AXUIElement) -> Bool { isNonTextClass(classes(el)) }

    // MARK: Geometry (VS Code's native EditContext)

    /// Newer VS Code types into a native EditContext element ("native-edit-context") that holds the whole file,
    /// sits on the cursor's row at the text's left edge, one line tall, and whose single text child is laid out
    /// unscrolled. The rendered lines expose no text to accessibility. So positions are computed: rows from the
    /// cursor's row, columns from the (monospace) character width, with Monaco's word wrap simulated.
    struct Geometry: Equatable { let rowTop: CGFloat; let left: CGFloat; let lineHeight: CGFloat; let charWidth: CGFloat; let wrapColumns: Int; let cursor: Int }

    static func isEditContext(_ el: AXUIElement) -> Bool { classes(el).contains("native-edit-context") }

    static func geometry(_ el: AXUIElement, text: String) -> Geometry? {
        guard isEditContext(el), isMainEditor(el), let f = LiveChecker.frame(el), f.height >= 8, f.height <= 60,
              let cursor = LiveChecker.selectedRange(el)?.location,
              let child = (TextAccess.attr(el, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let cf = LiveChecker.frame(child) else { return nil }
        let longest = text.components(separatedBy: "\n").map { columns($0) }.max() ?? 0
        guard longest > 0 else { return nil }
        let cw = cf.width / CGFloat(longest)
        guard cw >= 4, cw <= 20 else { return nil }
        return Geometry(rowTop: f.minY, left: f.minX, lineHeight: f.height, charWidth: cw, wrapColumns: max(20, Int(f.width / cw)), cursor: cursor)
    }

    /// Display columns of a line (a tab counts as 4).
    static func columns(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, u in
            if u == "\t" { return n + 4 }
            if u.properties.generalCategory == .nonspacingMark || u.value == 0x200D || (0xFE00...0xFE0F).contains(u.value) { return n }
            return n + (Lang.isWide(u) ? 2 : 1)
        }
    }

    /// Start offsets (UTF-16, within the line) of the line's visual rows under word wrap at `cols` columns.
    static func rowStarts(_ line: NSString, cols: Int) -> [Int] {
        // Walk in display columns (wide characters count 2); break after the last space that fits, else mid-word
        // (CJK text has no spaces and Monaco breaks it anywhere).
        var starts = [0]
        var rowStart = 0, col = 0, lastSpace = -1, i = 0
        while i < line.length {
            let r = line.rangeOfComposedCharacterSequence(at: i)
            let w = columns(line.substring(with: r))
            if col + w > cols, i > rowStart {
                let brk = lastSpace > rowStart ? lastSpace : i
                starts.append(brk)
                rowStart = brk
                col = columns(line.substring(with: NSRange(location: brk, length: NSMaxRange(r) - brk)))
                lastSpace = -1
                if line.character(at: i) == 32 { lastSpace = NSMaxRange(r) }
                i = NSMaxRange(r)
                continue
            }
            col += w
            if line.character(at: i) == 32 { lastSpace = NSMaxRange(r) }
            i = NSMaxRange(r)
        }
        return starts
    }

    /// Screen rects (AX coordinates) of `range`, one per visual row. Pure, for self-tests.
    static func rects(text: String, range: NSRange, _ g: Geometry) -> [CGRect] {
        let ns = text as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return [] }
        var lineStarts = [0]
        for i in 0..<ns.length where ns.character(at: i) == 10 { lineStarts.append(i + 1) }
        func lineIndex(_ off: Int) -> Int { (lineStarts.lastIndex { $0 <= off }) ?? 0 }
        func line(_ k: Int) -> NSString {
            let end = k + 1 < lineStarts.count ? lineStarts[k + 1] - 1 : ns.length
            return ns.substring(with: NSRange(location: lineStarts[k], length: end - lineStarts[k])) as NSString
        }
        var rowsCache: [Int: [Int]] = [:]
        func rows(_ k: Int) -> [Int] { if let r = rowsCache[k] { return r }; let r = rowStarts(line(k), cols: g.wrapColumns); rowsCache[k] = r; return r }
        func rowOf(_ k: Int, col: Int) -> Int { (rows(k).lastIndex { $0 <= col }) ?? 0 }
        let cl = lineIndex(g.cursor), cr = rowOf(cl, col: g.cursor - lineStarts[cl])
        /// Visual rows from the cursor's row to row `r` of line `k`.
        func delta(_ k: Int, _ r: Int) -> Int {
            if k == cl { return r - cr }
            if k > cl { return (rows(cl).count - cr) + (cl + 1 ..< k).reduce(0) { $0 + rows($1).count } + r }
            return -(cr + (k + 1 ..< cl).reduce(0) { $0 + rows($1).count } + (rows(k).count - r))
        }
        var out: [CGRect] = []
        var pos = range.location
        while pos < NSMaxRange(range) {
            let k = lineIndex(pos), l = line(k), col = pos - lineStarts[k]
            if col >= l.length { pos = lineStarts[k] + l.length + 1; continue } // the newline itself
            let rs = rows(k), r = rowOf(k, col: col)
            let rowEnd = r + 1 < rs.count ? rs[r + 1] : l.length
            let end = min(NSMaxRange(range) - lineStarts[k], rowEnd)
            let prefix = l.substring(with: NSRange(location: rs[r], length: col - rs[r]))
            let piece = l.substring(with: NSRange(location: col, length: end - col))
            let x = g.left + CGFloat(columns(prefix)) * g.charWidth
            let y = g.rowTop + CGFloat(delta(k, r)) * g.lineHeight
            out.append(CGRect(x: x, y: y, width: max(4, CGFloat(columns(piece)) * g.charWidth), height: g.lineHeight))
            pos = lineStarts[k] + end
        }
        return out
    }

    /// The sticky-scroll band at the top of the editor (AX coordinates), if shown.
    static func stickyFrame(in area: AXUIElement) -> CGRect? {
        for c in TextAccess.attr(area, kAXChildrenAttribute) as? [AXUIElement] ?? [] where classes(c).contains("overlayWidgets") {
            for w in TextAccess.attr(c, kAXChildrenAttribute) as? [AXUIElement] ?? [] where classes(w).contains("sticky-widget") {
                return LiveChecker.frame(w)
            }
        }
        return nil
    }

    /// The editor area around the hidden textarea (where the visible lines are), for text runs.
    static func editorArea(of el: AXUIElement) -> AXUIElement? {
        var cur = el
        for _ in 0..<8 {
            guard let p = TextAccess.attr(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
            cur = p as! AXUIElement
            if let f = LiveChecker.frame(cur), f.width > 200, f.height > 60 { return cur }
        }
        return nil
    }
}
