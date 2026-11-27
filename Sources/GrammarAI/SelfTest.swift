import AppKit
import ApplicationServices

/// `GrammarAI --ax-selftest`: exercises the AX edit + verify + undo path against a rich NSTextView in this process.
enum AXSelfTest {
    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        Settings.shared.persist = false
        Settings.shared.privacyConsent = true // in memory only
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        tv.isRichText = true
        let s = NSMutableAttributedString(string: "i has went to the ", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        s.append(NSAttributedString(string: "store", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
        s.append(NSAttributedString(string: " yesterday and buyed three apple.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        tv.textStorage?.setAttributedString(s)
        w.contentView = tv
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(tv)
        app.activate(ignoringOtherApps: true)

        func boldStore() -> Bool {
            do {
                let r = (tv.string as NSString).range(of: "store")
                guard r.location != NSNotFound, let f = tv.textStorage?.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont else { return false }
                return f.fontDescriptor.symbolicTraits.contains(.bold)
            }
        }
        func text() -> String { tv.string }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            print("AX trusted:", AXIsProcessTrusted())
            let axApp = AXUIElementCreateApplication(getpid())
            guard let f = TextAccess.attr(axApp, kAXFocusedUIElementAttribute) else { print("FAIL: no focused element"); exit(1) }
            let el = f as! AXUIElement
            print("role:", TextAccess.attr(el, kAXRoleAttribute) as? String ?? "?",
                  "| value settable:", TextAccess.isSettable(el, kAXValueAttribute),
                  "| selectedText settable:", TextAccess.isSettable(el, kAXSelectedTextAttribute))
            guard let value = TextAccess.attr(el, kAXValueAttribute) as? String else { print("FAIL: no value"); exit(1) }
            let fixed = "I went to the store yesterday and bought three apples."
            print("edits:", WordDiff.edits(value, fixed).map { "\($0.range)→\($0.text.debugDescription)" }.joined(separator: ", "))
            let r = TextAccess.applyEdits(el, base: 0, from: value, to: fixed, fieldValue: value)
            let after = text()
            print("applyEdits:", r, "| text ok:", after == fixed, "| bold kept:", boldStore())
            print("  now:", after.debugDescription)

            var cap = Capture(method: .axWholeValue, text: value, pid: getpid(), element: el, fieldValue: value)
            cap.base = 0
            let last = LastCorrection(capture: cap, original: value, corrected: fixed, via: "accessibility")
            do {
                let how = try TextAccess.undo(last)
                let undone = text()
                print("undo via \(how) | restored:", undone == value, "| bold kept:", boldStore())
            } catch { print("undo FAIL:", error.localizedDescription, "| frontmost:", NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") }

            // Selection mode: select "buyed three apple" and fix only that.
            do { tv.setSelectedRange((tv.string as NSString).range(of: "buyed three apple")) }
            let sel = TextAccess.attr(el, kAXSelectedTextAttribute) as? String ?? ""
            let v2 = TextAccess.attr(el, kAXValueAttribute) as? String ?? ""
            let base = (v2 as NSString).range(of: sel).location
            let r2 = TextAccess.applyEdits(el, base: base, from: sel, to: "bought three apples", fieldValue: v2)
            print("selection edit:", r2, "| text:", text().debugDescription)

            // End to end through the real capture() → replace() → undo() routing.
            do {
                tv.textStorage?.setAttributedString(s)
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                let cap = try TextAccess.capture()
                print("E2E whole: method=\(cap.method.rawValue) base=\(cap.base.map(String.init) ?? "nil") anchor=\(cap.anchor.map { "\($0)" } ?? "nil")")
                let how = try TextAccess.replace(cap, with: fixed)
                print("  replace via \(how) | ok:", text() == fixed, "| bold kept:", boldStore())
                let u = try TextAccess.undo(LastCorrection(capture: cap, original: cap.text, corrected: fixed, via: how))
                print("  undo via \(u) | ok:", text() == cap.text, "| bold kept:", boldStore())

                tv.setSelectedRange((tv.string as NSString).range(of: "i has went"))
                let cap2 = try TextAccess.capture()
                print("E2E selection: method=\(cap2.method.rawValue) text=\(cap2.text.debugDescription) base=\(cap2.base.map(String.init) ?? "nil")")
                let how2 = try TextAccess.replace(cap2, with: "I went")
                print("  replace via \(how2) | text:", text().debugDescription, "| bold kept:", boldStore())

                // Stale guard: change the text after capture.
                let cap3 = try TextAccess.capture()
                tv.insertText("X", replacementRange: NSRange(location: 0, length: 0))
                do { _ = try TextAccess.replace(cap3, with: "whatever"); print("  stale guard: FAIL (replaced)") }
                catch { print("  stale guard OK:", error.localizedDescription) }
            } catch { print("E2E FAIL:", error.localizedDescription) }
            exit(0)
        }
        app.run()
    }
}

import WebKit

/// `GrammarAI --ax-webtest`: the same AX path against WebKit (what Safari and Mail compose use).
enum AXWebTest {
    static var web: WKWebView!
    static func run(contentEditable: Bool) {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        web = WKWebView(frame: w.contentView!.bounds)
        w.contentView = web
        let field = contentEditable
            ? "<div id=f contenteditable style='border:1px solid #888;padding:6px'>i has went to the <b>store</b> yesterday and buyed three apple.</div>"
            : "<textarea id=f rows=4 cols=60>i has went to the store yesterday and buyed three apple.</textarea>"
        web.loadHTMLString("<html><body>\(field)<script>const f=document.getElementById('f');f.focus();</script></body></html>", baseURL: nil)
        w.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            w.makeFirstResponder(web)
            web.evaluateJavaScript("document.getElementById('f').focus()") { _, _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("mode:", contentEditable ? "contenteditable" : "textarea")
            let axApp = AXUIElementCreateApplication(getpid())
            guard let f = TextAccess.attr(axApp, kAXFocusedUIElementAttribute) else { print("no focused element via AX (needs trust for WebKit's remote tree?)"); exit(0) }
            let el = f as! AXUIElement
            print("role:", TextAccess.attr(el, kAXRoleAttribute) as? String ?? "?",
                  "| value:", (TextAccess.attr(el, kAXValueAttribute) as? String)?.debugDescription ?? "nil",
                  "| value settable:", TextAccess.isSettable(el, kAXValueAttribute),
                  "| selectedText settable:", TextAccess.isSettable(el, kAXSelectedTextAttribute))
            guard let value = TextAccess.attr(el, kAXValueAttribute) as? String else { exit(0) }
            let fixed = "I went to the store yesterday and bought three apples."
            let r = TextAccess.applyEdits(el, base: 0, from: value, to: fixed, fieldValue: value)
            let js = contentEditable ? "document.getElementById('f').innerHTML" : "document.getElementById('f').value"
            web.evaluateJavaScript(js) { res, _ in
                print("applyEdits:", r, "| DOM now:", (res as? String)?.debugDescription ?? "?")
                exit(0)
            }
        }
        app.run()
    }
}

import SwiftUI

/// `GrammarAI --render-ui DIR`: renders the windows and HUDs to PNGs for a visual check.
enum UIRender {
    /// The Settings form (top: the AI section) with a provider chosen in memory only.
    /// Renders just the AI section for one provider (set in memory only).
    static func runAI(_ p: Provider, dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Settings.shared.persist = false
        Settings.shared.provider = p
        if p == .vertex { Settings.shared.vertexProject = "my-gcp-project" }
        DispatchQueue.main.async {
            let host = NSHostingView(rootView: AnyView(AISectionPreview(keys: KeyTester()).background(Color(nsColor: .windowBackgroundColor))))
            let size = host.fittingSize
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-ai-\(p.rawValue).png"))
            }
            exit(0)
        }
        app.run()
    }

    static let rwIn = "hey, i cant make the meeting tmrw cause im swamped with the Q3 report, can we do thursday 3pm instead?"
    static let rwOut = "Hi, I won't be able to make the meeting tomorrow as I'm busy with the Q3 report. Could we move it to Thursday at 3 pm instead?"
    static func rw(_ p: RewriteController.Phase, changes: Bool = true) -> RewriteController {
        RewriteController.preview(rwIn, p, changes: changes)
    }

    /// Renders the popups at several fonts/sizes, then puts the user's settings back.
    static func runFonts(dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let s = Settings.shared
        let saved = (s.popupFont, s.popupFontSize)
        let variants: [(String, String, Double)] = [("font-system-11", "", 11), ("font-system-20", "", 20),
                                                    ("font-georgia-16", "Georgia", 16), ("font-mono-14", "__mono__", 14),
                                                    ("font-avenir-18", "Avenir Next", 18)]
        DispatchQueue.main.async {
            for (name, font, size) in variants {
                s.popupFont = font; s.popupFontSize = size
                let view = VStack(alignment: .leading, spacing: 0) {
                    family()
                    HUDPreview.message("Fixed 3 issues · ⌃⌥Z to undo", .success)
                }.background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                let size = host.fittingSize
                let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = host
                w.appearance = NSAppearance(named: .aqua)
                w.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                }
                w.orderOut(nil)
            }
            s.popupFont = saved.0; s.popupFontSize = saved.1
            exit(0)
        }
        app.run()
    }

    /// Made-up usage in memory (never the user's file).
    static func sampleUsage() -> Usage {
        let u = Usage(url: nil)
        for i in 0..<38 { u.add(.live, provider: "Gemini (AI Studio)", model: "gemini-3.5-flash-lite", TokenUsage(input: 700 + i * 9, output: 60 + i, thinking: nil)) }
        for _ in 0..<6 { u.add(.correct, provider: "Gemini (AI Studio)", model: "gemini-3.5-flash-lite", TokenUsage(input: 420, output: 380, thinking: nil)) }
        for _ in 0..<3 { u.add(.rewrite, provider: "Claude (Anthropic)", model: "claude-haiku-5-5", TokenUsage(input: 610, output: 240, thinking: nil)) }
        u.add(.test, provider: "Custom (OpenAI-compatible)", model: "llama3", TokenUsage())
        return u
    }

    static func family() -> some View {
        HStack(alignment: .top, spacing: 0) {
            LivePreview.popup(total: 3)
            HUDPreview.suggestion("i has went to the store yesterday and buyed three apple, they was delicious.",
                                  "I went to the store yesterday and bought three apples; they were delicious.")
        }
    }

    static func run(dir: String) {
        if CommandLine.arguments.contains("--default-look") {
            // Renders for the website: the default popup font and size, in memory only.
            Settings.shared.persist = false
            Settings.shared.popupFont = ""
            Settings.shared.popupFontSize = 13
        }
        if CommandLine.arguments.contains("--untrusted") { OnboardingModel.forceUntrusted = true }
        if CommandLine.arguments.contains("--fonts") { runFonts(dir: dir); return }
        if let i = CommandLine.arguments.firstIndex(of: "--ai"), i + 1 < CommandLine.arguments.count,
           let p = Provider(rawValue: CommandLine.arguments[i + 1]) { runAI(p, dir: dir); return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let views: [(String, AnyView)] = [
            ("onboarding", AnyView(OnboardingView(m: OnboardingModel(), keys: KeyTester(), onDone: {}))),
            ("settings", AnyView(SettingsView(m: SettingsModel(), keys: KeyTester()))),
            ("live-popup", AnyView(LivePreview.popup())),
            ("rewrite-diff-light", AnyView(RewriteCard(c: UIRender.rw(.ready(UIRender.rwOut))))),
            ("rewrite-diff-dark", AnyView(RewriteCard(c: UIRender.rw(.ready(UIRender.rwOut))))),
            ("rewrite-plain-light", AnyView(RewriteCard(c: UIRender.rw(.ready(UIRender.rwOut), changes: false)))),
            ("rewrite-loading-light", AnyView(RewriteCard(c: UIRender.rw(.loading)))),
            ("rewrite-failed-light", AnyView(RewriteCard(c: UIRender.rw(.failed("Gemini rate limit reached. Try again in a moment."))))),
            ("chip-light", AnyView(ChipView {})),
            ("settings-rewrite", AnyView(Form { Section("Rewrite selection") {
                Toggle("Show ✨ Rewrite button when text is selected", isOn: .constant(true))
                RewriteStylesEditor(settings: Settings.shared)
            } }.formStyle(.grouped).frame(width: 480, height: 200))),
            ("chip-dark", AnyView(ChipView {})),
            ("settings-usage-light", AnyView(Form { UsageSection(usage: UIRender.sampleUsage()) }.formStyle(.grouped).frame(width: 480).fixedSize(horizontal: false, vertical: true))),
            ("settings-usage-dark", AnyView(Form { UsageSection(usage: UIRender.sampleUsage()) }.formStyle(.grouped).frame(width: 480).fixedSize(horizontal: false, vertical: true))),
            ("family-dark", AnyView(UIRender.family())),
            ("family-light", AnyView(UIRender.family())),
            ("live-popup-example-light", AnyView(LivePreview.popupWithExample())),
            ("live-popup-example-dark", AnyView(LivePreview.popupWithExample())),
            ("live-popup-dark", AnyView(LivePreview.popup())),
            ("live-popup-light", AnyView(LivePreview.popup())),
            ("live-popup-single-light", AnyView(LivePreview.popup(total: 1))),
            ("live-popup-long-light", AnyView(LivePreview.popupLong())),
            ("live-popup-long-dark", AnyView(LivePreview.popupLong())),
            ("live-popup-long-replace-light", AnyView(LivePreview.popupLongReplace())),
            ("live-popup-long-replace-dark", AnyView(LivePreview.popupLongReplace())),
            ("live-popup-mid-light", AnyView(LivePreview.popupMidLength())),
            ("hud-working", AnyView(HUDPreview.message("Correcting…", .working))),
            ("hud-success", AnyView(HUDPreview.message("Fixed 3 issues · ⌃⌥Z to undo", .success))),
            ("hud-error", AnyView(HUDPreview.message("The API key isn't valid. Check it in Settings.", .error))),
            ("hud-suggest", AnyView(HUDPreview.suggestion("i has went to the store yesterday and buyed three apple.",
                                                          "I went to the store yesterday and bought three apples."))),
        ]
        DispatchQueue.main.async {
            for (name, view) in views {
                let host = NSHostingView(rootView: AnyView(view.background(Color(nsColor: .windowBackgroundColor))))
                let size = host.fittingSize
                let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = host
                if name.hasSuffix("-dark") { w.appearance = NSAppearance(named: .darkAqua) }
                if name.hasSuffix("-light") { w.appearance = NSAppearance(named: .aqua) }
                w.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote", url.path, size)
                w.orderOut(nil)
            }
            let v = LivePreview.underlines()
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: v.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = v
            w.orderFrontRegardless()
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-underlines.png"))
            }
            exit(0)
        }
        app.run()
    }
}

/// `GrammarAI --live-selftest`: live checking against a real NSTextView in this process (real Gemini call).
enum LiveSelfTest {
    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        Settings.shared.persist = false
        Settings.shared.privacyConsent = true // in memory only
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 520, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .systemFont(ofSize: 15)
        tv.string = "i has went to the store yesterday and buyed three apple, they was delicious.\nThe colour of the buton is wrong."
        w.contentView = scroll
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        app.activate(ignoringOtherApps: true)
        let live = LiveChecker.shared
        live.allowOwnProcess = true
        live.start()
        let t0 = Date()
        func poll() {
            if !live.marks.isEmpty || Date().timeIntervalSince(t0) > 12 {
                print("marks after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(live.marks.count)")
                let winFrame = w.frame
                for m in live.marks {
                    let inside = m.rects.allSatisfy { winFrame.contains(NSPoint(x: $0.midX, y: $0.midY)) }
                    print("  [\(m.issue.kind)] \(m.issue.text.debugDescription) → \(m.issue.fix.debugDescription) range=\(m.range) rects=\(m.rects.count) inWindow=\(inside)")
                }
                // Caret inside the first mark should open its popup.
                if let m = live.marks.first {
                    tv.setSelectedRange(NSRange(location: m.range.location + 1, length: 0))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        print("popup shown for caret:", live.debugPopupShown)
                        live.apply(m)
                        print("after apply:", tv.string.debugDescription)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            print("marks now: \(live.marks.count) (was one fewer expected)")
                            // ⇧Tab path: apply all, then undo back to the text before it.
                            var record: LastCorrection?
                            live.onApplied = { record = $0 }
                            let before = tv.string
                            live.applyAll()
                            print("after apply all:", tv.string.debugDescription)
                            if let r = record {
                                let how = try? TextAccess.undo(r)
                                print("undo apply-all via \(how ?? "FAILED"): restored=\(tv.string == before)")
                            } else { print("apply all: no undo record (FAIL)") }
                            exit(0)
                        }
                    }
                } else { exit(1) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
        app.run()
    }
}

/// `--autocorrect-probe [-Key value…]`: an off-screen text view in a process that never activates.
/// Types misspellings and reports whether autocorrect replaced them and which windows (bubbles) appeared.
enum AutocorrectProbe {
    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        tv.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        tv.isContinuousSpellCheckingEnabled = true
        w.contentView = tv
        w.orderFrontRegardless()
        w.makeFirstResponder(tv)
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for word in ["teh", " ", "recieve", " ", "adress", " "] { tv.insertText(word, replacementRange: tv.selectedRange()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let extra = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }.map { String(describing: type(of: $0)) }
                print("autocorrectPref=\(NSSpellChecker.isAutomaticSpellingCorrectionEnabled) textViewAutocorrect=\(tv.isAutomaticSpellingCorrectionEnabled) text=\(tv.string.debugDescription) newWindows=\(extra)")
                exit(0)
            }
        }
        app.run()
    }
}

/// `--marker-selftest`: an off-screen WebKit page (never activated) with a contenteditable editor and a textarea.
/// Compares AXBoundsForRange with the text-marker fallback on Nib's own accessibility tree.
/// Note: WebKit doesn't build its page tree for an off-screen window in a process that never activates, so this
/// needs a visible run to say anything.
enum MarkerSelfTest {
    static var web: WKWebView!
    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: 200, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        // Ask for the web-content accessibility tree before the page loads.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        w.contentView = web
        web.loadHTMLString("""
            <html><body style="font:16px -apple-system">
            <div id=ce contenteditable style="border:1px solid #999;padding:6px">i has went to the <b>store</b> and buyed three apple, they was happy.</div>
            <textarea id=ta rows=3 cols=50>he dont know where the files is</textarea></body></html>
            """, baseURL: nil)
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let axApp = AXUIElementCreateApplication(getpid())
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var queue: [(AXUIElement, Int)] = (TextAccess.attr(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { ($0, 0) }
            var found = 0, seen = 0
            while !queue.isEmpty, seen < 3000 {
                let (el, d) = queue.removeFirst(); seen += 1
                let role = TextAccess.attr(el, kAXRoleAttribute) as? String ?? ""
                if role == "AXTextArea" || role == "AXTextField" || (role != "AXWebArea" && LiveChecker.selectedRange(el) != nil && TextTarget.text(el) != nil) {
                    found += 1
                    let len = TextTarget.text(el).map { ($0.0 as NSString).length } ?? 0
                    let frame = LiveChecker.frame(el)
                    let r = NSRange(location: 2, length: 3)
                    let plain = LiveChecker.plainBounds(el, r)
                    TextMarkers.version += 1
                    let marked = TextMarkers.bounds(el, r, fieldFrame: frame)
                    let inside = { (b: CGRect?) in b.map { frame?.insetBy(dx: -4, dy: -4).contains(CGPoint(x: $0.midX, y: $0.midY)) ?? false } ?? false }
                    print("field \(found): role \(role), \(len) chars, frame \(frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "n/a")")
                    print("  AXBoundsForRange(2,3): \(plain.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)) inside=\(inside($0))" } ?? "none")")
                    print("  text markers supported: \(TextMarkers.supported(el)), (2,3): \(marked.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)) inside=\(inside($0))" } ?? "none")")
                    if let p = plain, let m = marked { print("  same rect: \(abs(p.minX - m.minX) < 2 && abs(p.minY - m.minY) < 2 && abs(p.width - m.width) < 2)") }
                    // A wrapped/multi-word range through the shared function used by underlines.
                    let wide = LiveChecker.bounds(el, NSRange(location: 0, length: min(len, 20)))
                    print("  LiveChecker.bounds(0,20): \(wide.map { "\(Int($0.width))×\(Int($0.height)) inside=\(inside($0))" } ?? "none")")
                }
                guard d < 40, let kids = TextAccess.attr(el, kAXChildrenAttribute) as? [AXUIElement] else { continue }
                queue.append(contentsOf: kids.map { ($0, d + 1) })
            }
            print("elements visited: \(seen), text fields: \(found), accessibility trusted: \(AXIsProcessTrusted())")
            exit(0)
        }
        app.run()
    }
}
