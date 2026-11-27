import AppKit
import ApplicationServices

/// Finds the text field the user is typing in, for live checking, the ✨ chip and `--diagnose`.
/// Covers rich editors in Chromium/Electron apps (Slack, Notion, Gmail…): their focused element may be a
/// wrapper, may have an unusual role, or may expose its text only through AXNumberOfCharacters +
/// AXStringForRange instead of AXValue.
enum TextTarget {
    struct Found {
        let element: AXUIElement
        let role: String
        let text: String
        /// How it was found and read, for diagnostics: e.g. "focused, AXValue" or "descendant, AXStringForRange".
        let via: String
    }

    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    private static var enabled = Set<pid_t>()

    /// Chromium and Electron build their web-content AX tree only when asked (once per process).
    static func enableTree(_ app: NSRunningApplication, _ axApp: AXUIElement, force: Bool = false) {
        guard let id = app.bundleIdentifier, force || !enabled.contains(app.processIdentifier) else { return }
        if TextAccess.chromiumBundleIDs.contains(id) {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        } else if TextAccess.isElectron(app) {
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        enabled.insert(app.processIdentifier)
    }

    /// When the tree was last asked for again after a failure, per pid.
    private static var reasserted: [pid_t: Date] = [:]
    static let reassertInterval: TimeInterval = 5

    /// Whether a re-assert last done at `last` may run again at `now` (throttle; pure, for self-tests).
    static func mayReassert(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= reassertInterval
    }

    /// Live checking failed in this app (no focused field, no readable text or no positions): ask Chromium/Electron
    /// for its accessibility tree again, at most every 5 s. They can drop the tree after Nib first asked
    /// (window reload, renderer swap, Chromium switching accessibility off when it thinks nobody reads it);
    /// Copy Diagnostics always re-asked, which is why running it brought underlines back. Returns true if it re-asked.
    @discardableResult
    static func reassertTree(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, TextAccess.chromiumBundleIDs.contains(id) || TextAccess.isElectron(app) else { return false }
        let pid = app.processIdentifier
        guard mayReassert(last: reasserted[pid]) else { return false }
        let first = reasserted[pid] == nil
        reasserted[pid] = Date()
        let axApp = AXUIElementCreateApplication(pid)
        enableTree(app, axApp, force: true)
        if TextAccess.isElectron(app) { setManualAccessibility(axApp, pid: pid) }
        TextMarkers.forget()
        if first { log("live: re-asking \(app.localizedName ?? id) for its accessibility tree after a failed check (at most every \(Int(reassertInterval)) s)") }
        return true
    }

    /// AXManualAccessibility attempts on apps that showed no focused element: pid → AXError of the set call.
    private(set) static var manualAttempts: [pid_t: AXError] = [:]

    /// Sets AXManualAccessibility (harmless where unsupported) and returns the AXError of the call.
    @discardableResult
    static func setManualAccessibility(_ axApp: AXUIElement, pid: pid_t) -> AXError {
        let e = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        manualAttempts[pid] = e
        return e
    }

    static func focused(_ app: NSRunningApplication, _ axApp: AXUIElement) -> AXUIElement? {
        if let f = focusedRaw(app, axApp) { return f }
        // No focused element: maybe an Electron app Nib didn't recognise. Ask once for its tree (the next
        // check sees the result); harmless on other apps.
        if manualAttempts[app.processIdentifier] == nil {
            let e = setManualAccessibility(axApp, pid: app.processIdentifier)
            var extra = ""
            if let id = app.bundleIdentifier, TextAccess.chromiumBundleIDs.contains(id) {
                // Chrome & co: AXEnhancedUserInterface is what switches their web content on; set it again.
                let e2 = AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                extra = ", AXEnhancedUserInterface → AXError \(e2.rawValue)"
            }
            log("live: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) showed no focused element; set AXManualAccessibility → AXError \(e.rawValue)\(extra)")
        }
        return nil
    }

    static func focusedRaw(_ app: NSRunningApplication, _ axApp: AXUIElement) -> AXUIElement? {
        if let f = TextAccess.attr(axApp, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() { return (f as! AXUIElement) }
        if let f = TextAccess.attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
            let el = f as! AXUIElement
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            if pid == app.processIdentifier { return el }
        }
        return nil
    }

    static func number(_ el: AXUIElement, _ name: String) -> Int? {
        (TextAccess.attr(el, name) as? NSNumber)?.intValue
    }

    /// The element's text: AXValue, else AXStringForRange over AXNumberOfCharacters.
    static func text(_ el: AXUIElement) -> (String, String)? {
        if let v = TextAccess.attr(el, kAXValueAttribute) as? String { return (v, "AXValue") }
        guard let n = number(el, kAXNumberOfCharactersAttribute), n >= 0, n <= TextAccess.maxLength else { return nil }
        var cf = CFRange(location: 0, length: n)
        guard let rv = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let s = out as? String else { return nil }
        return (s, "AXStringForRange")
    }

    /// Text-capable: a text role with text, or any element with a readable text range and text.
    static func isTextCapable(_ el: AXUIElement) -> Bool {
        let role = TextAccess.attr(el, kAXRoleAttribute) as? String ?? ""
        if role == "AXWebArea" { return false } // the page itself, not a field
        // Controls aren't text fields, even when Chromium gives them a text range.
        if isControlRole(role) { return false }
        guard LiveChecker.selectedRange(el) != nil || textRoles.contains(role) else { return false }
        return text(el) != nil
    }

    static let controlRoles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton",
        "AXPopUpButton", "AXTab", "AXList", "AXRow", "AXCell", "AXImage", "AXToolbar", "AXMenu", "AXMenuBar", "AXSlider",
        "AXDisclosureTriangle", "AXOutline", "AXTable", "AXHeading"]
    static func isControlRole(_ role: String) -> Bool { controlRoles.contains(role) }

    static func isSecure(_ el: AXUIElement) -> Bool {
        (TextAccess.attr(el, kAXRoleAttribute) as? String) == "AXSecureTextField"
            || (TextAccess.attr(el, kAXSubroleAttribute) as? String) == "AXSecureTextField"
    }

    /// The focused text field, or why there isn't one (no user text in the reason).
    static func resolve(_ app: NSRunningApplication, _ axApp: AXUIElement) -> (Found?, String) {
        enableTree(app, axApp)
        guard let f = focused(app, axApp) else { return (nil, "no focused element (the app isn't exposing its accessibility tree)") }
        if isSecure(f) { return (nil, "password field") }
        let fRole = TextAccess.attr(f, kAXRoleAttribute) as? String ?? ""
        let emptyWrapper = !textRoles.contains(fRole) && (text(f)?.0.isEmpty ?? true)
        // An empty non-text element (e.g. VS Code's editor group) may hold the real text area: look inside first.
        if emptyWrapper, let d = focusedDescendant(of: f), !isSecure(d), let (t, how) = text(d) {
            return (Found(element: d, role: TextAccess.attr(d, kAXRoleAttribute) as? String ?? "", text: t, via: "descendant, \(how)"), "")
        }
        if !emptyWrapper, isTextCapable(f), let (t, how) = text(f) {
            return (Found(element: f, role: TextAccess.attr(f, kAXRoleAttribute) as? String ?? "", text: t, via: "focused, \(how)"), "")
        }
        // A wrapper (web area, group, scroll area) around the real editor: look for its focused editable descendant.
        if let d = focusedDescendant(of: f), !isSecure(d), let (t, how) = text(d) {
            return (Found(element: d, role: TextAccess.attr(d, kAXRoleAttribute) as? String ?? "", text: t, via: "descendant, \(how)"), "")
        }
        let role = TextAccess.attr(f, kAXRoleAttribute) as? String ?? "?"
        return (nil, "focused element is \(role) with no readable text (no AXValue / AXStringForRange)")
    }

    static func focusedDescendant(of root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 600 {
            let (el, depth) = queue.removeFirst()
            seen += 1
            if seen > 1, (TextAccess.attr(el, kAXFocusedAttribute) as? Bool) == true, isTextCapable(el) { return el }
            guard depth < 30, let kids = TextAccess.attr(el, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: kids.map { ($0, depth + 1) })
        }
        return nil
    }

    // MARK: Skip reasons, logged once per app and reason (never any text)

    private static var logged = Set<String>()

    static func noteSkip(_ app: NSRunningApplication, _ reason: String) {
        let key = "\(app.bundleIdentifier ?? "?")|\(reason)"
        guard !reason.isEmpty, !logged.contains(key) else { return }
        logged.insert(key)
        log("live: skipped in \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")): \(reason)")
    }
}
