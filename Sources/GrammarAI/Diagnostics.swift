import AppKit
import ApplicationServices

/// A privacy-safe report about the focused text field of the frontmost app: what accessibility exposes and
/// what Nib decides. It never contains text: values appear only as lengths, and titles, descriptions,
/// placeholders and selections are never read.
enum Diagnostics {
    static func report() -> String {
        var lines: [String] = []
        func add(_ s: String) { lines.append(s) }
        let s = Settings.shared
        let info = Bundle.main.infoDictionary
        add("Nib diagnostics \(ISO8601DateFormatter().string(from: Date()))")
        add("Nib \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) at \(Bundle.main.bundlePath)")
        add("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        add("accessibility allowed for this process: \(AXIsProcessTrusted())")
        add("provider: \(s.provider.rawValue), model: \(s.effectiveModel), configured: \(s.apiKey != nil)")
        add("live checking: \(s.liveChecking), ✨ chip: \(s.showRewriteChip), paused: \(s.isPaused)")

        guard let app = NSWorkspace.shared.frontmostApplication else { add("no frontmost app"); return lines.joined(separator: "\n") }
        let id = app.bundleIdentifier ?? "?"
        add("")
        add("app: \(app.localizedName ?? "?") (\(id)), pid \(app.processIdentifier)")
        add("  bundle: \(app.bundleURL?.path ?? "?")\(app.bundleURL.map { $0.resolvingSymlinksInPath().path != $0.path ? " → \($0.resolvingSymlinksInPath().path)" : "" } ?? "")")
        add("  Electron detected: \(TextAccess.detectElectron(app)) (framework: \(app.bundleURL.map { FileManager.default.fileExists(atPath: $0.resolvingSymlinksInPath().appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false)), "
            + "treated as Electron for underlines: \(TextAccess.isElectron(app))")
        add("  chromium: \(TextAccess.chromiumBundleIDs.contains(id)), "
            + "copy/paste route for ⌥⌥: \(TextAccess.prefersClipboard(app)), code editor (excluded): \(TextAccess.copyLineBundleIDs.contains(id)), "
            + "terminal (blocked): \(TextAccess.blockedBundleIDs.contains(id)), turned off for this app: \(s.liveDisabledApps.contains(id))")
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if TextAccess.isCodeEditor(app) {
            let info = Monaco.fileInfo(app, axApp), verdict = Monaco.proseVerdict(info.name, onDisk: info.onDisk)
            add("  code editor (experimental underlines \(s.allowCodeEditors ? "on" : "off")), file: \(info.name ?? "?") (from the \(info.source)), prose: \(verdict.0 ? "✓" : "✗") \(verdict.1)")
        }
        func flag(_ name: String) -> String {
            var v: AnyObject?
            let e = AXUIElementCopyAttributeValue(axApp, name as CFString, &v)
            return e == .success ? "\(v.map { "\($0)" } ?? "nil")" : "unreadable (\(e.rawValue))"
        }
        add("  before: AXManualAccessibility=\(flag("AXManualAccessibility")), AXEnhancedUserInterface=\(flag("AXEnhancedUserInterface"))")
        TextTarget.enableTree(app, axApp, force: true)
        let hadFocus = TextTarget.focusedRaw(app, axApp) != nil
        // Ask every app for its tree, Electron or not, and report what the call returned.
        let setManual = TextTarget.setManualAccessibility(axApp, pid: app.processIdentifier)
        if TextAccess.chromiumBundleIDs.contains(id) {
            let e = AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            add("  set AXEnhancedUserInterface=true (Chromium) → AXError \(e.rawValue)")
        }
        usleep(800_000) // let Chromium/Electron build their tree
        add("  focused element before asking: \(hadFocus ? "yes" : "NONE")")
        add("  set AXManualAccessibility=true → AXError \(setManual.rawValue)\(setManual == .success ? " (success)" : setManual == .attributeUnsupported ? " (unsupported: not Electron)" : "")")
        add("  after enabling: AXManualAccessibility=\(flag("AXManualAccessibility")), AXEnhancedUserInterface=\(flag("AXEnhancedUserInterface"))")

        guard let f = TextTarget.focused(app, axApp) else {
            add("focused element: NONE (the app isn't exposing it)")
            add(""); add("live checking, step by step (stops at the first ✗):")
            for st in LiveChecker.shared.evaluate(app).steps { add("  \(st.ok ? "✓" : "✗") \(st.name)\(st.detail.isEmpty ? "" : " — \(st.detail)")") }
            add(""); add(recentLog(app)); return lines.joined(separator: "\n")
        }
        add("")
        add("focused element:"); describe(f, into: &lines)
        let (found, why) = TextTarget.resolve(app, axApp)
        if let found, !CFEqual(found.element, f) { add("text field used (\(found.via)):"); describe(found.element, into: &lines) }
        add("")
        add("live checking, step by step (stops at the first ✗):")
        let (steps, target, _) = LiveChecker.shared.evaluate(app)
        for st in steps { add("  \(st.ok ? "✓" : "✗") \(st.name)\(st.detail.isEmpty ? "" : " — \(st.detail)")") }
        if let target, steps.allSatisfy(\.ok) {
            let len = (target.text as NSString).length
            if len == 0 { add("  … text positions: can't tell yet (empty field; type something and run again)") }
            else if let b = LiveChecker.bounds(target.element, NSRange(location: 0, length: 1)) {
                let via = LiveChecker.plainBounds(target.element, NSRange(location: 0, length: 1)) != nil ? "AXBoundsForRange" : "text markers"
                add("  ✓ text positions available via \(via) (\(Int(b.width))×\(Int(b.height))) — underlines can be drawn")
            } else {
                add("  ✗ text positions available — the app doesn't report where its text is: no underlines (⌥⌥ and ⇧⇧ still work)")
            }
        }
        if let target = found, TextAccess.isCodeEditor(app) {
            let main = Monaco.isMainEditor(target.element)
            add("  Monaco: \(main ? "main editor (hidden textarea)" : "side box / ordinary field"), editor area found: \(Monaco.editorArea(of: target.element) != nil), "
                + "view-lines found: \(Monaco.editorArea(of: target.element).flatMap(Monaco.viewLines(in:)) != nil), "
                + "visible text runs: \(TextMarkers.runCount(target.element)), text lines in the field: \(target.text.components(separatedBy: "\n").count)")
            if main, let m = TextMarkers.lineMatch(target.element) {
                add("  Monaco lines: textarea (AXValue) \(m.textLines), visible lines \(m.visualLines), matched by content \(m.matchedLines)"
                    + (m.visualLines > 0 && m.matchedLines == 0 ? " — none matched: no underlines (the visible lines aren't in the textarea's text)" : ""))
            }
        }
        add("  last position method used: \(TextMarkers.lastMethod)")
        add("summary: " + decision(app, found: found, why: why))
        let live = LiveChecker.shared.debugMarks.prefix(3)
        if !live.isEmpty {
            add("current underlines (first \(live.count), screen rects, bottom-left based):")
            for (r, rects) in live {
                add("  range \(r.location)+\(r.length): " + rects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" }.joined(separator: " | "))
            }
            if let f = found.flatMap({ LiveChecker.frame($0.element) }).map(TextAccess.flip) {
                add("  field frame (bottom-left based): \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))")
            }
        }
        add("✨ chip: " + (found == nil ? "no (no text field)" :
            LiveChecker.selectedRange(found!.element).map { $0.length > 0 ? "selection of \($0.length) characters; needs bounds (above)" : "no selection" } ?? "no selection range"))
        add("")
        add(recentLog(app))
        return lines.joined(separator: "\n")
    }

    private static func describe(_ el: AXUIElement, into lines: inout [String]) {
        func add(_ s: String) { lines.append("  " + s) }
        let role = TextAccess.attr(el, kAXRoleAttribute) as? String ?? "?"
        let subrole = TextAccess.attr(el, kAXSubroleAttribute) as? String ?? "-"
        add("role: \(role), subrole: \(subrole)")
        var names: CFArray?
        AXUIElementCopyAttributeNames(el, &names)
        add("attributes: \(((names as? [String]) ?? []).sorted().joined(separator: ", "))")
        var pnames: CFArray?
        AXUIElementCopyParameterizedAttributeNames(el, &pnames)
        add("parameterised: \(((pnames as? [String]) ?? []).sorted().joined(separator: ", "))")
        var v: AnyObject?
        let ve = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
        if ve == .success { add("AXValue: " + ((v as? String).map { "string, \(($0 as NSString).length) characters" } ?? "not a string (\(v.map { String(describing: type(of: $0)) } ?? "nil"))")) }
        else { add("AXValue: unreadable (\(ve.rawValue))") }
        add("AXNumberOfCharacters: \(TextTarget.number(el, kAXNumberOfCharactersAttribute).map(String.init) ?? "n/a")")
        if let t = TextTarget.text(el) { add("text readable via \(t.1): \((t.0 as NSString).length) characters") } else { add("text readable: no") }
        add("AXValue settable: \(TextAccess.isSettable(el, kAXValueAttribute)), AXSelectedText settable: \(TextAccess.isSettable(el, kAXSelectedTextAttribute))")
        let sel = LiveChecker.selectedRange(el)
        add("AXSelectedTextRange: \(sel.map { "location \($0.location), length \($0.length)" } ?? "n/a")")
        let frame = LiveChecker.frame(el)
        add("frame: \(frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "n/a")")
        let probe = NSRange(location: max(0, (sel?.location ?? 1) - 1), length: 1)
        if (TextTarget.text(el).map { ($0.0 as NSString).length } ?? 0) == 0 {
            add("AXBoundsForRange: n/a (empty field; type something and run again)")
        } else if let b = LiveChecker.plainBounds(el, probe) {
            let sane = frame.map { $0.insetBy(dx: -50, dy: -50).contains(CGPoint(x: b.midX, y: b.midY)) } ?? false
            add("AXBoundsForRange: \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height)), inside the field: \(sane)")
        } else {
            add("AXBoundsForRange: not available")
        }
        if (TextTarget.text(el).map { ($0.0 as NSString).length } ?? 0) > 0 {
            if !TextMarkers.supported(el) {
                add("text positions via text markers: not supported by this field")
            } else if let b = TextMarkers.bounds(el, probe, fieldFrame: frame) {
                let inside = frame.map { $0.insetBy(dx: -50, dy: -50).contains(CGPoint(x: b.midX, y: b.midY)) } ?? false
                add("text positions via text markers: ✓ \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height)), inside the field: \(inside)")
            } else {
                add("text positions via text markers: ✗ (supported, but no usable rect)")
            }
        }
        if TextMarkers.supported(el), let len = TextTarget.text(el).map({ ($0.0 as NSString).length }), len > 0 {
            // Numbers only: what each position method returns for three sample ranges.
            let samples = [NSRange(location: 0, length: min(4, len)), NSRange(location: len / 2, length: min(3, len - len / 2)),
                           NSRange(location: max(0, len - 3), length: min(3, len))]
            for r in samples where r.length > 0 { add("text-marker " + TextMarkers.describe(el, r, fieldFrame: frame)) }
        }
        add("visible frame for underlines: \(LiveChecker.visibleFrame(el).map { "\(Int($0.width))×\(Int($0.height))" } ?? "none")")
    }

    private static func decision(_ app: NSRunningApplication, found: TextTarget.Found?, why: String) -> String {
        let s = Settings.shared, id = app.bundleIdentifier ?? ""
        if !s.liveChecking { return "skipped: live checking is off" }
        if s.isPaused { return "skipped: Nib is paused" }
        if !AXIsProcessTrusted() { return "skipped: accessibility not allowed for this process" }
        if s.apiKey == nil { return "skipped: no API key" }
        if TextAccess.blockedBundleIDs.contains(id) { return "skipped: terminal" }
        if s.liveDisabledApps.contains(id) { return "skipped: turned off for this app" }
        if TextAccess.prefersClipboard(app) && !TextAccess.chromiumBundleIDs.contains(id) && !TextAccess.isElectron(app) {
            return "skipped: app excluded from underlines (code editor / Firefox)"
        }
        guard let found else { return "skipped: \(why)" }
        let len = (found.text as NSString).length
        if len > TextAccess.maxLength { return "skipped: text too long" }
        if len == 0 { return "would check once there's text (field found, \(found.via))" }
        if LiveChecker.bounds(found.element, NSRange(location: 0, length: 1)) == nil { return "found the field (\(found.via)), but no text positions: no underlines (⌥⌥ still works)" }
        return "would check and underline (\(found.via))"
    }

    private static func recentLog(_ app: NSRunningApplication) -> String {
        let name = app.localizedName ?? "\u{0}", id = app.bundleIdentifier ?? "\u{0}"
        let all = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let relevant = all.split(separator: "\n").filter { $0.contains("live:") && ($0.contains(name) || $0.contains(id)) }.suffix(20)
        return "recent live log lines for this app (\(relevant.count)):\n" + (relevant.isEmpty ? "  (none)" : relevant.map { "  " + $0 }.joined(separator: "\n"))
    }

    /// `--probe-app <bundle id>`: walks the app's windows without focusing anything and reports every editable
    /// field: how its text and positions are exposed (lengths only, no text).
    static func probe(bundleID: String) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return "\(bundleID) isn't running" }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        TextTarget.enableTree(app, axApp, force: true)
        usleep(800_000)
        var out = ["probe \(app.localizedName ?? "?") (\(bundleID)), electron: \(TextAccess.isElectron(app)), chromium: \(TextAccess.chromiumBundleIDs.contains(bundleID))"]
        let windows = TextAccess.attr(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
        out.append("windows: \(windows.count)")
        var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
        var seen = 0, fields = 0, staticTexts = 0
        while !queue.isEmpty, seen < 20000, fields < 12 {
            let (el, depth) = queue.removeFirst()
            seen += 1
            let role = TextAccess.attr(el, kAXRoleAttribute) as? String ?? ""
            if role == "AXStaticText" { staticTexts += 1 }
            let editable = TextTarget.textRoles.contains(role)
            if editable && !TextTarget.isSecure(el) {
                fields += 1
                let t = TextTarget.text(el)
                let len = t.map { ($0.0 as NSString).length } ?? -1
                var b = "n/a (empty)"
                if len > 0 { b = LiveChecker.bounds(el, NSRange(location: 0, length: 1)).map { "\(Int($0.width))×\(Int($0.height)) at \(Int($0.minX)),\(Int($0.minY))" } ?? "NOT available" }
                out.append("  field \(fields): frame \(LiveChecker.frame(el).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "n/a"), focused \((TextAccess.attr(el, kAXFocusedAttribute) as? Bool) ?? false), role \(role), subrole \(TextAccess.attr(el, kAXSubroleAttribute) as? String ?? "-"), text via \(t?.1 ?? "NONE") (\(max(len, 0)) chars), selection range: \(LiveChecker.selectedRange(el) != nil), bounds: \(b), text capable: \(TextTarget.isTextCapable(el))")
            }
            guard depth < 40, let kids = TextAccess.attr(el, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: kids.map { ($0, depth + 1) })
        }
        out.append("elements visited: \(seen), text fields: \(fields), static texts: \(staticTexts)")
        return out.joined(separator: "\n")
    }

    /// Menu: count down so the user can click into the field, then copy the report.
    static func copyAfterCountdown() {
        var n = 5
        func tick() {
            if n > 0 {
                HUD.shared.show("Click into the text field you want checked… \(n)", style: .info, duration: 1.2)
                n -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick() }
            } else {
                let r = report()
                TextAccess.copyToClipboard(r)
                log("diagnostics copied")
                HUD.shared.show("Diagnostics copied to the clipboard (no text from your apps). Paste them to whoever is helping you.", style: .success, duration: 4)
            }
        }
        tick()
    }
}
