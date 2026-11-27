import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Where the text came from, so the correction goes back the same way.
struct Capture {
    enum Method: String { case axSelection = "AX selection", axWholeValue = "AX whole field", clipboard = "clipboard", inApp = "in-app" }
    let method: Method
    let text: String
    let pid: pid_t
    var appName: String = ""
    var element: AXUIElement? = nil
    /// The field's full value at capture time (AX methods), for verifying writes.
    var fieldValue: String? = nil
    /// Screen rect (Cocoa coordinates) of the caret/selection or field, for placing the HUD.
    var anchor: NSRect? = nil
    var textView: NSTextView? = nil
    var range: NSRange? = nil
    /// The whole field on screen (Cocoa coordinates), when known.
    var fieldFrame: NSRect? = nil
    /// UTF-16 offset of `text` inside the field (AX methods), when known.
    var base: Int? = nil
}

struct LastCorrection {
    let capture: Capture
    let original: String
    let corrected: String
    let via: String
    var at = Date()
}

enum CaptureError: LocalizedError {
    case noSelection, noFocus, secure, noText, tooLong(Int), focusChanged, terminal, textChanged, nothingToUndo, undoClipboard, partial, attachment, pasteNotApplied
    var errorDescription: String? {
        switch self {
        case .noSelection: return "Select the text to rewrite first."
        case .noFocus: return "Click into a text box first."
        case .secure: return "Password fields are skipped."
        case .noText: return "No text to correct. Click into a text field first."
        case .tooLong(let n): return "That's \(n) characters; the limit is \(TextAccess.maxLength). Select a smaller part."
        case .terminal: return "Not available in terminals: pasting there could run a command."
        case .focusChanged: return "You switched apps, so nothing was replaced. The correction is on the clipboard."
        case .textChanged: return "The text changed while correcting, so it was left alone."
        case .pasteNotApplied: return "Couldn't apply the correction here. It's on the clipboard; paste it with ⌘V."
        case .partial: return "Some fixes may not have been applied. Check the text (⌘Z undoes them)."
        case .attachment: return "The correction dropped an image or attachment, so nothing was changed."
        case .nothingToUndo: return "Nothing to undo."
        case .undoClipboard: return "Couldn't undo in place. The original text is on the clipboard."
        }
    }
}

enum TextAccess {
    static let maxLength = 20000

    /// Apps where select-all + paste could do harm (a paste can run a shell command).
    static let blockedBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]
    /// Browsers whose AX writes are unreliable: go straight to copy/paste.
    static let clipboardBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen",
    ]
    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    /// Editors where ⌘C with no selection copies the current line.
    static let copyLineBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.sublimetext.4", "com.jetbrains.intellij",
    ]
    private static var electronCache: [String: Bool] = [:]

    /// Electron, detected from the app bundle: the "Electron Framework.framework", or Electron's
    /// "<App> Helper (Renderer).app" next to it. (Info.plist's ElectronAsarIntegrity isn't used: some
    /// native apps carry it.) The path is resolved (symlinks) and, if NSRunningApplication has no bundle URL,
    /// derived from the executable. Cached per bundle id.
    static func detectElectron(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        if let cached = electronCache[id] { return cached }
        var candidates: [URL] = []
        if let u = app.bundleURL { candidates.append(u) }
        if let exe = app.executableURL { candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let found = candidates.contains { isElectronBundle($0) }
        electronCache[id] = found
        return found
    }

    static func isElectronBundle(_ url: URL) -> Bool {
        let fw = url.resolvingSymlinksInPath().appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        if fm.fileExists(atPath: fw.appendingPathComponent("Electron Framework.framework").path) { return true }
        let items = (try? fm.contentsOfDirectory(atPath: fw.path)) ?? []
        return items.contains { $0.hasSuffix(" Helper (Renderer).app") }
    }

    /// Electron and eligible for underlines (code editors are excluded on purpose).
    static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, !clipboardBundleIDs.contains(id) else { return false }
        if copyLineBundleIDs.contains(id) && !Settings.shared.allowCodeEditors { return false }
        return detectElectron(app)
    }

    /// VS Code, Cursor, Windsurf… (Monaco-based code editors).
    static func isCodeEditor(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map { copyLineBundleIDs.contains($0) && $0 != "com.sublimetext.4" && $0 != "com.jetbrains.intellij" } ?? false
    }

    static func prefersClipboard(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        if clipboardBundleIDs.contains(id) || copyLineBundleIDs.contains(id) { return true }
        return detectElectron(app)
    }

    // MARK: Accessibility helpers

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }

    static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium/Electron only build their AX tree when asked to.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Chromium browsers build their web-content AX tree only for assistive tech that sets this.
        if let id = app.bundleIdentifier, chromiumBundleIDs.contains(id) {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        for source in [axApp, AXUIElementCreateSystemWide()] {
            if let f = attr(source, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
                return (f as! AXUIElement)
            }
        }
        return nil
    }

    /// AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
    static func flip(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func anchor(for el: AXUIElement) -> NSRect? {
        if let range = attr(el, kAXSelectedTextRangeAttribute) {
            var out: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &out) == .success,
               let v = out, CFGetTypeID(v) == AXValueGetTypeID() {
                var r = CGRect.zero
                if AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 0, r.height < 400, r.minX > -10000 { return flip(r) }
            }
        }
        var pos = CGPoint.zero, size = CGSize.zero
        if let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
           CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
           AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(s as! AXValue, .cgSize, &size),
           size.height > 0, size.height < 300 {
            return flip(CGRect(origin: pos, size: size))
        }
        return nil
    }

    // MARK: Capture

    /// Text in one of Nib's own windows (the onboarding sample box).
    static func captureInApp(selectionOnly: Bool = false) throws -> Capture {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable, !tv.isFieldEditor else {
            throw CaptureError.noFocus
        }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        if selectionOnly && sel.length == 0 { throw CaptureError.noSelection }
        let range = sel.length > 0 ? sel : NSRange(location: 0, length: ns.length)
        let text = ns.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.noText }
        let rect = tv.firstRect(forCharacterRange: range, actualRange: nil)
        return Capture(method: .inApp, text: text, pid: getpid(), appName: "Nib", fieldValue: tv.string,
                       anchor: rect == .zero ? nil : rect, textView: tv, range: range)
    }

    static func capture(selectionOnly: Bool = false) throws -> Capture {
        // Capturing may select (⌘A, AX ranges): that selection is Nib's, not the user's.
        Surfaces.shared.touched()
        defer { Surfaces.shared.touched() }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw CaptureError.noFocus }
        if let id = app.bundleIdentifier, blockedBundleIDs.contains(id) { throw CaptureError.terminal }
        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "app"
        waitForModifierRelease()

        let el = focusedElement(of: app)
        let anchorRect = el.flatMap { anchor(for: $0) }
        let fieldRect = el.flatMap { LiveChecker.frame($0) }.map(flip)
        var axSelection: String?
        if let el {
            let role = attr(el, kAXRoleAttribute) as? String
            let subrole = attr(el, kAXSubroleAttribute) as? String
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" { throw CaptureError.secure }
            axSelection = attr(el, kAXSelectedTextAttribute) as? String
            if !prefersClipboard(app) {
                let value = attr(el, kAXValueAttribute) as? String
                if let sel = axSelection, !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var base: Int?
                    if let rv = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(rv) == AXValueGetTypeID() {
                        var r = CFRange()
                        if AXValueGetValue(rv as! AXValue, .cfRange, &r), let value,
                           r.location >= 0, r.location + r.length <= (value as NSString).length,
                           (value as NSString).substring(with: NSRange(location: r.location, length: r.length)) == sel {
                            base = r.location
                        }
                    }
                    return withField(fieldRect, Capture(method: .axSelection, text: sel, pid: pid, appName: name, element: el, fieldValue: value, anchor: anchorRect, base: base))
                }
                if selectionOnly { throw CaptureError.noSelection }
                if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   isSettable(el, kAXValueAttribute) || isSettable(el, kAXSelectedTextAttribute) {
                    return withField(fieldRect, Capture(method: .axWholeValue, text: value, pid: pid, appName: name, element: el, fieldValue: value, anchor: anchorRect, base: 0))
                }
            }
        }
        if let el, attr(el, kAXRoleAttribute) as? String == "AXWebArea", axSelection?.isEmpty ?? false {
            throw CaptureError.noFocus // the page itself is focused, not a text box
        }
        // Copy via the keyboard. If AX says nothing is selected (or ⌘C would copy a whole line), select all first.
        let knownEmpty = axSelection.map { $0.isEmpty } ?? false
        let selectAllFirst = knownEmpty || (app.bundleIdentifier.map { copyLineBundleIDs.contains($0) } ?? false) && axSelection?.isEmpty != false
        if selectionOnly {
            // Never select all for a rewrite; and where ⌘C with nothing selected copies the line, require a known selection.
            if knownEmpty { throw CaptureError.noSelection }
            if app.bundleIdentifier.map({ copyLineBundleIDs.contains($0) }) == true, axSelection?.isEmpty != false { throw CaptureError.noSelection }
        }
        let text = try clipboardCapture(selectAllFirst: selectionOnly ? false : selectAllFirst, noSelectAll: selectionOnly)
        // Keep a readable text field so the paste can be checked afterwards.
        let role = el.flatMap { attr($0, kAXRoleAttribute) as? String } ?? ""
        let readable = ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) ? el.flatMap({ attr($0, kAXValueAttribute) as? String }) : nil
        return withField(fieldRect, Capture(method: .clipboard, text: text, pid: pid, appName: name,
                       element: readable != nil ? el : nil, fieldValue: readable, anchor: anchorRect))
    }

    private static func withField(_ f: NSRect?, _ c: Capture) -> Capture {
        var c = c
        c.fieldFrame = f
        return c
    }

    // MARK: Replace

    /// Writes the corrected text back. Returns how it was done.
    @discardableResult
    static func replace(_ cap: Capture, with corrected: String) throws -> String {
        defer { Surfaces.shared.touched() }
        if cap.method == .inApp, let tv = cap.textView, let range = cap.range {
            guard tv.string == cap.fieldValue else { throw CaptureError.textChanged }
            tv.insertText(corrected, replacementRange: range)
            return "in-app"
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == cap.pid else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(corrected, forType: .string)
            throw CaptureError.focusChanged
        }
        let attachment = "\u{FFFC}"
        if cap.text.components(separatedBy: attachment).count != corrected.components(separatedBy: attachment).count {
            throw CaptureError.attachment
        }
        if let el = cap.element, let before = cap.fieldValue,
           let now = attr(el, kAXValueAttribute) as? String, now != before {
            throw CaptureError.textChanged
        }
        if let el = cap.element, let base = cap.base, let value = cap.fieldValue {
            switch applyEdits(el, base: base, from: cap.text, to: corrected, fieldValue: value) {
            case .ok: return "accessibility"
            case .partial: throw CaptureError.partial
            case .unsupported:
                // A write that landed late must not be followed by a second one.
                usleep(150_000)
                if let now = attr(el, kAXValueAttribute) as? String, now != value { throw CaptureError.partial }
            }
        }
        if let el = cap.element {
            switch cap.method {
            case .axSelection:
                if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, corrected as CFString) == .success {
                    if verify(el, before: cap.fieldValue, expect: corrected) { return "accessibility" }
                    // Can't confirm through the value. Paste only if the original selection is visibly still there.
                    guard attr(el, kAXSelectedTextAttribute) as? String == cap.text else { return "accessibility (unverified)" }
                }
                try pasteVerified(corrected, cap) // selection is still in place
                return "paste"
            case .axWholeValue:
                var range = CFRange(location: 0, length: (cap.text as NSString).length)
                if let rv = AXValueCreate(.cfRange, &range),
                   AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv) == .success,
                   AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, corrected as CFString) == .success,
                   verify(el, before: cap.fieldValue, expect: corrected) {
                    return "accessibility"
                }
                if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, corrected as CFString) == .success,
                   verify(el, before: cap.fieldValue, expect: corrected) {
                    return "accessibility (value)"
                }
                if let now = attr(el, kAXValueAttribute) as? String, now != cap.fieldValue {
                    return "accessibility (unverified)" // something changed; don't paste on top of it
                }
                sendKey(kVK_ANSI_A, command: true)
                usleep(80_000)
                try pasteVerified(corrected, cap)
                return "paste"
            default: break
            }
        }
        try pasteVerified(corrected, cap) // the clipboard capture left the text selected
        return "paste"
    }

    enum EditResult { case ok, partial, unsupported }

    /// Applies only the changed words, so formatting, images and links around them survive.
    static func applyEdits(_ el: AXUIElement, base: Int, from original: String, to corrected: String, fieldValue: String) -> EditResult {
        let edits = WordDiff.edits(original, corrected)
        if edits.isEmpty { return .ok }
        let ns = fieldValue as NSString
        guard base >= 0, base + (original as NSString).length <= ns.length else { return .unsupported }
        let expected = ns.replacingCharacters(in: NSRange(location: base, length: (original as NSString).length), with: corrected)
        for (i, e) in edits.reversed().enumerated() {
            let before = attr(el, kAXValueAttribute) as? String
            var r = CFRange(location: base + e.range.location, length: e.range.length)
            guard let rv = AXValueCreate(.cfRange, &r),
                  AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv) == .success,
                  AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, e.text as CFString) == .success else {
                return i == 0 ? .unsupported : .partial
            }
            if i == 0 {
                // Make sure this app really applies AX writes before doing the rest.
                var took = false
                for _ in 0..<8 {
                    usleep(30_000)
                    if let now = attr(el, kAXValueAttribute) as? String, now != before { took = true; break }
                }
                if !took { return .unsupported }
            }
        }
        for _ in 0..<6 {
            if let now = attr(el, kAXValueAttribute) as? String {
                if now == expected { return .ok }
            }
            usleep(50_000)
        }
        // Some apps normalise line endings or spaces; accept if the corrected text is there.
        let needle = String(corrected.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if let now = attr(el, kAXValueAttribute) as? String, now.contains(needle) { return .ok }
        log("AX edits didn't fully verify")
        return .partial
    }

    /// Many apps report success but ignore the write, or apply it a moment later: poll the value.
    static func verify(_ el: AXUIElement, before: String?, expect: String, tries: Int = 6) -> Bool {
        let needle = String(expect.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        for _ in 0..<tries {
            usleep(50_000)
            guard let after = attr(el, kAXValueAttribute) as? String else { return false }
            if after != before && (needle.isEmpty || after.contains(needle)) { return true }
        }
        return false
    }

    // MARK: Undo

    @discardableResult
    static func undo(_ last: LastCorrection) throws -> String {
        defer { Surfaces.shared.touched() }
        if let tv = last.capture.textView {
            let r = (tv.string as NSString).range(of: last.corrected)
            guard r.location != NSNotFound else { throw CaptureError.textChanged }
            tv.insertText(last.original, replacementRange: r)
            return "in-app"
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == last.capture.pid else {
            copyToClipboard(last.original)
            throw CaptureError.undoClipboard
        }
        waitForModifierRelease()
        if last.via.hasPrefix("accessibility"), let el = last.capture.element,
           let value = attr(el, kAXValueAttribute) as? String {
            let ns = value as NSString
            let len = (last.corrected as NSString).length
            var r = NSRange(location: NSNotFound, length: 0)
            if let b = last.capture.base, b + len <= ns.length, ns.substring(with: NSRange(location: b, length: len)) == last.corrected {
                r = NSRange(location: b, length: len)
            } else {
                r = ns.range(of: last.corrected)
            }
            if r.location != NSNotFound {
                switch applyEdits(el, base: r.location, from: last.corrected, to: last.original, fieldValue: value) {
                case .ok: return "accessibility"
                case .partial: throw CaptureError.partial
                case .unsupported: break
                }
                var cf = CFRange(location: r.location, length: r.length)
                if let rv = AXValueCreate(.cfRange, &cf),
                   AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv) == .success,
                   AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, last.original as CFString) == .success,
                   verify(el, before: value, expect: last.original) {
                    return "accessibility"
                }
                // Fields that only accept whole-value writes (Safari <textarea>): put the whole value back.
                let restored = ns.replacingCharacters(in: r, with: last.original)
                if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, restored as CFString) == .success,
                   verify(el, before: value, expect: last.original) {
                    return "accessibility (value)"
                }
            }
        }
        if last.via == "paste", Date().timeIntervalSince(last.at) < 60 {
            sendKey(kVK_ANSI_Z, command: true)
            return "⌘Z"
        }
        copyToClipboard(last.original)
        throw CaptureError.undoClipboard
    }

    // MARK: Keyboard + clipboard

    static func copyToClipboard(_ s: String, transient: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        // Ask clipboard managers (Maccy, Raycast, Paste…) not to record our temporary paste.
        if transient { pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
    }

    static func waitForModifierRelease() {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty { return }
            usleep(20_000)
        }
    }

    static func sendKey(_ key: Int, command: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: false)
        let flags: CGEventFlags = command ? .maskCommand : []
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    typealias Saved = [[NSPasteboard.PasteboardType: Data]]

    static func savePasteboard() -> Saved {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    static func restorePasteboard(_ saved: Saved) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { dict in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    static func waitForChange(from count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSPasteboard.general.changeCount != count { return true }
            usleep(15_000)
        }
        return false
    }

    static func copySelection(timeout: TimeInterval) -> String? {
        let pb = NSPasteboard.general
        pb.clearContents()
        let count = pb.changeCount
        sendKey(kVK_ANSI_C, command: true)
        guard waitForChange(from: count, timeout: timeout) else { return nil }
        usleep(20_000)
        return pb.string(forType: .string)
    }

    static func clipboardCapture(selectAllFirst: Bool, noSelectAll: Bool = false) throws -> String {
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }
        var text: String?
        if !selectAllFirst { text = copySelection(timeout: 0.35) }
        if noSelectAll, text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true { throw CaptureError.noSelection }
        if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            if !selectAllFirst { usleep(150_000) } // let a late first copy land before the second
            sendKey(kVK_ANSI_A, command: true)
            usleep(100_000)
            text = copySelection(timeout: 0.6)
        }
        guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.noText }
        return t
    }

    private static var pendingRestore: DispatchWorkItem?

    static func paste(_ text: String) throws {
        let saved = savePasteboard()
        copyToClipboard(text, transient: true)
        sendKey(kVK_ANSI_V, command: true)
        // Give the target app time to read the pasteboard before restoring it.
        let work = DispatchWorkItem { restorePasteboard(saved) }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Pastes, then, when the field can be read, checks that the paste changed it.
    /// If it didn't, the correction stays on the clipboard instead of the old contents.
    static func pasteVerified(_ text: String, _ cap: Capture) throws {
        let el = cap.element
        let before = el.flatMap { attr($0, kAXValueAttribute) as? String }
        try paste(text)
        guard let el, let before else { return }
        // Any change counts: rich editors report pasted text with their own whitespace.
        for _ in 0..<16 {
            usleep(50_000)
            if let now = attr(el, kAXValueAttribute) as? String, now != before { return }
        }
        pendingRestore?.cancel()
        pendingRestore = nil
        copyToClipboard(text)
        log("paste not applied in \(cap.appName) (field unchanged)")
        throw CaptureError.pasteNotApplied
    }
}
