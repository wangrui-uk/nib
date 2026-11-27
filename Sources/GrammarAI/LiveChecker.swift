import AppKit
import ApplicationServices
import SwiftUI
import Carbon.HIToolbox

/// Live checking: wavy underlines under mistakes in the focused text field, with a popup to apply a fix.
///
/// Polls the focused element (~150 ms). After a pause in typing it sends the paragraphs it hasn't seen
/// to Gemini; issues are cached per paragraph text and found again in the current text on every tick,
/// so stale results simply don't match. Underlines are drawn in a click-through overlay at the
/// positions AX reports (AXBoundsForRange); apps that can't report positions are skipped.
final class LiveChecker {
    static let shared = LiveChecker()

    struct Mark: Equatable {
        let issue: Issue
        let range: NSRange
        var rects: [NSRect] // Cocoa screen coordinates
    }

    var paused = false
    /// For the self-test: check Nib's own windows too.
    var allowOwnProcess = false
    private(set) var marks: [Mark] = []
    var debugPopupShown: Bool { popup.isVisible }
    /// For diagnostics: the field's current underline ranges and rects (numbers only).
    var debugMarks: [(NSRange, [NSRect])] { marks.map { ($0.range, $0.rects) } }
    private(set) var support: [String: String] = [:] // bundle id → "underlines" / "no positions"

    private var timer: Timer?
    private var element: AXUIElement?
    private var bundleID = ""
    private var lastValue = ""
    private var lastChange = Date()
    private var offFieldTicks = 0
    private var enhanced = Set<pid_t>()
    /// Paragraphs from the previous tick, so issues can follow a paragraph while it's being edited.
    private var previousParagraphs: [(range: NSRange, text: String)] = []
    private var cache: [String: [Issue]] = [:]
    private var carry: [String: [Issue]] = [:]
    private var inFlight = false
    private var nextRequest = Date.distantPast
    private var dismissed = Set<String>()
    /// The field that couldn't report text positions, and when: skipped for a while, then tried again
    /// (Electron apps such as Slack build their tree a few seconds after Nib asks for it).
    private var noBoundsElement: (AXUIElement, Date)?
    static let negativeCacheLifetime: TimeInterval = 10
    private var hideAt: Date?
    private let overlay = UnderlineOverlay()
    private let popup = IssuePopup()

    static let pause: TimeInterval = 1.0       // after typing stops
    static let minInterval: TimeInterval = 2.0 // between requests
    static let maxChars = 4000                 // per request

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        startKeyMonitor()
    }

    func clear() {
        if !marks.isEmpty { marks = [] }
        overlay.hide()
        if popup.isVisible || keysRegistered { hidePopup() }
        hideAt = nil
    }

    // MARK: Tick

    // MARK: Evaluation (shared with Copy Diagnostics, so it reports the exact step live checking stops at)

    struct Step { let name: String; let ok: Bool; let detail: String }

    /// The checks live checking makes, in order, up to the first failure.
    /// `stage` says what kind of failure it is: "off" (switched off or not applicable), "excluded" (app excluded),
    /// "field" (in an app where the user may be typing, but no usable text field), or "" (all passed).
    func evaluate(_ app: NSRunningApplication?) -> (steps: [Step], target: TextTarget.Found?, stage: String) {
        var steps: [Step] = []
        func step(_ name: String, _ ok: Bool, _ detail: String = "") -> Bool { steps.append(Step(name: name, ok: ok, detail: detail)); return ok }
        let s = Settings.shared
        guard step("live checking is on", s.liveChecking),
              step("Nib isn't paused (⌘⌘)", !s.isPaused),
              step("no correction, suggestion or rewrite card open", !paused && !Surfaces.shared.modalUpChecked),
              step("Accessibility allowed for Nib", AXIsProcessTrusted() || allowOwnProcess),
              step("AI provider set up", s.apiKey != nil, s.provider.name),
              step("live checking allowed (privacy notice)", s.privacyConsent, s.privacyConsent ? "" : "not confirmed yet: Settings → Privacy"),
              step("front app found", app?.bundleIdentifier != nil),
              let app, let id = app.bundleIdentifier,
              step("front app isn't Nib", allowOwnProcess || app.processIdentifier != getpid()),
              step("not a terminal", !TextAccess.blockedBundleIDs.contains(id)),
              step("not turned off for this app", !s.liveDisabledApps.contains(id))
        else { return (steps, nil, "off") }
        let chromium = TextAccess.chromiumBundleIDs.contains(id), electron = TextAccess.isElectron(app)
        let excluded = TextAccess.prefersClipboard(app) && !chromium && !electron
        guard step("app not excluded from underlines", !excluded,
                   excluded ? (TextAccess.isCodeEditor(app) ? "code editor: turn on Settings → Live checking → Allow underlines in code editors (experimental)" : "Firefox is excluded")
                            : TextAccess.isCodeEditor(app) ? "code editor, experimental underlines on" : "")
        else { return (steps, nil, "excluded") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        TextTarget.enableTree(app, axApp)
        _ = step("app's accessibility tree switched on", true,
                 electron ? "AXManualAccessibility (Electron)" : chromium ? "AXEnhancedUserInterface (Chromium)" : "native app, not needed")
        guard let f = TextTarget.focused(app, axApp),
              step("focused element found", true, TextAccess.attr(f, kAXRoleAttribute) as? String ?? "?")
        else { _ = step("focused element found", false, "the app doesn't expose which element has focus"); return (steps, nil, "field") }
        guard step("not a password field", !TextTarget.isSecure(f)) else { return (steps, nil, "off") }
        let (target, why) = TextTarget.resolve(app, axApp)
        guard let target, step("text field with readable text", true, target.via)
        else { _ = step("text field with readable text", false, why); return (steps, nil, "field") }
        guard step("text within \(TextAccess.maxLength) characters", (target.text as NSString).length <= TextAccess.maxLength)
        else { return (steps, target, "off") }
        if TextAccess.isCodeEditor(app), Monaco.isMainEditor(target.element) {
            let info = Monaco.fileInfo(app, axApp)
            let (prose, why) = Monaco.proseVerdict(info.name, onDisk: info.onDisk)
            guard step("prose file in the code editor's main editor", prose,
                       "\(info.name ?? "unknown file") (from the \(info.source)): \(why)")
            else { return (steps, nil, "off") }
        }
        return (steps, target, "")
    }

    // MARK: Tick

    private func tick() {
        let app = NSWorkspace.shared.frontmostApplication
        let (steps, resolved, stage) = evaluate(app)
        guard let app, let id = app.bundleIdentifier, let target = resolved, stage.isEmpty else {
            if let app, let failed = steps.last(where: { !$0.ok }) {
                if stage == "excluded" { hintOnce(app, "it's excluded from underlines") }
                if stage == "field" {
                    TextTarget.noteSkip(app, "\(failed.name): \(failed.detail)")
                    TextTarget.reassertTree(app)
                    // The user is typing here, but Nib can't use the field: say so once instead of staying silent.
                    if typingInFrontApp(app) >= 8 { hintOnce(app, "it doesn't expose its text field to macOS") }
                }
            }
            clear()
            return
        }
        let el = target.element
        if element == nil || !CFEqual(element!, el) {
            element = el
            bundleID = id
            lastValue = ""
            previousParagraphs = []
            segmentCache.removeAll()
            clear()
        }
        if let nb = noBoundsElement, CFEqual(nb.0, el) {
            if Date().timeIntervalSince(nb.1) < Self.negativeCacheLifetime { clear(); return }
            noBoundsElement = nil
            TextMarkers.forget()
        }
        let role = target.role
        let value = target.text
        guard (value as NSString).length <= TextAccess.maxLength else { TextTarget.noteSkip(app, "text longer than \(TextAccess.maxLength) characters"); clear(); return }

        if value != lastValue { lastValue = value; lastChange = Date(); TextMarkers.version += 1 }
        let paragraphs = Self.paragraphs(value)
        // A paragraph being edited isn't in the cache yet: keep showing the issues of the version
        // it replaced (same position) while their words are still there, until it's checked again.
        if paragraphs.count == previousParagraphs.count {
            for (new, old) in zip(paragraphs, previousParagraphs) where cache[new.text] == nil && new.text != old.text {
                if let carried = carry[old.text] ?? cache[old.text] { carry[new.text] = carried.filter { new.text.contains($0.text) } }
            }
        }
        if carry.count > 200 { carry.removeAll() }
        previousParagraphs = paragraphs
        settlePendingClean(paragraphs)
        // Monaco's main editor: check only the lines on screen (its text can be a long file, or a page of it).
        if TextAccess.isCodeEditor(app), let g = Monaco.geometry(el, text: value), let vf = Self.visibleFrame(el).map(TextAccess.flip) {
            maybeRequest(paragraphs.filter { p in Monaco.rects(text: value, range: p.range, g).contains { vf.intersects($0) } })
        } else if TextAccess.isCodeEditor(app), Monaco.isMainEditor(el), let visible = TextMarkers.visibleRanges(el) {
            maybeRequest(paragraphs.filter { p in visible.contains { NSIntersectionRange($0, p.range).length > 0 } })
        } else {
            maybeRequest(paragraphs)
        }

        // Find each cached issue in the text as it is now.
        var found: [Mark] = []
        for p in paragraphs {
            guard let issues = cache[p.text] ?? carry[p.text] else { continue }
            var used: [NSRange] = []
            for issue in issues where !dismissed.contains(issue.key) {
                let r = Gemini.spanRange(issue.text, in: p.text as NSString)
                guard r.location != NSNotFound else { continue }
                let abs = NSRange(location: p.range.location + r.location, length: r.length)
                guard !used.contains(where: { NSIntersectionRange($0, abs).length > 0 }) else { continue }
                used.append(abs)
                found.append(Mark(issue: issue, range: abs, rects: []))
            }
            if found.count >= 40 { break }
        }
        guard !found.isEmpty else { clear(); return }

        // Where they are on screen.
        guard let visible = Self.visibleFrame(el) else {
            // Found mistakes but the field has no usable frame (no AXPosition/AXSize): say so instead of failing silently.
            hintOnce(app, "it doesn't report where its text field is on screen")
            TextTarget.noteSkip(app, "no frame for the text field (AXPosition/AXSize)")
            TextTarget.reassertTree(app)
            clear(); return
        }
        var placed: [Mark] = []
        var anyBounds = false
        let geometryUsed = TextAccess.isCodeEditor(app) && Monaco.isEditContext(el)
        for var m in found {
            guard let rects = lineRects(el, m.range, value) else { continue }
            anyBounds = true
            // Code editors: only rows fully on screen (not half under the sticky-scroll band or the edge).
            m.rects = rects.filter { geometryUsed ? visible.contains(CGPoint(x: $0.midX, y: $0.midY)) : visible.intersects($0) }
            if !m.rects.isEmpty { placed.append(m) }
        }
        if !anyBounds {
            let again = noBoundsElement != nil
            noBoundsElement = (el, Date())
            TextTarget.reassertTree(app)
            hintOnce(app, TextAccess.isCodeEditor(app) && Monaco.isMainEditor(el)
                     ? "turn on its Settings → “Editor: Accessibility Support” → on, so it shows where its text is"
                     : "it doesn't report where its text is on screen")
            if support[id] == nil { support[id] = "no positions" }
            if !again { log("live: a \(role) in \(app.localizedName ?? id) can't report text positions yet; retrying every \(Int(Self.negativeCacheLifetime)) s") }
            clear()
            return
        }
        if placed.isEmpty {
            // Positions came back but none falls inside the field (e.g. window-relative or stale coordinates).
            offFieldTicks += 1
            if offFieldTicks == 10 {
                let sample = found.first.flatMap { lineRects(el, $0.range, value)?.first }.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "?"
                TextTarget.noteSkip(app, "text positions fall outside the field (e.g. \(sample) vs field \(Int(visible.minX)),\(Int(visible.minY)) \(Int(visible.width))×\(Int(visible.height)))")
                hintOnce(app, "the text positions it reports don't match the field on screen")
            }
            clear(); return
        }
        offFieldTicks = 0
        if support[id] != "underlines" { support[id] = "underlines"; log("live: underlines in \(app.localizedName ?? id) (\(id))") }
        if placed != marks { marks = placed }
        overlay.show(marks, in: visible)
        updatePopup(el)
    }

    // MARK: Loop guard (Nib never re-checks or reverts its own writes)

    /// A change Nib made, word-level, lower-cased: "was" → "were".
    struct FixPair: Hashable { let from: String; let to: String }

    /// Changes Nib applied this session (live fixes, ⌥⌥, rewrites, and undos the other way round).
    private(set) var appliedFixes = Set<FixPair>()
    /// Text Nib just wrote, to be marked as checked on the next tick (once live checking is running again).
    private var pendingClean: [String] = []

    static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Word-level changes between what was there and what Nib wrote.
    static func fixPairs(original: String, written: String) -> [FixPair] {
        let ns = original as NSString
        return WordDiff.edits(original, written).compactMap { e in
            let from = norm(ns.substring(with: e.range)), to = norm(e.text)
            return from == to ? nil : FixPair(from: from, to: to)
        }
    }

    /// Drops suggestions that would undo a change Nib made this session (A→B applied, now B→A suggested).
    static func dropReverts(_ issues: [Issue], applied: Set<FixPair>) -> [Issue] {
        guard !applied.isEmpty else { return issues }
        return issues.filter { issue in
            let undoing = fixPairs(original: issue.text, written: issue.fix)
            let whole = FixPair(from: norm(issue.fix), to: norm(issue.text))
            return !(applied.contains(whole) || undoing.contains { applied.contains(FixPair(from: $0.to, to: $0.from)) })
        }
    }

    /// Field paragraphs that contain text Nib just wrote: those count as checked.
    static func cleanParagraphs(field: [String], written: [String]) -> [String] {
        let chunks = written.flatMap { w in paragraphs(w).map { $0.text.trimmingCharacters(in: .whitespaces) } }.filter { $0.count >= 3 }
        return field.filter { p in chunks.contains { p.contains($0) } }
    }

    /// Called after any write Nib makes outside live checking (⌥⌥ apply, Accept, Replace, undo).
    func noteNibWrite(original: String, written: String) {
        appliedFixes.formUnion(Self.fixPairs(original: original, written: written))
        pendingClean.append(written)
    }

    /// Marks pending Nib-written paragraphs as checked; runs once, on the first tick that sees the field.
    private func settlePendingClean(_ paragraphs: [(range: NSRange, text: String)]) {
        guard !pendingClean.isEmpty else { return }
        for p in Self.cleanParagraphs(field: paragraphs.map(\.text), written: pendingClean) where cache[p] == nil {
            cache[p] = []
        }
        pendingClean.removeAll()
    }

    // MARK: Hints and errors

    private var hinted = Set<String>()
    private(set) var lastError: (message: String, at: Date)?
    private var errorShown = Set<String>()

    /// Once per app per session: say why there are no underlines, instead of failing silently.
    /// Once per app per session: say why there are no underlines, instead of failing silently.
    private func hintOnce(_ app: NSRunningApplication, _ reason: String) {
        guard let id = app.bundleIdentifier, !hinted.contains(id) else { return }
        // Next to the field the user is typing in (or the pointer), on that field's screen, for 8 s.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let anchor = TextTarget.focusedRaw(app, axApp).flatMap { Self.frame($0) }.map(TextAccess.flip)
        hinted.insert(id)
        let name = app.localizedName ?? id
        let phrase = Settings.shared.triggerPhrase
        log("live: no underlines in \(name) (\(id)): \(reason); hint shown")
        HUD.shared.show("Underlines aren't available in \(name): \(reason). \(phrase.prefix(1).uppercased() + phrase.dropFirst()) to correct instead. (Menu → Copy Diagnostics… shows details.)",
                        style: .error, near: anchor, duration: 8)
    }

    /// Keys typed in the front app since it came to the front (to tell "typing in a field we can't use" from "just browsing").
    private var typing: (pid: pid_t, count: Int) = (0, 0)
    private func typingInFrontApp(_ app: NSRunningApplication) -> Int { typing.pid == app.processIdentifier ? typing.count : 0 }

    /// Problems that stop live checking (no credit, bad key, model gone) are shown once, not just logged.
    private func reportFailure(_ error: Error) {
        let msg = error.localizedDescription
        lastError = (msg, Date())
        var blocking = false
        if error.isBlockingAIError { blocking = true }
        nextRequest = Date().addingTimeInterval(blocking ? 300 : 30)
        if blocking, !errorShown.contains(msg) {
            errorShown.insert(msg)
            HUD.shared.show("Live checking paused: \(msg)", style: .error, duration: 6)
        }
    }

    // MARK: Requests

    private static func worthChecking(_ s: String) -> Bool {
        s.split(whereSeparator: \.isWhitespace).count >= 3 && s.contains(where: \.isLetter)
    }

    private func maybeRequest(_ paragraphs: [(range: NSRange, text: String)]) {
        guard !inFlight, Date().timeIntervalSince(lastChange) >= Self.pause, Date() >= nextRequest else { return }
        var todo: [String] = []
        var size = 0
        for p in paragraphs where cache[p.text] == nil && Self.worthChecking(p.text) && !todo.contains(p.text) {
            if size + p.text.count > Self.maxChars, !todo.isEmpty { break }
            todo.append(p.text)
            size += p.text.count + 2
        }
        guard !todo.isEmpty else { return }
        inFlight = true
        nextRequest = Date().addingTimeInterval(Self.minInterval)
        let started = Date()
        let appLabel = "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") (\(bundleID))"
        Task { @MainActor in
            do {
                let issues = Self.dropReverts(try await Gemini.proofread(todo.joined(separator: "\n\n")), applied: appliedFixes)
                if cache.count > 400 { cache.removeAll() }
                for t in todo { cache[t] = issues.filter { t.contains($0.text) } }
                lastError = nil
                log("live: checked \(todo.count) paragraph(s) in \(appLabel), \(size) chars, \(issues.count) issue(s), \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            } catch {
                log("live: check failed: \(error.localizedDescription)")
                reportFailure(error) // backs off; the correct shortcut still works
            }
            inFlight = false
        }
    }

    // MARK: Popup

    /// Whether Tab / ⇧Tab / Esc act on the popup right now. A pure rule, so it can be tested:
    /// a popup opened by the caret is armed at once; one opened by hovering only after the pointer
    /// has rested 0.3 s; and never while the user is typing (a key in the last 0.5 s), so a Tab typed
    /// mid-sentence under a hovering pointer still goes to the app.
    struct KeyGate {
        enum Origin { case caret, hover }
        var origin: Origin?
        var shownAt = Date.distantPast
        var lastTyped = Date.distantPast
        static let hoverDwell: TimeInterval = 0.3
        static let typingQuiet: TimeInterval = 0.5

        func armed(at now: Date) -> Bool {
            guard let origin else { return false }
            if now.timeIntervalSince(lastTyped) < Self.typingQuiet { return false }
            return origin == .caret || now.timeIntervalSince(shownAt) >= Self.hoverDwell
        }
    }

    private var gate = KeyGate()
    private var popupMark: Mark?
    private var popupElement: AXUIElement?
    private var keysRegistered = false
    private var keyMonitor: Any?
    static let tabID: UInt32 = 5, shiftTabID: UInt32 = 6, escID: UInt32 = 7

    private func updatePopup(_ el: AXUIElement) {
        let mouse = NSEvent.mouseLocation
        if popup.isVisible, popup.frame.insetBy(dx: -8, dy: -8).contains(mouse) { hideAt = nil; syncKeys(); return }
        var target = marks.first { $0.rects.contains { $0.insetBy(dx: -1, dy: -4).contains(mouse) } }
        var origin = KeyGate.Origin.hover
        if target == nil, Date().timeIntervalSince(lastChange) > 0.6, let sel = Self.selectedRange(el), sel.length == 0 {
            target = marks.first { sel.location > $0.range.location && sel.location < NSMaxRange($0.range) }
            origin = .caret
        }
        // The coordinator decides: nothing over a card, and not straight after Nib moved the text or caret.
        let caretKey = Self.selectedRange(el).map { "\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0):\($0.location):\($0.length)" }
        if !Surfaces.shared.gate.livePopupAllowed(caret: caretKey, mouse: mouse, at: Date()), !popup.isVisible {
            target = nil
        }
        if let t = target {
            hideAt = nil
            if popup.shownKey != Self.popupKey(t) || popupMark?.rects != t.rects {
                if popup.shownKey != Self.popupKey(t) { gate.origin = origin; gate.shownAt = Date() }
                popupMark = t
                popupElement = el
                popup.show(t, key: Self.popupKey(t), total: marks.count,
                           apply: { [weak self] in self?.apply(t) },
                           applyAll: { [weak self] in self?.applyAll() },
                           ignore: { [weak self] in self?.ignore(t) })
            }
        } else if popup.isVisible {
            if let at = hideAt { if Date() >= at { hidePopup() } } else { hideAt = Date().addingTimeInterval(0.4) }
        }
        syncKeys()
    }

    private func hidePopup() {
        popup.hide()
        hideAt = nil
        popupMark = nil
        gate.origin = nil
        syncKeys()
    }

    private func ignore(_ m: Mark) {
        dismissed.insert(m.issue.key)
        hidePopup()
    }

    /// Tab / ⇧Tab / Esc are caught (as temporary global shortcuts) only while the popup is armed.
    private func syncKeys() {
        let want = popup.isVisible && popupMark != nil && gate.armed(at: Date())
        guard want != keysRegistered else { return }
        if want {
            HotKey.shared.actions[Self.tabID] = { [weak self] in self?.key(.tab) }
            HotKey.shared.actions[Self.shiftTabID] = { [weak self] in self?.key(.shiftTab) }
            HotKey.shared.actions[Self.escID] = { [weak self] in self?.key(.esc) }
            HotKey.shared.register(id: Self.tabID, keyCode: UInt32(kVK_Tab), modifiers: 0)
            HotKey.shared.register(id: Self.shiftTabID, keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey))
            HotKey.shared.register(id: Self.escID, keyCode: UInt32(kVK_Escape), modifiers: 0)
        } else {
            [Self.tabID, Self.shiftTabID, Self.escID].forEach { HotKey.shared.unregister(id: $0) }
        }
        keysRegistered = want
    }

    enum PopupKey { case tab, shiftTab, esc }

    private func key(_ k: PopupKey) {
        // Re-check at the moment of the key: still armed, and focus still in the popup's field.
        let focusOK: Bool = {
            guard let pe = popupElement, let app = NSWorkspace.shared.frontmostApplication else { return false }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let f = TextAccess.attr(axApp, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return false }
            return CFEqual(f as! AXUIElement, pe)
        }()
        guard focusOK, popup.isVisible, let m = popupMark, gate.armed(at: Date()) else {
            passThrough(k)
            return
        }
        switch k {
        case .tab: apply(m)
        case .shiftTab: applyAll()
        case .esc: ignore(m)
        }
    }

    /// The key wasn't meant for us: give it back to the app.
    private func passThrough(_ k: PopupKey) {
        [Self.tabID, Self.shiftTabID, Self.escID].forEach { HotKey.shared.unregister(id: $0) }
        keysRegistered = false
        let code = k == .esc ? kVK_Escape : kVK_Tab
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = k == .shiftTab ? .maskShift : []
            e?.post(tap: .cghidEventTap)
        }
    }

    func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return }
            self.gate.lastTyped = Date()
            if !e.modifierFlags.contains(.command), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                self.typing = self.typing.pid == pid ? (pid, self.typing.count + 1) : (pid, 1)
            }
            self.syncKeys()
        }
    }

    private static func popupKey(_ m: Mark) -> String { "\(m.issue.key)@\(m.range.location)" }

    // MARK: Apply

    /// Called with an undo record after fixes are applied (⌃⌥Z puts the text back).
    var onApplied: ((LastCorrection) -> Void)?

    private var isPasteApp: Bool {
        TextAccess.chromiumBundleIDs.contains(bundleID) || TextAccess.copyLineBundleIDs.contains(bundleID)
            || NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first.map(TextAccess.isElectron) == true
    }

    /// Writes one fix into the field as it is now. Returns the field's new value, or nil.
    private func write(_ mark: Mark, _ el: AXUIElement, in value: String) -> String? {
        defer { Surfaces.shared.touched() }
        let ns = value as NSString
        guard NSMaxRange(mark.range) <= ns.length, ns.substring(with: mark.range) == mark.issue.text else { return nil }
        let expected = ns.replacingCharacters(in: mark.range, with: mark.issue.fix)
        var cf = CFRange(location: mark.range.location, length: mark.range.length)
        if let rv = AXValueCreate(.cfRange, &cf),
           AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv) == .success,
           AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, mark.issue.fix as CFString) == .success,
           Self.waitFor(el, expected) {
            return expected
        }
        let paste = isPasteApp
        if !paste, (TextTarget.text(el)?.0) == value,
           AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, expected as CFString) == .success,
           Self.waitFor(el, expected) {
            return expected
        }
        if paste, (TextTarget.text(el)?.0) == value,
           let sel = Self.selectedRange(el), sel == mark.range {
            // Chromium/Electron accept the selection but not the text: paste the fix over the selected span.
            try? TextAccess.paste(mark.issue.fix)
            for _ in 0..<16 {
                usleep(50_000)
                if let now = TextTarget.text(el)?.0, now != value { return now }
            }
        }
        return nil
    }

    private func undoRecord(_ el: AXUIElement, from original: String, to now: String) -> LastCorrection {
        var cap = Capture(method: .axWholeValue, text: original, pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                          appName: bundleID, element: el, fieldValue: original)
        cap.base = 0
        return LastCorrection(capture: cap, original: original, corrected: now, via: "accessibility")
    }

    func apply(_ mark: Mark) {
        hidePopup()
        guard let el = element, let value = TextTarget.text(el)?.0 else { return }
        let ns = value as NSString
        guard NSMaxRange(mark.range) <= ns.length, ns.substring(with: mark.range) == mark.issue.text else {
            HUD.shared.show("The text changed; check again in a moment.", style: .info, near: mark.rects.first); return
        }
        guard let now = write(mark, el, in: value) else {
            log("live: apply failed in \(bundleID)")
            HUD.shared.show("Couldn't apply the fix here. \(Settings.shared.triggerPhrase.prefix(1).uppercased() + Settings.shared.triggerPhrase.dropFirst()) instead.", style: .error, near: mark.rects.first)
            return
        }
        log("live: applied \(mark.issue.kind) fix in \(bundleID)")
        appliedFixes.formUnion(Self.fixPairs(original: mark.issue.text, written: mark.issue.fix))
        // Settle the paragraph: keep its other issues, don't re-check what was just fixed.
        let old = Self.paragraphs(value).first { NSLocationInRange(mark.range.location, $0.range) }
        let new = Self.paragraphs(now).first { NSLocationInRange(mark.range.location, $0.range) }
        if let old, let new, let issues = cache[old.text] ?? carry[old.text] {
            cache[new.text] = issues.filter { $0 != mark.issue && new.text.contains($0.text) }
        }
        // Put the caret after the fix.
        var caret = CFRange(location: mark.range.location + (mark.issue.fix as NSString).length, length: 0)
        if let rv = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv)
        }
        lastValue = now
        onApplied?(undoRecord(el, from: value, to: now))
    }

    /// ⇧Tab: every underlined fix in the field, last first so earlier ranges don't move.
    func applyAll() {
        let all = marks
        hidePopup()
        guard let el = element, let original = TextTarget.text(el)?.0, !all.isEmpty else { return }
        var value = original
        var applied = 0
        for m in all.sorted(by: { $0.range.location > $1.range.location }) {
            // Spans before the ones already written haven't moved; check each is still what was marked.
            guard let now = write(m, el, in: value) else { continue }
            value = now
            applied += 1
        }
        guard applied > 0 else {
            HUD.shared.show("Couldn't apply the fixes here.", style: .error, near: all.first?.rects.first)
            return
        }
        // Settle: what was just fixed isn't checked again, and won't be suggested back.
        for m in all { appliedFixes.formUnion(Self.fixPairs(original: m.issue.text, written: m.issue.fix)) }
        for p in Self.paragraphs(value) where cache[p.text] == nil { cache[p.text] = [] }
        lastValue = value
        log("live: applied \(applied)/\(all.count) fixes in \(bundleID)")
        onApplied?(undoRecord(el, from: original, to: value))
        let skipped = all.count - applied
        HUD.shared.show("Applied \(applied) fix\(applied == 1 ? "" : "es")\(skipped > 0 ? " (\(skipped) skipped)" : "") · \(Settings.shared.undoDisplay) to undo",
                        style: .success, near: all.first?.rects.first, duration: 2.5)
    }

    private static func waitFor(_ el: AXUIElement, _ expected: String) -> Bool {
        for _ in 0..<8 {
            if (TextTarget.text(el)?.0) == expected { return true }
            usleep(30_000)
        }
        return false
    }

    // MARK: AX geometry

    static func paragraphs(_ s: String) -> [(range: NSRange, text: String)] {
        var out: [(NSRange, String)] = []
        let ns = s as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { sub, r, _, _ in
            if let sub, !sub.isEmpty { out.append((r, sub)) }
        }
        return out
    }

    static func selectedRange(_ el: AXUIElement) -> NSRange? {
        guard let v = TextAccess.attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    /// Screen rect (AX coordinates) of a character range: AXBoundsForRange, else the text-marker API
    /// (rich editors in Chromium/Electron apps, e.g. Slack, answer only the latter).
    static func bounds(_ el: AXUIElement, _ range: NSRange) -> CGRect? {
        if let text = TextTarget.text(el)?.0, let g = Monaco.geometry(el, text: text) {
            TextMarkers.lastMethod = "Monaco geometry"
            return Monaco.rects(text: text, range: range, g).first
        }
        let plain = plainBounds(el, range)
        // Native fields: AXBoundsForRange, inside the field and word-sized. Chromium multi-line fields (Chrome
        // <textarea>, Slack) answer with the whole field's box, and some give nothing: then the text-marker
        // positions (range rect, joined character rects, or hit-testing the lines).
        if let p = plain, TextMarkers.isPlainTrusted(el, p, frame: { frame(el) }) {
            let f = frame(el)
            let len = TextTarget.number(el, kAXNumberOfCharactersAttribute) ?? NSMaxRange(range)
            if TextMarkers.plausible(p, length: range.length, textLength: len, field: f) { TextMarkers.lastMethod = "AXBoundsForRange"; return p }
            return TextMarkers.bounds(el, range, fieldFrame: f)
        }
        let f = frame(el)
        if let m = TextMarkers.bounds(el, range, fieldFrame: f) { return m }
        let len = TextTarget.number(el, kAXNumberOfCharactersAttribute) ?? NSMaxRange(range)
        return plain.flatMap { TextMarkers.plausible($0, length: range.length, textLength: len, field: f) ? $0 : nil }
    }

    static func plainBounds(_ el: AXUIElement, _ range: NSRange) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let rv = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width > 0, r.height > 0 else { return nil }
        return r
    }

    /// Line segments of wrapped spans, worked out once per text version (it takes one AX call per character).
    private var segmentCache: [String: [NSRange]] = [:]

    /// One rect per line: a range that wraps comes back as one tall box, so it's split into its lines.
    private func lineRects(_ el: AXUIElement, _ range: NSRange, _ value: String) -> [NSRect]? {
        if let g = Monaco.geometry(el, text: value) {
            TextMarkers.lastMethod = "Monaco geometry"
            let r = Monaco.rects(text: value, range: range, g)
            return r.isEmpty ? nil : r.map(TextAccess.flip)
        }
        guard let whole = Self.bounds(el, range) else { return nil }
        let key = "\(value.hashValue)|\(range.location)|\(range.length)|\(Int(whole.width))"
        if let segs = segmentCache[key] {
            return segs.compactMap { Self.bounds(el, $0) }.map(TextAccess.flip)
        }
        let first = Self.bounds(el, NSRange(location: range.location, length: 1)) ?? whole
        if whole.height <= first.height * 1.5 { segmentCache[key] = [range]; return [TextAccess.flip(whole)] }
        var segs: [NSRange] = []
        var lastY: CGFloat?
        for i in range.location..<NSMaxRange(range) {
            guard let r = Self.bounds(el, NSRange(location: i, length: 1)) else { continue }
            if let y = lastY, abs(y - r.midY) < first.height / 2, var last = segs.popLast() {
                last.length = i + 1 - last.location
                segs.append(last)
            } else {
                segs.append(NSRange(location: i, length: 1))
                lastY = r.midY
            }
        }
        if segmentCache.count > 300 { segmentCache.removeAll() }
        segmentCache[key] = segs
        return segs.compactMap { Self.bounds(el, $0) }.map(TextAccess.flip)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p = TextAccess.attr(el, kAXPositionAttribute), let s = TextAccess.attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// The part of the field that's on screen: the field, clipped by its scroll area and window.
    static func visibleFrame(_ el: AXUIElement) -> NSRect? {
        guard var r = frame(el) else { return nil }
        // Monaco's hidden textarea: the visible text is in the editor area around it.
        if Monaco.isMainEditor(el), let area = Monaco.editorArea(of: el), let af = frame(area) {
            r = af
            // Sticky scroll pins headings over the top rows: no underlines under them.
            if let sticky = Monaco.stickyFrame(in: area), sticky.height > 0, sticky.maxY < r.maxY {
                r = CGRect(x: r.minX, y: sticky.maxY, width: r.width, height: r.maxY - sticky.maxY)
            }
        }
        var cur: AXUIElement = el
        for _ in 0..<6 {
            guard let p = TextAccess.attr(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            cur = p as! AXUIElement
            let role = TextAccess.attr(cur, kAXRoleAttribute) as? String
            if role == "AXScrollArea" || role == "AXWindow", let pf = frame(cur) { r = r.intersection(pf) }
            if role == "AXWindow" { break }
        }
        guard !r.isNull, r.width > 4, r.height > 4 else { return nil }
        return TextAccess.flip(r).insetBy(dx: 0, dy: -4) // room for the wave under the last line
    }
}

// MARK: - Overlay

final class UnderlineView: NSView {
    var items: [(NSRect, String)] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        for (r, kind) in items {
            let color: NSColor = kind == "spelling" ? .systemRed : kind == "grammar" ? .systemOrange : .secondaryLabelColor
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            let y = r.minY + 1
            if kind == "wording" {
                path.setLineDash([2, 2], count: 2, phase: 0)
                path.move(to: NSPoint(x: r.minX, y: y)); path.line(to: NSPoint(x: r.maxX, y: y))
            } else {
                var x = r.minX
                path.move(to: NSPoint(x: x, y: y))
                var up = true
                while x < r.maxX {
                    let nx = min(x + 2, r.maxX)
                    path.line(to: NSPoint(x: nx, y: y + (up ? 1.5 : -1.5) * 0.9))
                    x = nx; up.toggle()
                }
            }
            path.stroke()
        }
    }
}

final class UnderlineOverlay {
    private var panel: NSPanel?
    private var view: UnderlineView?
    private var lastFrame = NSRect.zero

    func show(_ marks: [LiveChecker.Mark], in frame: NSRect) {
        let p = panel ?? make()
        if frame != lastFrame { p.setFrame(frame, display: false); lastFrame = frame }
        let items = marks.flatMap { m in m.rects.map { ($0.offsetBy(dx: -frame.minX, dy: -frame.minY), m.issue.kind) } }
        if !(view!.items.elementsEqual(items) { $0.0 == $1.0 && $0.1 == $1.1 }) { view!.items = items }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let v = UnderlineView()
        p.contentView = v
        panel = p
        view = v
        return p
    }
}

// MARK: - Popup

struct IssueView: View {
    let issue: Issue

    /// "e.g. The policy had a strong *effect* on sales." in the caption style, the fix in medium weight.
    private var exampleLine: some View {
        let ex = issue.example
        let text: Text
        if let r = ex.range(of: issue.fix, options: .caseInsensitive) {
            text = Text("e.g. ") + Text(String(ex[..<r.lowerBound]))
                + Text(String(ex[r])).fontWeight(.medium).foregroundColor(.primary.opacity(0.75))
                + Text(String(ex[r.upperBound...]))
        } else {
            text = Text("e.g. ") + Text(ex)
        }
        let pt = PopupStyle.size * 11 / 13
        let italic = PopupStyle.italicFont(pt)
        return Wrapping(natural: PopupStyle.width("e.g. " + ex, pt), maxWidth: min(PopupStyle.maxTextWidth, 340 * PopupStyle.scale)) {
            text.font(italic ?? PopupStyle.font(pt)).foregroundColor(.secondary).lineLimit(3)
        }
        .modifier(SlantIfNeeded(active: italic == nil))
    }

    var total: Int = 1
    let apply: () -> Void
    var applyAll: () -> Void = {}
    let ignore: () -> Void
    var body: some View {
        PopupCard(accent: PopupStyle.color(for: issue.kind)) {
            change
            let reason = issue.reason.prefix(1).uppercased() + issue.reason.dropFirst()
            Wrapping(natural: PopupStyle.width(reason, PopupStyle.size * 11 / 13)) { PopupStyle.caption(reason) }
            if !issue.example.isEmpty { exampleLine }
            HStack(spacing: 6) {
                Button(action: apply) { KeyLabel(title: "Apply", glyph: "⇥", onAccent: true) }
                    .buttonStyle(PopupButtonStyle(prominent: true))
                if total > 1 {
                    Button(action: applyAll) { KeyLabel(title: "Apply All (\(total))", glyph: "⇧⇥", tinted: true) }
                        .buttonStyle(PopupButtonStyle(tinted: true))
                }
                Button(action: ignore) { KeyLabel(title: "Ignore", glyph: "esc") }
                    .buttonStyle(PopupButtonStyle())
            }
            .padding(.top, 2)
        }
        .fixedSize()
    }

    /// Spans longer than this show the change in place (a compact diff) instead of "original → fix".
    static let inlineThreshold = 40

    /// The change. Short: "original → fix" on one line, the changed characters of the fix in the accent colour;
    /// the fix goes on its own line when both don't fit. Long: the change in place, shortened around the edits,
    /// so a single "?" or "," isn't lost at the end of a long line. Everything wraps at `maxTextWidth`.
    @ViewBuilder private var change: some View {
        let pt = PopupStyle.size
        let fix = issue.fix.isEmpty ? "(remove)" : issue.fix
        let arrow = Image(systemName: "arrow.right").font(.system(size: 10 * PopupStyle.scale, weight: .semibold)).foregroundColor(.secondary)
        let fixText = issue.fix.isEmpty ? PopupStyle.added(fix) : InlineDiff.fixText(issue.text, issue.fix)
        if issue.text.count > Self.inlineThreshold, !issue.fix.isEmpty {
            let segs = InlineDiff.compact(InlineDiff.segments(issue.text, issue.fix))
            Wrapping(natural: PopupStyle.width(InlineDiff.plain(segs), pt, bold: true)) { InlineDiff.text(segs).font(PopupStyle.textFont).lineLimit(6) }
        } else {
            let wa = PopupStyle.width(issue.text, pt), wb = PopupStyle.width(fix, pt, bold: true), arrowW = 16 * PopupStyle.scale + 12
            if wa + arrowW + wb <= PopupStyle.maxTextWidth {
                HStack(spacing: 6) { PopupStyle.removed(issue.text); arrow; fixText }.font(PopupStyle.textFont).fixedSize()
            } else {
                VStack(alignment: .leading, spacing: 3 * PopupStyle.scale) {
                    Wrapping(natural: wa) { PopupStyle.removed(issue.text).font(PopupStyle.textFont).lineLimit(4) }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        arrow
                        Wrapping(natural: wb, maxWidth: PopupStyle.maxTextWidth - arrowW) { fixText.font(PopupStyle.textFont).lineLimit(4) }
                    }
                }
            }
        }
    }
}

final class IssuePopup {
    private var panel: HUDPanel?
    private(set) var shownKey: String?
    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: NSRect { panel?.frame.insetBy(dx: 10, dy: 10) ?? .zero }

    func show(_ mark: LiveChecker.Mark, key: String, total: Int, apply: @escaping () -> Void,
              applyAll: @escaping () -> Void, ignore: @escaping () -> Void) {
        let host = FirstMouseHostingView(rootView: IssueView(issue: mark.issue, total: total, apply: apply, applyAll: applyAll, ignore: ignore))
        let size = host.fittingSize
        let p = panel ?? make()
        p.contentView = host
        p.setContentSize(size)
        // Just below the underlined word, so the line being written stays visible; above it if there's no room.
        // (The view has 10 pt of transparent padding around the card.)
        let anchor = mark.rects.first ?? .zero
        let vf = CardPlacement.screen(for: NSPoint(x: anchor.midX, y: anchor.midY)).visibleFrame
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.minY - 4 - size.height + 10)
        if origin.y + 10 < vf.minY + CardPlacement.margin { origin.y = anchor.maxY + 4 - 10 }
        p.setFrameOrigin(CardPlacement.clamp(NSRect(origin: origin, size: size), padding: 10, in: vf).origin)
        p.orderFrontRegardless()
        shownKey = key
    }

    func hide() {
        panel?.orderOut(nil)
        shownKey = nil
    }

    private func make() -> HUDPanel {
        let p = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel = p
        return p
    }
}

/// For UIRender only.
enum LivePreview {
    static func popup(total: Int = 4) -> some View {
        IssueView(issue: Issue(kind: "grammar", text: "they was", fix: "they were", reason: "subject-verb agreement"), total: total, apply: {}, ignore: {})
    }
    static func popupLong() -> some View {
        IssueView(issue: Issue(kind: "grammar", text: "Could you send it, when you have read the notes.", fix: "Could you send it when you have read the notes?",
                               reason: "Missing question mark"), total: 2, apply: {}, ignore: {})
    }
    static func popupLongReplace() -> some View {
        IssueView(issue: Issue(kind: "wording", text: "the thing that we were talking about at the meeting yesterday afternoon",
                               fix: "what we discussed at yesterday afternoon's meeting", reason: "Wordy; a shorter phrasing reads better"), total: 1, apply: {}, ignore: {})
    }
    static func popupMidLength() -> some View {
        IssueView(issue: Issue(kind: "grammar", text: "who's responsibility is it to", fix: "whose responsibility is it to", reason: "Possessive, not a contraction"), total: 1, apply: {}, ignore: {})
    }
    static func popupWithExample() -> some View {
        IssueView(issue: Issue(kind: "wording", text: "affect", fix: "effect", reason: "noun needed",
                               example: "The new policy had a strong effect on sales."), total: 3, apply: {}, ignore: {})
    }
    static func underlines() -> NSView {
        let tf = NSTextField(labelWithString: "i has went to the store and buyed three apple, the buton is red.")
        tf.font = .systemFont(ofSize: 15)
        tf.sizeToFit()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: tf.frame.width + 20, height: 40))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        tf.frame.origin = NSPoint(x: 10, y: 12)
        container.addSubview(tf)
        let u = UnderlineView(frame: container.bounds)
        func rect(_ s: String) -> NSRect {
            let full = tf.stringValue as NSString
            let r = full.range(of: s)
            let attrs: [NSAttributedString.Key: Any] = [.font: tf.font!]
            let x = (full.substring(to: r.location) as NSString).size(withAttributes: attrs).width
            let w = (s as NSString).size(withAttributes: attrs).width
            return NSRect(x: 10 + x + 2, y: 12, width: w, height: 18)
        }
        u.items = [(rect("has went"), "grammar"), (rect("buyed"), "grammar"), (rect("buton"), "spelling"), (rect("is red"), "wording")]
        container.addSubview(u)
        return container
    }
}
