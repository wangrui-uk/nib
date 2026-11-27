import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// `open -n build/GrammarAI.app --args --e2e DIR`: drives real apps on throwaway documents and
/// writes results to DIR/results.txt. Runs inside the app so it uses the app's Accessibility grant.
enum E2E {
    static let sample = "i has went to the store yesterday and buyed three apple, they was delicious."

    struct Case {
        let name: String
        let bundleID: String
        let file: URL
        var selectText: String? = nil
    }

    static func prepare(_ dir: URL) -> [Case] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rich = NSMutableAttributedString(string: "i has went to the ", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        rich.append(NSAttributedString(string: "store", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
        rich.append(NSAttributedString(string: " yesterday and buyed three apple, they was delicious.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        let rtf = dir.appendingPathComponent("GrammarAI Test rich.rtf")
        try? rich.rtf(from: NSRange(location: 0, length: rich.length))?.write(to: rtf)
        let rtfSel = dir.appendingPathComponent("GrammarAI Test selection.rtf")
        try? rich.rtf(from: NSRange(location: 0, length: rich.length))?.write(to: rtfSel)
        func page(_ name: String, _ body: String) -> URL {
            let url = dir.appendingPathComponent("\(name).html")
            try? """
            <!doctype html><html><head><title>GrammarAI Test \(name)</title></head><body>\(body)
            <script>const f=document.getElementById('f');f.focus();
            if(f.setSelectionRange){f.setSelectionRange(f.value.length,f.value.length)}</script></body></html>
            """.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let ta = page("textarea", "<textarea id=f rows=4 cols=40>\(sample)</textarea>")
        let input = page("input", "<input id=f size=80 value=\"\(sample)\">")
        let ce = page("contenteditable", "<div id=f contenteditable style='border:1px solid #999;padding:6px'>i has went to the <b>store</b> yesterday and buyed three apple, they was delicious.</div>")
        return [
            Case(name: "TextEdit rich text (whole doc)", bundleID: "com.apple.TextEdit", file: rtf),
            Case(name: "TextEdit rich text (selection)", bundleID: "com.apple.TextEdit", file: rtfSel, selectText: "buyed three apple"),
            Case(name: "Safari <textarea>", bundleID: "com.apple.Safari", file: ta),
            Case(name: "Safari <input>", bundleID: "com.apple.Safari", file: input),
            Case(name: "Safari contenteditable", bundleID: "com.apple.Safari", file: ce),
            Case(name: "Chrome <textarea>", bundleID: "com.google.Chrome", file: ta),
            Case(name: "Chrome <input>", bundleID: "com.google.Chrome", file: input),
            Case(name: "Chrome contenteditable", bundleID: "com.google.Chrome", file: ce),
        ]
    }

    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func frontmost(_ id: String) -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == id else { return nil }
        return app
    }

    static func windowTitle(_ app: NSRunningApplication) -> String {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = TextAccess.attr(axApp, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return "" }
        return TextAccess.attr(w as! AXUIElement, kAXTitleAttribute) as? String ?? ""
    }

    /// The field's text: AX value, else a ⌘A ⌘C copy.
    static func readField(_ app: NSRunningApplication) -> String {
        // Never copy from whatever else might be in front.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return "<focus moved; not read>" }
        if let el = TextAccess.focusedElement(of: app), let v = TextAccess.attr(el, kAXValueAttribute) as? String, !v.isEmpty { return v }
        guard windowTitle(app).contains("GrammarAI Test") else { return "<not the test window; not read>" }
        return (try? TextAccess.clipboardCapture(selectAllFirst: true)) ?? "<unreadable>"
    }

    /// Finds the test field (DOM id "f") in the front window and clicks into it.
    static func focusTestField(_ app: NSRunningApplication) -> Bool {
        _ = TextAccess.focusedElement(of: app) // turns on Chromium's AX tree
        usleep(500_000)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = TextAccess.attr(axApp, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return false }
        var queue: [(AXUIElement, Int)] = [(w as! AXUIElement, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if TextAccess.attr(el, "AXDOMIdentifier") as? String == "f" {
                AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                var pos = CGPoint.zero, size = CGSize.zero
                if let p = TextAccess.attr(el, kAXPositionAttribute), let s = TextAccess.attr(el, kAXSizeAttribute),
                   AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(s as! AXValue, .cgSize, &size) {
                    let pt = CGPoint(x: pos.x + size.width - 12, y: pos.y + size.height / 2)
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                    }
                }
                return true
            }
            guard depth < 40, let kids = TextAccess.attr(el, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: kids.map { ($0, depth + 1) })
        }
        return false
    }

    static func select(_ text: String, in app: NSRunningApplication) -> Bool {
        guard let el = TextAccess.focusedElement(of: app), let v = TextAccess.attr(el, kAXValueAttribute) as? String else { return false }
        let r = (v as NSString).range(of: text)
        guard r.location != NSNotFound else { return false }
        var cf = CFRange(location: r.location, length: r.length)
        guard let rv = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv) == .success
    }

    static func fixed(_ s: String) -> Bool {
        !s.contains("buyed") && s.contains("bought") && !s.contains("i has")
    }

    @MainActor
    static func run(_ delegate: AppDelegate, dir: URL) async {
        // The test copy shares the user's settings: never save anything, and run even if Nib is paused (⌘⌘).
        Settings.shared.persist = false
        Settings.shared.pausedUntil = nil
        Settings.shared.liveChecking = true
        var out = "Nib end-to-end run \(Date())\naccessibility=\(AXIsProcessTrusted())\n\n"
        func record(_ line: String) {
            out += line + "\n"
            try? out.write(to: dir.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        }
        if CommandLine.arguments.contains("--attach") {
            // Test whatever field is in front (e.g. a Cursor window opened by the test script).
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let app = NSWorkspace.shared.frontmostApplication else { record("no front app"); record("DONE"); exit(0) }
            record("front: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")), code editor underlines: \(Settings.shared.allowCodeEditors)")
            if CommandLine.arguments.contains("--prep-editor") {
                // VS Code: dismiss a notification (esc), then focus the first editor group (⌘1).
                TextAccess.sendKey(kVK_Escape, command: false); await sleep(0.4)
                TextAccess.sendKey(kVK_ANSI_1, command: true); await sleep(1.0)
                if CommandLine.arguments.contains("--first-tab") {
                    // ⌃1: the group's first editor (the file under test, not an Untitled left by an earlier run).
                    let src = CGEventSource(stateID: .hidSystemState)
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_1), keyDown: down)
                        e?.flags = .maskControl; e?.post(tap: .cghidEventTap)
                    }
                    await sleep(1.2)
                }
                // Click into the text: a little inside the editor area's top-left, on the first lines.
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                if let f = TextTarget.focusedRaw(app, axApp).flatMap({ LiveChecker.frame($0) }) {
                    let pt = CGPoint(x: f.minX + 160, y: f.minY + 50)
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                    }
                    record("  clicked into the editor at \(Int(pt.x)),\(Int(pt.y))")
                    await sleep(1.0)
                }
                if CommandLine.arguments.contains("--type-probe") {
                    // Typing guarantees Monaco's own text area has keyboard focus: "x", then delete it.
                    TextAccess.sendKey(kVK_ANSI_X, command: false); await sleep(0.4)
                    TextAccess.sendKey(kVK_Delete, command: false); await sleep(1.0)
                    if let f = TextTarget.focusedRaw(app, axApp) {
                        record("  after typing, focused: \(TextAccess.attr(f, kAXRoleAttribute) as? String ?? "?"), frame \(LiveChecker.frame(f).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "n/a"), value \((TextAccess.attr(f, kAXValueAttribute) as? String).map { "\(($0 as NSString).length) chars" } ?? "none"), description length \((TextAccess.attr(f, kAXDescriptionAttribute) as? String)?.count ?? 0)")
                    }
                }
            }
            // Live checking asks Electron for its tree once; give it a moment to rebuild before looking.
            _ = LiveChecker.shared.evaluate(app)
            await sleep(4)
            if CommandLine.arguments.contains("--dump") {
                if CommandLine.arguments.contains("--prev-tab") {
                    let src = CGEventSource(stateID: .hidSystemState)
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: down)
                        e?.flags = [.maskCommand, .maskAlternate]; e?.post(tap: .cghidEventTap)
                    }
                    await sleep(1.5)
                }
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                guard let (t, _) = Optional(TextTarget.resolve(app, axApp)), let t else { record("no target"); record("DONE"); exit(0) }
                let el = t.element
                func fr(_ e: AXUIElement) -> String { LiveChecker.frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-" }
                func desc(_ e: AXUIElement) -> String {
                    let v = TextAccess.attr(e, kAXValueAttribute) as? String
                    return "\(TextAccess.attr(e, kAXRoleAttribute) as? String ?? "?") [\(Monaco.classes(e).joined(separator: " "))] \(fr(e)) value:\(v.map { String($0.prefix(40)).debugDescription } ?? "-")"
                }
                record("target: \(desc(el)) mainEditor:\(Monaco.isMainEditor(el))")
                let kids = TextAccess.attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
                record("textarea children: \(kids.count)")
                for k in kids.prefix(5) { record("  " + desc(k)) }
                var cur = el
                for i in 0..<10 {
                    guard let p = TextAccess.attr(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
                    cur = p as! AXUIElement
                    record("parent \(i + 1): " + desc(cur) + " kids:\((TextAccess.attr(cur, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0)")
                }
                if let area = Monaco.editorArea(of: el) {
                    record("editorArea: " + desc(area))
                    var queue: [(AXUIElement, Int)] = [(area, 0)]; var n = 0
                    while !queue.isEmpty, n < 120 {
                        let (c, d) = queue.removeFirst(); n += 1
                        record(String(repeating: "  ", count: d) + desc(c))
                        if d < 7, let ks = TextAccess.attr(c, kAXChildrenAttribute) as? [AXUIElement] { queue.insert(contentsOf: ks.prefix(6).map { ($0, d + 1) }, at: 0) }
                    }
                }
                record("DONE"); exit(0)
            }
            func phase(_ label: String) async {
                LiveChecker.shared.clear()
                await sleep(0.5)
                let (steps, target, stage) = LiveChecker.shared.evaluate(app)
                record("[\(label)]")
                for st in steps { record("  \(st.ok ? "✓" : "✗") \(st.name)\(st.detail.isEmpty ? "" : " — \(st.detail)")") }
                if let t = target {
                    record("  field: \(t.role) via \(t.via), \((t.text as NSString).length) chars, \(t.text.components(separatedBy: "\n").count) lines, main editor: \(Monaco.isMainEditor(t.element)), runs: \(TextMarkers.runCount(t.element))")
                }
                let t0 = Date()
                while LiveChecker.shared.marks.isEmpty && Date().timeIntervalSince(t0) < 20 { await sleep(0.3) }
                await sleep(0.8)
                let marks = LiveChecker.shared.marks
                let field = target.flatMap { LiveChecker.visibleFrame($0.element) }
                let rects = marks.flatMap(\.rects)
                let sane = field.map { f in !rects.isEmpty && rects.allSatisfy { $0.width < f.width * 0.9 && $0.height < 40 && f.insetBy(dx: -4, dy: -4).contains(NSPoint(x: $0.midX, y: $0.midY)) } } ?? false
                record("\(marks.isEmpty ? "NO UNDERLINES" : sane ? "PASS" : "WRONG POSITIONS") — \(marks.count) underlines after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, stage '\(stage)', method \(TextMarkers.lastMethod)")
                if let el = target?.element, let m = TextMarkers.lineMatch(el) {
                    record("  Monaco lines: textarea \(m.textLines), visible \(m.visualLines), matched \(m.matchedLines)")
                }
                if let t = target {
                    let ns = t.text as NSString
                    for mk in marks.prefix(6) {
                        let lineNo = ns.substring(to: mk.range.location).components(separatedBy: "\n").count
                        let word = ns.substring(with: mk.range)
                        record("  mark \(word.debugDescription) on textarea line \(lineNo): " + mk.rects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" }.joined(separator: " | "))
                    }
                }
                record("SCREENSHOT \(label)")
                await sleep(3) // the test script takes a screenshot now
                if let m = marks.first, let el = target?.element, CommandLine.arguments.contains("--apply") {
                    let before = TextTarget.text(el)?.0 ?? ""
                    LiveChecker.shared.apply(m)
                    await sleep(1.2)
                    let after = TextTarget.text(el)?.0 ?? ""
                    let want = (before as NSString).replacingCharacters(in: m.range, with: m.issue.fix)
                    record("  apply \(m.issue.text.debugDescription) → \(m.issue.fix.debugDescription) on line \((before as NSString).substring(to: m.range.location).components(separatedBy: "\n").count): \(after == want ? "ok (read back exactly)" : after == before ? "NOT applied (text unchanged)" : "CHANGED DIFFERENTLY (\((before as NSString).length)→\((after as NSString).length) chars)")")
                }
            }
            await phase("top of file")
            if CommandLine.arguments.contains("--scroll-test") {
                let key = CommandLine.arguments.contains("--scroll-up") ? kVK_PageUp : kVK_PageDown
                for _ in 0..<2 { TextAccess.sendKey(key, command: false); await sleep(0.3) }
                await sleep(1.5)
                await phase("after scrolling (2× \(key == kVK_PageUp ? "Page Up" : "Page Down"))")
            }
            if CommandLine.arguments.contains("--untitled-test") {
                TextAccess.sendKey(kVK_ANSI_N, command: true); await sleep(1.5)
                let src = CGEventSource(stateID: .hidSystemState)
                let chars = Array(("She go to the shops yesterday and buyed three apple.\n\nThey was very tasty and we eats them all." as NSString).utf16Array)
                for chunk in stride(from: 0, to: chars.count, by: 16) {
                    var c = Array(chars[chunk..<min(chars.count, chunk + 16)])
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                        e?.keyboardSetUnicodeString(stringLength: c.count, unicodeString: &c)
                        e?.post(tap: .cghidEventTap)
                    }
                    await sleep(0.08)
                }
                await sleep(2)
                await phase("Untitled document")
            }
            record("DONE")
            exit(0)
        }
        var cases = prepare(dir)
        if let i = CommandLine.arguments.firstIndex(of: "--only"), i + 1 < CommandLine.arguments.count {
            let words = CommandLine.arguments[i + 1].lowercased().split(separator: ",")
            cases = cases.filter { c in words.contains { c.name.lowercased().contains($0) } }
        }
        for c in cases {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.bundleID) else {
                record("SKIP \(c.name): app not installed"); continue
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try? await NSWorkspace.shared.open([c.file], withApplicationAt: appURL, configuration: cfg)
            await sleep(3.5)
            NSRunningApplication.runningApplications(withBundleIdentifier: c.bundleID).first?.activate()
            await sleep(0.8)
            guard let app = frontmost(c.bundleID), windowTitle(app).contains("GrammarAI Test") else {
                record("SKIP \(c.name): couldn't bring the test window to the front (front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), title: \(NSWorkspace.shared.frontmostApplication.map(windowTitle) ?? ""))")
                continue
            }
            if c.file.pathExtension == "html", !focusTestField(app) { record("NOTE \(c.name): test field not found via AX") }
            await sleep(0.5)
            if let sel = c.selectText, !select(sel, in: app) { record("NOTE \(c.name): couldn't select '\(sel)' via AX") }
            await sleep(0.3)

            if NSApp.isActive { record("NOTE \(c.name): Nib was active before correcting") }
            if CommandLine.arguments.contains("--live") {
                // Live checking: wait for underlines, then apply the first one.
                let t0 = Date()
                while LiveChecker.shared.marks.isEmpty && Date().timeIntervalSince(t0) < 12 { await sleep(0.2) }
                let marks = LiveChecker.shared.marks
                let support = LiveChecker.shared.support[c.bundleID] ?? "-"
                if marks.isEmpty, let el = TextTarget.focusedRaw(app, AXUIElementCreateApplication(app.processIdentifier)) {
                    let (t, why) = TextTarget.resolve(app, AXUIElementCreateApplication(app.processIdentifier))
                    let fe = t?.element ?? el
                    let len = t.map { ($0.text as NSString).length } ?? 0
                    record("     field: \(t?.role ?? (TextAccess.attr(el, kAXRoleAttribute) as? String ?? "?")) via \(t?.via ?? why), \(len) chars, frame \(LiveChecker.frame(fe).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "n/a"), markers supported \(TextMarkers.supported(fe))")
                    if len > 4 {
                        record("     AXBoundsForRange(0,4): \(LiveChecker.plainBounds(fe, NSRange(location: 0, length: 4)).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "none")")
                        if TextMarkers.supported(fe) { record("     text-marker " + TextMarkers.describe(fe, NSRange(location: 0, length: 4), fieldFrame: LiveChecker.frame(fe))) }
                    }
                }
                guard let m = marks.first else {
                    record("\(support == "no positions" ? "NO-UNDERLINES" : "FAIL") \(c.name) — live: 0 marks after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s (support: \(support))")
                    continue
                }
                // Positions: every underline rect should be word-sized, inside the field.
                let field = TextTarget.focusedRaw(app, AXUIElementCreateApplication(app.processIdentifier)).flatMap { LiveChecker.frame($0) }.map(TextAccess.flip)
                let rects = marks.flatMap(\.rects)
                let sane = field.map { f in rects.allSatisfy { $0.width < f.width * 0.9 && $0.height < 40 && f.insetBy(dx: -4, dy: -4).contains(NSPoint(x: $0.midX, y: $0.midY)) } } ?? false
                record("     positions: \(sane ? "word-sized" : "WRONG") — \(rects.prefix(3).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" }.joined(separator: " | ")) in field \(field.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "?")")
                if let el = TextTarget.focusedRaw(app, AXUIElementCreateApplication(app.processIdentifier)) {
                    let f = LiveChecker.frame(el)
                    record("     AXBoundsForRange(first mark): \(LiveChecker.plainBounds(el, m.range).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "none"); field (AX) \(f.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "?")")
                    if TextMarkers.supported(el) { record("     text-marker " + TextMarkers.describe(el, m.range, fieldFrame: f)) }
                }
                let before = readField(app)
                LiveChecker.shared.apply(m)
                await sleep(0.6)
                let after = readField(app)
                let applied = after == (before as NSString).replacingCharacters(in: m.range, with: m.issue.fix)
                record("\(applied ? "PASS" : "FAIL") \(c.name) — live: \(marks.count) underlines after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s; applied \(m.issue.text.debugDescription) → \(m.issue.fix.debugDescription): \(applied ? "ok" : "not applied")")
                if let a = frontmost(c.bundleID), windowTitle(a).contains("GrammarAI Test") {
                    TextAccess.sendKey(kVK_ANSI_W, command: true)
                    await sleep(0.6)
                    if c.bundleID == "com.apple.TextEdit" {
                        let src = CGEventSource(stateID: .hidSystemState)
                        for down in [true, false] {
                            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: down)
                            e?.flags = .maskCommand
                            e?.post(tap: .cghidEventTap)
                        }
                        await sleep(0.4)
                    }
                }
                continue
            }
            delegate.lastRoute = ""
            delegate.lastError = ""
            if CommandLine.arguments.contains("--tap") {
                // Real key events: ⌥ down/up twice, as the hardware would send them.
                let src = CGEventSource(stateID: .hidSystemState)
                for _ in 0..<2 {
                    let down = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: true); down?.type = .flagsChanged; down?.flags = .maskAlternate
                    let up = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: false); up?.type = .flagsChanged; up?.flags = []
                    down?.post(tap: .cghidEventTap); usleep(60_000)
                    up?.post(tap: .cghidEventTap); usleep(90_000)
                }
            } else {
                delegate.correctNow()
            }
            let t0 = Date()
            await sleep(0.6)
            while delegate.isBusy && Date().timeIntervalSince(t0) < 20 { await sleep(0.1) }
            await sleep(1.0)
            guard frontmost(c.bundleID) != nil else {
                record("ABORT \(c.name): focus moved to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") — route: \(delegate.lastRoute) error: \(delegate.lastError)")
                continue
            }
            let after = readField(app)
            let ok = c.selectText == nil ? fixed(after) : (after.contains("bought three apples") && after.contains("i has went"))
            record("\(ok ? "PASS" : "FAIL") \(c.name) — route: \(delegate.lastRoute.isEmpty ? "-" : delegate.lastRoute)\(delegate.lastError.isEmpty ? "" : " — error: \(delegate.lastError)") — \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            record("     after:  \(String(after.prefix(200)).debugDescription)")

            // Undo
            delegate.undoLast()
            await sleep(1.2)
            let undone = readField(app)
            let undoOK = undone.trimmingCharacters(in: .whitespacesAndNewlines) == sample
            record("     undo: \(undoOK ? "PASS" : "FAIL") \(undoOK ? "" : String(undone.prefix(200)).debugDescription)")

            // Close only our own test window/tab.
            if let a = frontmost(c.bundleID), windowTitle(a).contains("GrammarAI Test") {
                TextAccess.sendKey(kVK_ANSI_W, command: true)
                await sleep(0.6)
                // TextEdit may ask to save: "Don't Save" is ⌘⌫.
                if c.bundleID == "com.apple.TextEdit" {
                    let src = CGEventSource(stateID: .hidSystemState)
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: down)
                        e?.flags = .maskCommand
                        e?.post(tap: .cghidEventTap)
                    }
                    await sleep(0.4)
                }
            }
        }
        record("\nDONE")
        exit(0)
    }
}

private extension NSString {
    var utf16Array: [UniChar] { (0..<length).map { character(at: $0) } }
}
