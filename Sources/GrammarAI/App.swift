import AppKit
import SwiftUI
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let correctID: UInt32 = 1
    static let undoID: UInt32 = 2
    static let pauseID: UInt32 = 11

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let keys = KeyTester()
    private var busy = false
    var isBusy: Bool { busy }
    var lastRoute = ""
    var lastError = ""
    private var hotKeyOK = true
    private var last: LastCorrection?

    func applicationWillTerminate(_ note: Notification) {
        // Never leave the user's macOS text checking switched off behind us.
        SystemTextChecking.restore()
    }

    @objc func checkForUpdates() { Updates.shared.checkForUpdates(nil) }

    func applicationDidFinishLaunching(_ note: Notification) {
        log("launched; accessibility=\(AXIsProcessTrusted()) apiKey=\(Settings.shared.apiKey != nil)")
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(.idle)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Permission, key and live-checking state can change at any time: keep the icon in step.
        let iconTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Record Accessibility changes in the log (it's otherwise only logged at launch).
            let trusted = AXIsProcessTrusted()
            if trusted != self.lastTrusted { log("accessibility changed: \(trusted)"); self.lastTrusted = trusted }
            // A timed pause that has run out resumes by itself.
            if self.pauseApplied && !Settings.shared.isPaused { self.resume(auto: true) }
            self.refreshIcon()
        }
        RunLoop.main.add(iconTimer, forMode: .common)
        // Renamed from Grammar AI: a login item registered for the old app is re-registered for this one.
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        }
        HotKey.shared.actions[Self.correctID] = { [weak self] in self?.correctNow() }
        HotKey.shared.actions[Self.undoID] = { [weak self] in self?.undoLast() }
        registerHotKey()

        LiveChecker.shared.onApplied = { [weak self] record in self?.last = record }
        RewriteController.shared.onApplied = { [weak self] record in self?.last = record }
        RewriteController.shared.onClosed = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if self?.busy == false { LiveChecker.shared.paused = false } }
        }
        LiveChecker.shared.start()
        SelectionChip.shared.action = { [weak self] in self?.rewriteNow() }
        SelectionChip.shared.start()
        DoubleTapMonitor.shift.action = { [weak self] in self?.rewriteNow() }
        registerPauseKey()
        applyPause(announce: false) // also syncs macOS text checking (restores originals left by a crash)
        if let i = CommandLine.arguments.firstIndex(of: "--e2e"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { @MainActor in await E2E.run(self, dir: dir) }
            return
        }
        Updates.shared.start()
        Usage.shared.recording = Settings.shared.persist // local statistics: normal launches only
        // Existing users updating to 2.1: ask once for the OK before live checking runs. (New users get the same
        // notice as a step of the setup guide.)
        let st = Settings.shared
        if st.persist, st.liveChecking, !st.privacyConsent, AXIsProcessTrusted(), st.apiKey != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Consent.ask() }
        }
        if CommandLine.arguments.contains("--relaunched-for-accessibility") && !AXIsProcessTrusted() {
            // Ask macOS to list Nib again in Privacy & Security → Accessibility, and show the guide.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openOnboarding() }
            return
        }
        if !UserDefaults.standard.bool(forKey: "onboarded") || !AXIsProcessTrusted() || Settings.shared.apiKey == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openOnboarding() }
        }
    }

    private var goodHotKey: (UInt32, UInt32, String)?

    func registerHotKey() {
        let s = Settings.shared
        DoubleTapMonitor.shared.action = { [weak self] in self?.correctNow() }
        if s.isPaused {
            // Paused: nothing is listened for except the pause shortcut itself.
            HotKey.shared.unregister(id: Self.correctID)
            HotKey.shared.unregister(id: Self.undoID)
            DoubleTapMonitor.shared.stop()
            DoubleTapMonitor.shift.stop()
            hotKeyOK = true
            return
        }
        HotKey.shared.register(id: Self.undoID, keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))
        applyRewriteTrigger()
        if s.usesDoubleOption {
            HotKey.shared.unregister(id: Self.correctID)
            DoubleTapMonitor.shared.start()
            hotKeyOK = true
            return
        }
        DoubleTapMonitor.shared.stop()
        hotKeyOK = HotKey.shared.register(id: Self.correctID, keyCode: s.hotKeyCode, modifiers: s.hotKeyModifiers)
        if hotKeyOK {
            goodHotKey = (s.hotKeyCode, s.hotKeyModifiers, s.hotKeyDisplay)
        } else if let (code, mods, display) = goodHotKey, code != s.hotKeyCode || mods != s.hotKeyModifiers {
            // Keep the shortcut that worked.
            let taken = s.hotKeyDisplay
            s.hotKeyCode = code; s.hotKeyModifiers = mods; s.hotKeyDisplay = display
            hotKeyOK = HotKey.shared.register(id: Self.correctID, keyCode: code, modifiers: mods)
            HUD.shared.show("\(taken) is already used by another app. Kept \(display).", style: .error, duration: 4)
            return
        }
        if !hotKeyOK {
            HUD.shared.show("\(s.hotKeyDisplay) is already used by another app. Pick another shortcut in Settings.", style: .error, duration: 4)
        }
    }

    // MARK: Pause

    private var goodPauseKey: (UInt32, UInt32, String)?
    private var pauseApplied = false
    private var lastTrusted = AXIsProcessTrusted()

    func registerPauseKey() {
        let s = Settings.shared
        HotKey.shared.actions[Self.pauseID] = { [weak self] in self?.togglePause() }
        DoubleTapMonitor.command.action = { [weak self] in self?.togglePause() }
        if s.pauseTrigger != "custom" {
            // ⌘⌘ keeps listening while paused: it's the way back.
            HotKey.shared.unregister(id: Self.pauseID)
            DoubleTapMonitor.command.start()
            return
        }
        DoubleTapMonitor.command.stop()
        let clash = !s.usesDoubleOption && s.hotKeyCode == s.pauseKeyCode && s.hotKeyModifiers == s.pauseKeyModifiers
        if !clash, HotKey.shared.register(id: Self.pauseID, keyCode: s.pauseKeyCode, modifiers: s.pauseKeyModifiers) {
            goodPauseKey = (s.pauseKeyCode, s.pauseKeyModifiers, s.pauseKeyDisplay)
            return
        }
        let taken = s.pauseKeyDisplay
        let why = clash ? "is your correct shortcut" : "is already used by another app"
        if let (code, mods, display) = goodPauseKey, code != s.pauseKeyCode || mods != s.pauseKeyModifiers {
            s.pauseKeyCode = code; s.pauseKeyModifiers = mods; s.pauseKeyDisplay = display
            HotKey.shared.register(id: Self.pauseID, keyCode: code, modifiers: mods)
            HUD.shared.show("\(taken) \(why). Kept \(display) for Pause Nib.", style: .error, duration: 4)
        } else {
            HUD.shared.show("\(taken) \(why). Pick another Pause shortcut in Settings.", style: .error, duration: 4)
        }
    }

    @objc func togglePause() {
        Settings.shared.isPaused ? resume() : pause(until: .distantFuture)
    }

    func pause(until: Date) {
        Settings.shared.pausedUntil = until
        applyPause(announce: true)
    }

    func resume(auto: Bool = false) {
        Settings.shared.pausedUntil = nil
        applyPause(announce: true, auto: auto)
    }

    /// Puts everything in line with the pause state: listeners, open panels, the icon.
    func applyPause(announce: Bool, auto: Bool = false) {
        let paused = Settings.shared.isPaused
        if !paused, Settings.shared.pausedUntil != nil { Settings.shared.pausedUntil = nil } // an expired pause
        if paused {
            RewriteController.shared.close()
            HUD.shared.hide()
            SelectionChip.shared.hide()
            LiveChecker.shared.clear()
        }
        registerHotKey()
        SystemTextChecking.sync()
        pauseApplied = paused
        refreshIcon()
        guard announce else { return }
        if paused {
            let until = Settings.shared.pausedUntil ?? .distantFuture
            let when = until == .distantFuture ? "" : " until \(Self.pauseTime(until))"
            HUD.shared.show("Nib paused\(when) · \(Settings.shared.pauseDisplay) to resume", style: .info, duration: 2.2)
        } else {
            HUD.shared.show(auto ? "Nib is back on (the pause ended)" : "Nib on", style: .success, duration: 1.8)
        }
        log(paused ? "paused" : "resumed\(auto ? " (timer)" : "")")
    }

    static func pauseTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }



    // MARK: Menu

    enum Status { case ready, needsAX, noKey }
    var status: Status {
        if !AXIsProcessTrusted() { return .needsAX }
        if Settings.shared.apiKey == nil { return .noKey }
        return .ready
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.isEnabled = enabled
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let s = Settings.shared
        if s.isPaused {
            let h = item("Nib is paused", nil, enabled: false)
            h.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: nil)
            menu.addItem(h)
            menu.addItem(item("Resume Nib\t\(s.pauseDisplay)", #selector(togglePause)))
        } else {
            menu.addItem(item("Pause Nib\t\(s.pauseDisplay)", #selector(togglePause)))
        }
        menu.addItem(.separator())
        let header: NSMenuItem
        switch status {
        case .ready:
            header = item(busy ? "Correcting…" : "Ready — \(s.triggerPhrase) in any text field", nil, enabled: false)
            header.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.tinted(.systemGreen)
        case .needsAX:
            header = item("Needs Accessibility permission", nil, enabled: false)
            header.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?.tinted(.systemOrange)
        case .noKey:
            header = item("No API key", nil, enabled: false)
            header.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?.tinted(.systemOrange)
        }
        menu.addItem(header)
        if status == .needsAX { menu.addItem(item("Allow Accessibility Access…", #selector(openAX))) }
        if status == .noKey { menu.addItem(item("Add API Key…", #selector(openSettings))) }
        if s.liveChecking, let e = LiveChecker.shared.lastError, Date().timeIntervalSince(e.at) < 900 {
            let i = item("⚠︎ Live checking paused: \(e.message.prefix(70))", #selector(openSettings))
            menu.addItem(i)
        }
        if s.liveChecking && !s.privacyConsent && status == .ready {
            menu.addItem(item("Live checking needs your OK — Review…", #selector(askConsent)))
        }
        if !hotKeyOK { menu.addItem(item("⚠︎ \(s.hotKeyDisplay) is taken — change it in Settings", #selector(openSettings))) }
        if s.showUsageInMenu {
            let u = Usage.shared.summary(days: 1)
            menu.addItem(item("Today: \(u.calls) call\(u.calls == 1 ? "" : "s") · \(Usage.short(u.tokens)) tokens", #selector(openSettings)))
        }
        menu.addItem(.separator())

        menu.addItem(item("Correct Now\t\(s.triggerDisplay)", #selector(correctFromMenu), enabled: !busy && status == .ready && !s.isPaused))
        menu.addItem(item("Rewrite Selection…\t\(s.rewriteTrigger == "doubleShift" ? "⇧ ⇧" : "")", #selector(rewriteFromMenu), enabled: !busy && status == .ready && !s.isPaused))
        menu.addItem(item("Undo Last Correction\t\(s.undoDisplay)", #selector(undoFromMenu), enabled: last != nil))
        let live = item("Live Checking (Underlines)", #selector(toggleLive))
        live.state = s.liveChecking ? .on : .off
        menu.addItem(live)
        if s.liveChecking, let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, app.processIdentifier != getpid() {
            let name = app.localizedName ?? id
            let off = s.liveDisabledApps.contains(id)
            let per = item(off ? "    Turn On in \(name)" : "    Turn Off in \(name)", #selector(togglePerApp(_:)))
            per.representedObject = id
            menu.addItem(per)
        }
        let suggest = item("Show Suggestion Before Applying", #selector(toggleSuggest))
        suggest.state = s.suggestFirst ? .on : .off
        menu.addItem(suggest)
        menu.addItem(.separator())
        menu.addItem(item("Setup Guide…", #selector(openOnboarding)))
        menu.addItem(item("Copy Diagnostics…", #selector(copyDiagnostics)))
        if Updates.shared.isAvailable { menu.addItem(item("Check for Updates…", #selector(checkForUpdates))) }
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nib", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Accessory apps have no menu bar, but text fields need Edit shortcuts (⌘V into the key field).
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc private func openAX() { AppDelegate.openAccessibilitySettings() }
    @objc private func copyDiagnostics() {
        // Let the menu close, then count down while the user clicks into the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Diagnostics.copyAfterCountdown() }
    }

    @objc private func toggleSuggest() { Settings.shared.suggestFirst.toggle() }
    @objc private func toggleLive() {
        let s = Settings.shared
        if !s.liveChecking && !s.privacyConsent { Consent.ask() } else { s.liveChecking.toggle() }
        refreshIcon()
    }
    @objc private func askConsent() { Consent.ask(); refreshIcon() }
    @objc private func togglePerApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let s = Settings.shared
        if let i = s.liveDisabledApps.firstIndex(of: id) { s.liveDisabledApps.remove(at: i) } else { s.liveDisabledApps.append(id) }
    }

    /// Quits and reopens Nib (a new copy, after this one has gone). Used when macOS's Accessibility list
    /// holds a stale entry: after removing it, a fresh launch makes macOS list Nib again.
    static func relaunch(forAccessibility: Bool) {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let extra = forAccessibility ? " --args --relaunched-for-accessibility" : ""
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"\(extra)", path]
        do { try p.run() } catch { log("relaunch failed: \(error.localizedDescription)"); return }
        log("relaunching for Accessibility")
        NSApp.terminate(nil)
    }

    static func openAccessibilitySettings() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func makeWindow<V: View>(_ title: String, _ view: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        // No text field is focused when a Nib window opens, and focus is dropped when it stops being the key
        // window, so coming back to it (or Nib being brought forward) never resumes typing into a field.
        w.initialFirstResponder = nil
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { _ in
            w.makeFirstResponder(nil)
        }
        return w
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow("Nib Settings",
                                        SettingsView(m: SettingsModel(), keys: keys, onHotKeyChange: { [weak self] in self?.registerHotKey() },
                                                     onRewriteTriggerChange: { [weak self] in self?.applyRewriteTrigger() },
                                                     onPauseKeyChange: { [weak self] in self?.registerPauseKey() }))
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.makeFirstResponder(nil)
    }

    @objc func openOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow("Welcome to Nib", OnboardingView(m: OnboardingModel(), keys: keys, onDone: { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboarded")
                self?.onboardingWindow?.close()
            }))
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Icon

    enum IconState { case idle, working, error, done }

    private var iconState: IconState = .idle

    func setIcon(_ s: IconState) {
        iconState = s
        refreshIcon()
    }

    /// The nib: working (✨), needs attention (dot: no permission, no key, live checking paused, error) or off (slashed).
    func refreshIcon() {
        let state: NibIcon.MenuState
        switch iconState {
        case .working: state = .working
        case .error: state = .attention
        case .idle, .done:
            let liveError = LiveChecker.shared.lastError.map { Date().timeIntervalSince($0.at) < 900 } ?? false
            if Settings.shared.isPaused { state = .off }
            else if status != .ready || liveError { state = .attention }
            else if !Settings.shared.liveChecking { state = .off }
            else { state = .idle }
        }
        if currentMenuState != state {
            currentMenuState = state
            statusItem.button?.image = NibIcon.menuBar(state)
        }
    }
    private var currentMenuState: NibIcon.MenuState?

    // MARK: Correction

    @objc private func correctFromMenu() {
        // Let the menu close so focus is back in the target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.correctNow() }
    }

    @objc private func undoFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.undoLast() }
    }

    /// ✨ Rewrite the selection (chip, ⇧⇧ or the menu).
    func rewriteNow() {
        guard !Settings.shared.isPaused else { return }
        guard !busy, !RewriteController.shared.isVisible else { return }
        let inApp = NSApp.isActive && ((NSApp.keyWindow?.firstResponder as? NSTextView).map { $0.isEditable && !$0.isFieldEditor } ?? false)
        if !inApp && !AXIsProcessTrusted() {
            HUD.shared.show("Nib needs Accessibility access first.", style: .error, duration: 3)
            openOnboarding(); return
        }
        guard Settings.shared.apiKey != nil else { HUD.shared.show(AIError.noKey.describe(Settings.shared.provider), style: .error); openSettings(); return }
        HUD.shared.hide()
        SelectionChip.shared.hide()
        // One popup at a time.
        LiveChecker.shared.paused = true
        LiveChecker.shared.clear()
        if NSApp.isActive && !inApp {
            NSApp.hide(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { RewriteController.shared.start(inApp: false) }
        } else {
            RewriteController.shared.start(inApp: inApp)
        }
    }

    func applyRewriteTrigger() {
        if Settings.shared.rewriteTrigger == "doubleShift" && !Settings.shared.isPaused { DoubleTapMonitor.shift.start() } else { DoubleTapMonitor.shift.stop() }
    }

    @objc private func rewriteFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.rewriteNow() }
    }

    func correctNow() {
        guard !Settings.shared.isPaused else { return }
        if RewriteController.shared.isVisible { RewriteController.shared.close() }
        guard !busy else { return }
        if NSApp.isActive, !((NSApp.keyWindow?.firstResponder as? NSTextView).map { $0.isEditable && !$0.isFieldEditor } ?? false) {
            // One of our windows is in front but has no text box: hand focus back to the previous app first.
            NSApp.hide(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.correctNow() }
            return
        }
        let inApp = NSApp.isActive
        if !inApp && !AXIsProcessTrusted() {
            HUD.shared.show("Nib needs Accessibility access first.", style: .error, duration: 3)
            openOnboarding()
            return
        }
        guard Settings.shared.apiKey != nil else {
            HUD.shared.show(AIError.noKey.describe(Settings.shared.provider), style: .error)
            inApp ? openSettings() : openOnboarding()
            return
        }
        HUD.shared.hide()
        // One popup at a time: the live popup, its underlines, its Tab/esc keys and the ✨ chip go away first.
        Surfaces.shared.begin(.correcting)
        LiveChecker.shared.paused = true
        LiveChecker.shared.clear()

        let cap: Capture
        do { cap = try inApp ? TextAccess.captureInApp() : TextAccess.capture() } catch { fail(error, anchor: nil); return }
        // (fail() and finish() resume live checking.)

        // Send only the core text; keep surrounding whitespace exactly.
        let (lead, core, trail) = splitWhitespace(cap.text)
        guard core.count <= TextAccess.maxLength else { fail(CaptureError.tooLong(core.count), anchor: cap.anchor); return }

        busy = true
        LiveChecker.shared.paused = true
        LiveChecker.shared.clear()
        setIcon(.working)
        HUD.shared.show("Correcting…", style: .working, near: cap.anchor, duration: nil)
        let started = Date()

        Task { @MainActor in
            do {
                let fixed = try await Gemini.correct(core)
                NSLog("Nib: \(cap.appName) via \(cap.method.rawValue), \(core.count) chars, \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                if fixed == core {
                    lastRoute = "\(cap.method.rawValue) (no changes)"
                    finish("No changes needed", style: .info, anchor: cap.anchor)
                    return
                }
                let n = WordDiff.issueCount(core, fixed)
                let replacement = lead + fixed + trail
                if Settings.shared.suggestFirst {
                    busy = false
                    setIcon(.idle)
                    // One popup at a time: live checking stays paused (no underlines, no popup, no Tab/esc keys)
                    // until the panel closes, then picks the field up again.
                    LiveChecker.shared.paused = true
                    LiveChecker.shared.clear()
                    Surfaces.shared.begin(.suggestion)
                    HUD.shared.onSuggestionClosed = {
                        Surfaces.shared.end(.suggestion)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !self.busy { LiveChecker.shared.paused = false } }
                    }
                    // Below the field when it's small enough, else below the caret line, so the line being edited stays visible.
                    let panelAnchor = cap.fieldFrame.flatMap { $0.height <= 220 ? $0 : nil } ?? cap.anchor
                    HUD.shared.showSuggestion(original: core, corrected: fixed, near: panelAnchor,
                                              accept: { [weak self] in self?.apply(cap, replacement, n) },
                                              reject: {})
                    return
                }
                apply(cap, replacement, n)
            } catch {
                fail(error, anchor: cap.anchor)
            }
        }
    }

    private func apply(_ cap: Capture, _ replacement: String, _ n: Int) {
        do {
            let how = try TextAccess.replace(cap, with: replacement)
            log("replaced via \(how)")
            LiveChecker.shared.noteNibWrite(original: cap.text, written: replacement)
            lastRoute = "\(cap.method.rawValue) → \(how)"
            last = LastCorrection(capture: cap, original: cap.text, corrected: replacement, via: how)
            finish("Fixed \(n) issue\(n == 1 ? "" : "s") · \(Settings.shared.undoDisplay) to undo", style: .success, anchor: cap.anchor)
        } catch {
            fail(error, anchor: cap.anchor)
        }
    }

    func undoLast() {
        guard !busy else { return }
        guard let last else { HUD.shared.show(CaptureError.nothingToUndo.localizedDescription, style: .info); return }
        do {
            let how = try TextAccess.undo(last)
            log("undo via \(how)")
            LiveChecker.shared.noteNibWrite(original: last.corrected, written: last.original)
            self.last = nil
            HUD.shared.show("Restored the original text", style: .success, near: last.capture.anchor, duration: 1.6)
        } catch {
            fail(error, anchor: last.capture.anchor)
        }
    }

    private func finish(_ msg: String, style: HUDStyle, anchor: NSRect?) {
        busy = false
        Surfaces.shared.end(.correcting)
        LiveChecker.shared.paused = false
        setIcon(.done)
        HUD.shared.show(msg, style: style, near: anchor, duration: style == .success ? 2.5 : 1.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if !self.busy { self.setIcon(.idle) } }
    }

    private func fail(_ error: Error, anchor: NSRect?) {
        busy = false
        Surfaces.shared.end(.correcting)
        LiveChecker.shared.paused = false
        setIcon(.error)
        log("error: \(error.localizedDescription)")
        lastError = error.localizedDescription
        HUD.shared.show(error.localizedDescription, style: .error, near: anchor, duration: 3.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if !self.busy { self.setIcon(.idle) } }
    }

    private func splitWhitespace(_ s: String) -> (String, String, String) {
        let chars = Array(s)
        var start = 0, end = chars.count
        while start < end, chars[start].isWhitespace { start += 1 }
        while end > start, chars[end - 1].isWhitespace { end -= 1 }
        return (String(chars[..<start]), String(chars[start..<end]), String(chars[end...]))
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = self.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

@main
enum Main {
    static func main() {
        // CLI test mode: GrammarAI --correct "text"  (or text on stdin)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test-model"), i + 1 < args.count {
            // Test runs: use this model, in memory only.
            Settings.shared.persist = false
            Settings.shared.models[Settings.shared.provider.rawValue] = args[i + 1]
            Settings.shared.privacyConsent = true
        }
        if args.contains("--allow-code-editors") {
            // Test runs: switch the experimental code-editor underlines on, in memory only.
            Settings.shared.persist = false
            Settings.shared.allowCodeEditors = true
            Settings.shared.privacyConsent = true
        }
        if args.contains("--e2e") {
            // A test copy: settings in memory only, never paused, and the user's macOS text settings untouched.
            Settings.shared.persist = false
            Settings.shared.pausedUntil = nil
            SystemTextChecking.disabled = true
            Settings.shared.privacyConsent = true
        }
        if args.count > 1 && args[1].hasPrefix("--") && !args.contains("--e2e") && !args.contains("--relaunched-for-accessibility") {
            Keychain.migrate = false
        }
        if let i = args.firstIndex(of: "--correct-temp"), i + 1 < args.count, let t = Double(args[i + 1]) { Gemini.correctTemperature = t }
        if let i = args.firstIndex(of: "--detect"), i + 1 < args.count {
            print(Lang.detect(args[i + 1], hints: ["en", "zh", "ko"]) ?? "nil"); exit(0)
        }
        if let i = args.firstIndex(of: "--eval-merge"), i + 2 < args.count {
            Eval.merge(run: URL(fileURLWithPath: args[i + 1]), verdicts: URL(fileURLWithPath: args[i + 2]),
                       judgeName: args.firstIndex(of: "--judge-name").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "judge")
            exit(0)
        }
        if args.contains("--eval") {
            setvbuf(stdout, nil, _IONBF, 0)
            let sem = DispatchSemaphore(value: 0)
            Task.detached { await Eval.run(args); sem.signal() }
            sem.wait()
            exit(0)
        }
        if let i = args.firstIndex(of: "--ai-check"), i + 1 < args.count, let p = Provider(rawValue: args[i + 1]) {
            // Checks a provider without touching the saved settings: connection, model list, structured output.
            func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            let s = Settings.shared
            s.persist = false // nothing below is saved
            if let r = opt("--region") { if p == .qwen { s.qwenRegion = r } else if p == .vertex { s.vertexRegion = r } }
            if let pr = opt("--project") { s.vertexProject = pr }
            if let u = opt("--base-url") { s.customBaseURL = u }
            let ep = AIEndpoint(provider: p, model: opt("--model") ?? s.model(for: p), key: opt("--key") ?? s.key(for: p))
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let t0 = Date()
                do {
                    try await AI.test(ep)
                    let u = Usage.lastParsed
                    let tok = u.map { $0.reported ? "tokens \($0.input ?? 0) in / \($0.output ?? 0) out\($0.thinking.map { " / \($0) thinking" } ?? "")" : "tokens not reported" } ?? "no usage parsed"
                    print("[\(p.rawValue)] test connection: OK (\(ep.model), \(String(format: "%.2f", Date().timeIntervalSince(t0)))s, \(tok))")
                }
                catch { print("[\(p.rawValue)] test connection: Not working: \(error.localizedDescription)") }
                do { let m = try await AI.listModels(ep); print("[\(p.rawValue)] load models: \(m.count) — \(m.prefix(6).joined(separator: ", "))\(m.count > 6 ? ", …" : "")") }
                catch { print("[\(p.rawValue)] load models: Not working: \(error.localizedDescription)") }
                if !args.contains("--quick") {
                    let schema: [String: Any] = ["type": "object", "properties": ["issues": ["type": "array", "items": ["type": "object",
                        "properties": ["text": ["type": "string"], "fix": ["type": "string"]], "required": ["text", "fix"]]]], "required": ["issues"]]
                    do {
                        let t1 = Date()
                        let out = try await AI.complete(AIRequest(system: "List spelling/grammar mistakes as JSON {\"issues\": [{\"text\", \"fix\"}]}.",
                                                                  user: "He dont know where the files is.", temperature: 0, schema: schema, timeout: 20), ep)
                        print("[\(p.rawValue)] structured issues: \(AI.sanitise(out)) (\(String(format: "%.2f", Date().timeIntervalSince(t1)))s)")
                    } catch { print("[\(p.rawValue)] structured issues: Not working: \(error.localizedDescription)") }
                    // The app's own paths with this provider (in memory): live proofread, ⌥⌥ correct, rewrite.
                    s.provider = p
                    s.models[p.rawValue] = ep.model
                    func tok() -> String {
                        guard let u = Usage.lastParsed else { return "no usage" }
                        return u.reported ? "\(u.input ?? 0) in / \(u.output ?? 0) out\(u.thinking.map { " / \($0) thinking" } ?? "")" : "tokens not reported"
                    }
                    func timed(_ name: String, _ body: () async throws -> String) async {
                        Usage.lastParsed = nil
                        let t = Date()
                        do { let r = try await body(); print("[\(p.rawValue)] \(name): \(r) (\(String(format: "%.2f", Date().timeIntervalSince(t)))s, \(tok()))") }
                        catch { print("[\(p.rawValue)] \(name): Not working: \(error.localizedDescription)") }
                    }
                    await timed("proofread") { try await Gemini.proofread("They was late and he dont know why.").map { "\($0.text) → \($0.fix)" }.joined(separator: "; ") }
                    await timed("proofread (ko)") { try await Gemini.proofread("저는 한국어를 공부할수 있어요.").map { "\($0.text) → \($0.fix)" }.joined(separator: "; ") }
                    await timed("proofread (zh)") { try await Gemini.proofread("我明天在来找你，好吗？").map { "\($0.text) → \($0.fix)" }.joined(separator: "; ") }
                    await timed("correct") { try await Gemini.correct("She dont like it, and their late.").debugDescription }
                    await timed("rewrite") {
                        let style = RewriteStyles.builtIns.first { $0.id == "concise" }!
                        return try await Gemini.rewrite("I wanted to let you know that we have decided to move the launch from March 3 to March 17.", style: style).debugDescription
                    }
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if let i = args.firstIndex(of: "--correct") {
            let input = i + 1 < args.count ? args[i + 1] : (String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "")
            let sem = DispatchSemaphore(value: 0)
            var code: Int32 = 0
            Task.detached {
                do { print(try await Gemini.correct(input)) }
                catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); code = 1 }
                sem.signal()
            }
            sem.wait()
            exit(code)
        }
        if let i = args.firstIndex(of: "--proofread"), i + 1 < args.count {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                do { for x in try await Gemini.proofread(args[i + 1]) { print("[\(x.kind)] \(x.text.debugDescription) → \(x.fix.debugDescription) (\(x.reason))\(x.example.isEmpty ? "" : "  e.g. \(x.example)")") } }
                catch { print("error:", error.localizedDescription) }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if let i = args.firstIndex(of: "--rewrite"), i + 2 < args.count {
            let style = Settings.shared.rewriteStyles.first { $0.id == args[i + 1] } ?? RewriteStyles.builtIns[0]
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                do { print(try await Gemini.rewrite(args[i + 2], style: style)) } catch { print("error:", error.localizedDescription) }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if let i = args.firstIndex(of: "--make-icons"), i + 1 < args.count { NibIcon.writeAll(to: args[i + 1]); exit(0) }
        if let i = args.firstIndex(of: "--pause-for"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            // Test helper: store a pause ending in N seconds (takes effect at the next launch).
            Settings.shared.pausedUntil = Date().addingTimeInterval(secs)
            UserDefaults.standard.synchronize()
            exit(0)
        }
        if args.contains("--autocorrect-probe") { AutocorrectProbe.run() }
        if args.contains("--text-checking-probe") {
            // Reports what AppKit sees in this process. Pass `-Key NO` arguments (argument domain only,
            // nothing persistent) to learn which preference keys drive which behaviour.
            _ = NSApplication.shared
            let tv = NSTextView(frame: .zero)
            tv.isContinuousSpellCheckingEnabled = true
            tv.isGrammarCheckingEnabled = true
            print("spellingCorrection=\(NSSpellChecker.isAutomaticSpellingCorrectionEnabled) textCompletion=\(NSSpellChecker.isAutomaticTextCompletionEnabled) inlinePrediction=\({ if #available(macOS 14, *) { return NSSpellChecker.isAutomaticInlinePredictionEnabled } else { return false } }()) textViewContinuous=\(tv.isContinuousSpellCheckingEnabled) textViewGrammar=\(tv.isGrammarCheckingEnabled)")
            if #available(macOS 15.4, *) {
                let tf = NSTextField(frame: .zero)
                print("textViewWritingToolsBehavior=\(tv.writingToolsBehavior.rawValue) textFieldAllowsWritingTools=\(tf.allowsWritingTools) textFieldAffordance=\(tf.allowsWritingToolsAffordance) autocorrect=\(NSSpellChecker.isAutomaticSpellingCorrectionEnabled)")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
            // Registers / unregisters THIS bundle (wherever it's installed) as a login item.
            do {
                switch args[i + 1] {
                case "on": try SMAppService.mainApp.register()
                case "off": try SMAppService.mainApp.unregister()
                default: break
                }
                print("login item: \(SMAppService.mainApp.status == .enabled ? "on" : "off") (status \(SMAppService.mainApp.status.rawValue)) for \(Bundle.main.bundlePath)")
            } catch { print("login item error: \(error.localizedDescription)") }
            exit(0)
        }
        if args.contains("--electron-scan") {
            // Which installed apps Nib treats as Electron (bundle check only).
            let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
            for d in dirs {
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).sorted() where name.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: d).appendingPathComponent(name)
                    if TextAccess.isElectronBundle(url) {
                        let id = Bundle(url: url)?.bundleIdentifier ?? "?"
                        print("Electron: \(name) (\(id))\(TextAccess.copyLineBundleIDs.contains(id) ? " — code editor, excluded from underlines" : "")")
                    }
                }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--probe-app"), i + 1 < args.count {
            _ = NSApplication.shared
            print(Diagnostics.probe(bundleID: args[i + 1]))
            exit(0)
        }
        if args.contains("--diagnose") {
            // Privacy-safe report on the focused field of the frontmost app (no text). Needs Accessibility for the
            // process running it: from Terminal that's Terminal's permission; the menu item uses Nib's own.
            setvbuf(stdout, nil, _IONBF, 0)
            let delay = args.firstIndex(of: "--delay").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 5
            _ = NSApplication.shared
            for n in stride(from: delay, to: 0, by: -1) { print("Click into the text field you want checked… \(n)"); sleep(1) }
            print(Diagnostics.report())
            exit(0)
        }
        if args.contains("--system-text-status") { print(SystemTextChecking.describe(), "suppressing=\(SystemTextChecking.isSuppressing)"); exit(0) }
        if args.contains("--diff-selftest") { DiffSelfTest.run(); exit(0) }
        if args.contains("--ax-selftest") { AXSelfTest.run() }
        if args.contains("--marker-selftest") { MarkerSelfTest.run() }
        if args.contains("--live-selftest") { LiveSelfTest.run() }
        if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count { UIRender.run(dir: args[i + 1]) }
        if args.contains("--ax-webtest") { AXWebTest.run(contentEditable: args.contains("--ce")) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

enum DiffSelfTest {
    static func run() {
        // ⌘⌘ / ⇧⇧ / ⌥⌥ monitors map real key events to taps; anything else cancels.
        func flags(_ code: UInt16, _ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        let cmd = DoubleTapMonitor.command
        let mapCases: [(String, DoubleTapDetector.Input, DoubleTapDetector.Input)] = [
            ("⌘ down", cmd.input(for: flags(55, [.command])), .optionDown),
            ("⌘ up", cmd.input(for: flags(55, [])), .optionUp),
            ("right ⌘ down", cmd.input(for: flags(54, [.command])), .optionDown),
            ("⌘ while ⇧ held (⌘⇧…)", cmd.input(for: flags(55, [.command, .shift])), .other),
            ("⌥ key for the ⌘ monitor", cmd.input(for: flags(58, [.option])), .other),
            ("⌥ down for the ⌥ monitor", DoubleTapMonitor.shared.input(for: flags(58, [.option])), .optionDown),
            ("⇧ down for the ⇧ monitor", DoubleTapMonitor.shift.input(for: flags(56, [.shift])), .optionDown),
        ]
        for (name, got, want) in mapCases { print("tap mapping \(got == want ? "OK" : "FAIL"): \(name)") }
        // ⌘C between two ⌘ taps (the C keyDown) cancels, like any other key.
        var d = DoubleTapDetector(); let t0 = Date()
        let seq: [(DoubleTapDetector.Input, Double)] = [(.optionDown, 0), (.other, 40), (.optionUp, 90), (.optionDown, 200), (.optionUp, 260)]
        let fired = seq.contains { d.feed($0.0, at: t0.addingTimeInterval($0.1 / 1000)) }
        print("tap mapping \(fired ? "FAIL" : "OK"): ⌘C then ⌘ tap doesn't pause")

        for (name, ok) in Keychain.selfTest() { print("keychain \(ok ? "OK" : "FAIL"): \(name)") }
        for (name, ok) in SystemTextSelfTest.run() { print("system text \(ok ? "OK" : "FAIL"): \(name)") }

        // Regression (2.0.11–2.0.14 broke Slack): Monaco's main-editor test must never match Slack's composer.
        do {
            typealias M = Monaco
            let cases: [(String, Bool, Bool)] = [
                ("Slack composer 927×38, one line", M.mainEditorShape(isCodeEditor: false, frame: CGRect(x: 694, y: 823, width: 927, height: 38), text: "he doont know where the files is", description: ""), false),
                ("Slack composer 927×38 with a newline", M.mainEditorShape(isCodeEditor: false, frame: CGRect(x: 694, y: 823, width: 927, height: 38), text: "he doont know\nwhere the files is\n", description: ""), false),
                ("Chrome contenteditable 3424×32", M.mainEditorShape(isCodeEditor: false, frame: CGRect(x: 8, y: 130, width: 3424, height: 32), text: "line one\n", description: ""), false),
                ("VS Code main editor 658×18, whole file", M.mainEditorShape(isCodeEditor: true, frame: CGRect(x: 1239, y: 410, width: 658, height: 18), text: "Meeting notes\n\ni has went", description: "Editor"), true),
                ("Cursor main editor 918×26, whole file", M.mainEditorShape(isCodeEditor: true, frame: CGRect(x: 1286, y: 996, width: 918, height: 26), text: "a\nb\nc", description: ""), true),
                ("VS Code side box 240×20, one line", M.mainEditorShape(isCodeEditor: true, frame: CGRect(x: 2872, y: 858, width: 240, height: 20), text: "commit message", description: ""), false),
                ("AXTextArea is not a control role", !TextTarget.isControlRole("AXTextArea") && !TextTarget.isControlRole("AXTextField") && !TextTarget.isControlRole("AXGroup"), true),
                ("AXButton is a control role", TextTarget.isControlRole("AXButton"), true),
                ("a per-field 'no positions' answer is kept for 5 s", TextMarkers.fresh(Date(timeIntervalSinceNow: -5)), true),
                ("a per-field 'no positions' answer expires after 10 s (Slack's tree may come later)", TextMarkers.fresh(Date(timeIntervalSinceNow: -11)), false),
                ("tree re-assert allowed the first time", TextTarget.mayReassert(last: nil), true),
                ("tree re-assert throttled within 5 s", TextTarget.mayReassert(last: Date(timeIntervalSinceNow: -2)), false),
                ("tree re-assert allowed again after 5 s", TextTarget.mayReassert(last: Date(timeIntervalSinceNow: -6)), true),
            ]
            for (name, got, want) in cases { print("regression \(got == want ? "OK" : "FAIL"): \(name)") }
        }

        // Code editors: which files count as prose.
        do {
            let cases: [(String?, Bool)] = [("notes.md", true), ("README.markdown", true), ("todo.txt", true), ("Untitled-1", true),
                                            ("index.rst", true), ("main.swift", false), ("app.py", false), ("package.json", false), (nil, false)]
            let ok = cases.allSatisfy { Monaco.isProse($0.0) == $0.1 }
            print("code editors \(ok ? "OK" : "FAIL"): prose files (.md/.markdown/.txt/.rst/untitled) checked, code files and unknown skipped")
        }

        // Code editors: file names from window titles, and the prose rule's edge cases.
        do {
            let titles: [(String, String?)] = [("● notes.md — project — Visual Studio Code", "notes.md"),
                ("[Restricted Mode] notes.md - project - Visual Studio Code", "notes.md"), ("README — project — Visual Studio Code", "README"),
                ("notes.md (Working Tree) — project", "notes.md"), ("Untitled-1 — Visual Studio Code", "Untitled-1")]
            for (t, want) in titles { print("code editors \(Monaco.fileName(fromTitle: t) == want ? "OK" : "FAIL"): title → \(want ?? "nil")") }
            let prose: [(String?, Bool, Bool)] = [("README", true, true), ("Makefile", true, false), ("notes.log", true, false),
                ("Meeting notes", false, true), (".env", true, false), ("draft.tex", true, true), ("notes.MD", true, true)]
            for (f, disk, want) in prose { print("code editors \(Monaco.isProse(f, onDisk: disk) == want ? "OK" : "FAIL"): \(f ?? "nil")\(disk ? "" : " (unsaved)") prose = \(want)") }
        }

        // Monaco: visible lines matched to the textarea's text by content.
        do {
            typealias P = TextMarkers.Piece
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 50) -> CGRect { CGRect(x: x, y: y, width: w, height: 18) }
            let full = "# Heading\n\nShe go to school.\nfourth line words\nfifth line here"
            let ns = full as NSString
            // Scrolled, Markdown tokens, line numbers, nbsp, and a line outside the textarea's page.
            let pieces = [P(text: "3", frame: r(0, 100, 10)), P(text: "She\u{00A0}go\u{00A0}to", frame: r(40, 100)), P(text: " school.", frame: r(90, 100)),
                          P(text: "4", frame: r(0, 120, 10)), P(text: "not in this page", frame: r(40, 120)),
                          P(text: "fifth line here", frame: r(40, 140))]
            let (starts, m) = TextMarkers.matchLines(pieces, in: full)
            let a = starts[1] == ns.range(of: "She go").location && starts[2] == ns.range(of: " school.").location
                && starts[0] == nil && starts[4] == nil && starts[5] == ns.range(of: "fifth").location && m.visualLines == 3 && m.matchedLines == 2
            print("monaco lines \(a ? "OK" : "FAIL"): scrolled view, tokens, nbsp, line numbers skipped, a line outside the page skipped (matched \(m.matchedLines)/\(m.visualLines))")
            // Highlighted heading split into tokens, with the whitespace token missing from the tree.
            let (s2, m2) = TextMarkers.matchLines([P(text: "#", frame: r(40, 10, 8)), P(text: "Heading", frame: r(58, 10))], in: full)
            print("monaco lines \(s2 == [0, 2] && m2.matchedLines == 1 ? "OK" : "FAIL"): heading tokens without the space token")
            // Only the visible lines are checked.
            let vis = m.visibleRanges.map { ns.substring(with: $0) }
            print("monaco lines \(vis == ["She go to school.", "fifth line here"] ? "OK" : "FAIL"): visible lines are what gets checked")
            // A short line ("-") far ahead must not derail the lines after it.
            let (s3, _) = TextMarkers.matchLines([P(text: "-", frame: r(40, 10, 8)), P(text: "She go to school.", frame: r(40, 30))], in: full + "\n\n\n\n-")
            print("monaco lines \(s3[0] == nil && s3[1] == ns.range(of: "She go").location ? "OK" : "FAIL"): a short line far ahead is ignored")
        }

        // VS Code's native EditContext: positions computed from the cursor's row and the character width.
        do {
            let text = "# Meeting notes\n\n## Section 1\n\nShe go to the shops.\naaaa bbbb cccc dddd eeee ffff"
            let ns = text as NSString
            let cursor = ns.range(of: "## Section").location + 3 // line 3 (index 2)
            let g = Monaco.Geometry(rowTop: 156, left: 119, lineHeight: 18, charWidth: 7, wrapColumns: 20, cursor: cursor)
            let a = Monaco.rects(text: text, range: ns.range(of: "She go"), g)
            print("monaco geometry \(a == [CGRect(x: 119, y: 192, width: 42, height: 18)] ? "OK" : "FAIL"): a line below the cursor")
            let b = Monaco.rects(text: text, range: ns.range(of: "Meeting"), g)
            print("monaco geometry \(b == [CGRect(x: 133, y: 120, width: 49, height: 18)] ? "OK" : "FAIL"): a line above the cursor")
            let c = Monaco.rects(text: text, range: ns.range(of: "eeee"), g)
            print("monaco geometry \(c == [CGRect(x: 119, y: 228, width: 28, height: 18)] ? "OK" : "FAIL"): word wrap moves a word to the next row")
            let d = Monaco.rects(text: text, range: ns.range(of: "dddd eeee"), g)
            print("monaco geometry \(d.count == 2 && d[0].minY == 210 && d[1].minY == 228 ? "OK" : "FAIL"): a range across a wrap gets one rect per row")
        }

        // Floating cards stay on screen: anchors at each edge of a 1440×900 visible frame (origin 0,25).
        do {
            let vf = NSRect(x: 0, y: 25, width: 1440, height: 875)
            let size = NSSize(width: 500, height: 160) // includes 10 pt transparent padding
            let cases: [(String, NSPoint)] = [("left edge", NSPoint(x: -60, y: 400)), ("right edge", NSPoint(x: 1300, y: 400)),
                                              ("bottom edge", NSPoint(x: 600, y: -40)), ("top edge", NSPoint(x: 600, y: 880)),
                                              ("bottom-left corner", NSPoint(x: -200, y: -200)), ("top-right corner", NSPoint(x: 1400, y: 950))]
            for (name, o) in cases {
                let f = CardPlacement.clamp(NSRect(origin: o, size: size), padding: 10, in: vf).insetBy(dx: 10, dy: 10)
                let ok = vf.insetBy(dx: 8, dy: 8).contains(f) && f.width == 480 && f.height == 140
                print("card placement \(ok ? "OK" : "FAIL"): anchor at the \(name) → card fully on screen with an 8 pt margin")
            }
            let inside = NSRect(x: 300, y: 300, width: 500, height: 160)
            print("card placement \(CardPlacement.clamp(inside, padding: 10, in: vf) == inside ? "OK" : "FAIL"): a card already on screen doesn't move")
        }

        // Long spans: the change shown in place, the lone "?" kept visible.
        do {
            typealias S = InlineDiff.Seg
            let a = "Could you send it, when you have read the notes.", b = "Could you send it when you have read the notes?"
            let segs = InlineDiff.segments(a, b)
            let want: [S] = [.same("Could you send it"), .removed(","), .same(" when you have read the notes"), .removed("."), .added("?")]
            print("inline diff \(segs == want ? "OK" : "FAIL"): punctuation-only edits refined to characters")
            let c = InlineDiff.compact(segs)
            print("inline diff \(InlineDiff.plain(c) == "… you send it, when you have read the notes.?" ? "OK" : "FAIL"): long unchanged text shortened (\(InlineDiff.plain(c)))")
            let long = InlineDiff.compact([.same("one two three four five six seven eight nine ten "), .removed("was"), .added("were"), .same(" one two three four five six seven eight nine ten")])
            print("inline diff \(InlineDiff.plain(long) == "… eight nine ten waswere one two three …" ? "OK" : "FAIL"): both ends shortened to three words (\(InlineDiff.plain(long)))")
            print("inline diff \(InlineDiff.refine("was", "were") == [.removed("was"), .added("were")] ? "OK" : "FAIL"): a changed word stays whole")
            print("inline diff \(InlineDiff.refine("apple", "apples") == [.same("apple"), .removed(""), .added("s"), .same("")] ? "OK" : "FAIL"): an added ending is refined")
        }

        // Privacy notice: names the provider and says live checking sends paragraphs as you type.
        do {
            let n = Consent.notice(.claude)
            let ok = n.contains("Claude (Anthropic)") && n.contains("paragraphs as you type") && n.contains("never contains your text")
            print("privacy \(ok ? "OK" : "FAIL"): the notice names the provider and what live checking sends")
        }

        // Usage statistics: each provider's usage format, missing usage, totals, the 1,000-call cap.
        do {
            let g = UsageParse.gemini(["usageMetadata": ["promptTokenCount": 812, "candidatesTokenCount": 64, "thoughtsTokenCount": 30, "totalTokenCount": 906]])
            print("usage \(g == TokenUsage(input: 812, output: 64, thinking: 30) ? "OK" : "FAIL"): Gemini usageMetadata (thoughts counted separately)")
            let a = UsageParse.anthropic(["usage": ["input_tokens": 500, "cache_read_input_tokens": 100, "output_tokens": 42]])
            print("usage \(a == TokenUsage(input: 600, output: 42, thinking: nil) ? "OK" : "FAIL"): Anthropic usage (cache reads count as input)")
            let o = UsageParse.openAI(["usage": ["prompt_tokens": 300, "completion_tokens": 120, "completion_tokens_details": ["reasoning_tokens": 100]]])
            print("usage \(o == TokenUsage(input: 300, output: 20, thinking: 100) ? "OK" : "FAIL"): OpenAI usage (reasoning taken out of completion)")
            let d = UsageParse.openAI(["usage": ["prompt_tokens": 50, "completion_tokens": 9]])
            print("usage \(d == TokenUsage(input: 50, output: 9, thinking: nil) ? "OK" : "FAIL"): OpenAI-compatible usage without reasoning details")
            let none = UsageParse.openAI(["choices": []])
            print("usage \(!none.reported && UsageParse.gemini([:]) == TokenUsage() ? "OK" : "FAIL"): missing usage → not reported")

            let u = Usage(url: nil)
            let now = Date()
            u.add(.live, provider: "Gemini", model: "m1", g, at: now)
            u.add(.correct, provider: "Gemini", model: "m1", none, at: now)
            u.add(.rewrite, provider: "Claude", model: "m2", a, at: Calendar.current.date(byAdding: .day, value: -3, to: now)!)
            u.add(.live, provider: "Gemini", model: "m1", d, at: Calendar.current.date(byAdding: .day, value: -20, to: now)!)
            let t = u.summary(days: 1, now: now), w = u.summary(days: 7, now: now), m = u.summary(days: 30, now: now)
            let ok = t.calls == 2 && t.unreported == 1 && t.input == 812 && t.thinking == 30 && w.calls == 3 && w.byModel.count == 2
                && m.calls == 4 && m.byFeature.first(where: { $0.0 == .live })?.1 == 2
            print("usage \(ok ? "OK" : "FAIL"): today / 7 days / 30 days totals, by feature and by model")
            for _ in 0..<1005 { u.add(.test, provider: "Gemini", model: "m1", d, at: now) }
            let csv = u.csv().split(separator: "\n")
            print("usage \(csv.count == 1001 && csv[0].hasPrefix("time,feature,provider,model") ? "OK" : "FAIL"): the last 1,000 calls kept; CSV header and rows (\(csv.count - 1) rows)")
        }

        // Prompt-eval scoring: span extent doesn't matter, alternatives count, false flags and violations.
        do {
            typealias E = Eval.ExpectedIssue
            func pc(_ text: String, _ issues: [E], mustNotChange: Bool = false, protected: [String] = []) -> Eval.ProofCase {
                Eval.ProofCase(id: "t", split: "dev", category: "t", text: text, issues: issues, protected: protected, mustNotChange: mustNotChange)
            }
            let c1 = pc("They was waiting outside.", [E(span: "was", fixes: ["were"], kind: "grammar")])
            let a = Eval.score(c1, issues: [Issue(kind: "grammar", text: "They was", fix: "They were", reason: "")])
            let b = Eval.score(c1, issues: [Issue(kind: "grammar", text: "was", fix: "is", reason: "")])
            print("eval scoring \(a.fixed == 1 && a.falseFlags == 0 && b.found == 1 && b.fixed == 0 ? "OK" : "FAIL"): a wider span with the right fix counts; a wrong fix doesn't")
            let c2 = pc("Can you send it by Friday.", [E(span: "Friday.", fixes: ["Friday?"], kind: "grammar", alts: [.init(span: ".", fix: "?")])])
            let d = Eval.score(c2, issues: [Issue(kind: "grammar", text: ".", fix: "?", reason: "")])
            print("eval scoring \(d.fixed == 1 ? "OK" : "FAIL"): an alternative span and fix count")
            let c3 = pc("See https://example.com today.", [], mustNotChange: true, protected: ["https://example.com"])
            let f = Eval.score(c3, issues: [Issue(kind: "spelling", text: "https://example.com", fix: "https://example.org", reason: "")])
            print("eval scoring \(f.falseFlags == 1 && f.violations == 2 ? "OK" : "FAIL"): a flag on must-not-change text touching a protected part is a violation")
        }

        // Spans are found as whole words first; code-like spans are guarded; `code` in ⌥⌥ output is restored.
        do {
            let ns = "Ich habe gestern ein Auto gekauft und er ist schnell." as NSString
            print("spans \(Gemini.spanRange("er", in: ns).location == ns.range(of: " er ").location + 1 ? "OK" : "FAIL"): “er” is found as a word, not inside “gestern”")
            let t = "Check README.md and recieve_data() in utils.py, see https://example.com or ask @maria in #dev. Then end.Next" as NSString
            let code = ["recieve_data()", "README.md", "utils.py", "https://example.com", "@maria", "#dev"].allSatisfy { Gemini.looksLikeCode($0, in: t) }
            let prose = ["Check", "end.Next", "ask"].allSatisfy { !Gemini.looksLikeCode($0, in: t) }
            print("code guard \(code && prose ? "OK" : "FAIL"): identifiers, files, URLs, mentions guarded; prose (and a missing space) not")
            let inTicks = "Run `git pul` now" as NSString
            print("code guard \(Gemini.looksLikeCode("pul", in: inTicks) ? "OK" : "FAIL"): a word inside backticks is guarded")
            let restored = Gemini.restoringCode("Run `git pull` and then restart.", original: "Run `git pul` and then restart.")
            print("code guard \(restored == "Run `git pul` and then restart." ? "OK" : "FAIL"): ⌥⌥ puts `code` back as it was")
        }

        // Built-in styles saved with an earlier (unedited) text get the current one; edited ones are kept.
        do {
            let old = RewriteStyles.previousInstructions["apology"]![0]
            let saved = [RewriteStyle(id: "apology", name: "Apology", instruction: old, builtIn: true),
                         RewriteStyle(id: "sales", name: "Sales & outreach", instruction: "My own sales text", builtIn: true)]
            let loaded = RewriteStyles.load(from: RewriteStyles.encode(saved))
            let apology = loaded.first { $0.id == "apology" }!.instruction, sales = loaded.first { $0.id == "sales" }!.instruction
            let ok = apology == RewriteStyles.builtIns.first { $0.id == "apology" }!.instruction && apology != old && sales == "My own sales text"
            print("rewrite styles \(ok ? "OK" : "FAIL"): unedited built-in styles get the improved text; edited ones are kept")
        }

        // Chinese and Korean: language detection, wide characters in VS Code geometry and text runs, live-check threshold.
        do {
            let hints = ["en", "zh", "ko"]
            let det: [(String, String?, String)] = [
                ("저는 한국어를 공부할 수 있어요.", nil, "ko"), ("我明天再来找你，好吗？", nil, "zh-Hans"),
                ("這個問題我們已經討論過了，但是他還是不明白。", nil, "zh-Hant"), ("The quarterly report is attached for your review.", nil, "en"),
                ("ok", "ko", "ko")]
            for (t, prev, want) in det {
                let got = Lang.detect(t, previous: prev, hints: hints)
                print("language \(got == want ? "OK" : "FAIL"): \(want) detected (\(got ?? "nil"))")
            }
            print("wide chars \(Monaco.columns("한국어") == 6 && Monaco.columns("ab中") == 4 && Monaco.columns("a\tb") == 6 ? "OK" : "FAIL"): Hangul and Han count two columns")
            let rows = Monaco.rowStarts("가나다라마바사아자차" as NSString, cols: 8)
            print("wide chars \(rows == [0, 4, 8] ? "OK" : "FAIL"): CJK text without spaces wraps by columns (\(rows))")
            let g = Monaco.Geometry(rowTop: 100, left: 10, lineHeight: 18, charWidth: 7, wrapColumns: 80, cursor: 0)
            let r = Monaco.rects(text: "가나 abc", range: ("가나 abc" as NSString).range(of: "abc"), g)
            print("wide chars \(r.first?.minX == 10 + 5 * 7 ? "OK" : "FAIL"): a word after Hangul is placed after their double width")
            let (x0, _) = TextMarkers.proportionalSpan("가나ab", NSRange(location: 2, length: 2), width: 100)
            print("wide chars \(x0 > 55 ? "OK" : "FAIL"): text-run placement measures widths (\(Int(x0)) of 100, not 50)")
            print("live check \(LiveChecker.worthChecking("我明天再来找你") && !LiveChecker.worthChecking("ok go") ? "OK" : "FAIL"): Chinese without spaces is checked; two words aren't")
            let st = Settings.shared, saved = (st.persist, st.writingLanguages, st.checkOtherLanguages)
            st.persist = false; st.writingLanguages = ["en"]; st.checkOtherLanguages = false
            let ok = Lang.isChecked("en") && !Lang.isChecked("ko") && !Lang.isChecked("xx") && Lang.isChecked(nil)
            st.writingLanguages = saved.1; st.checkOtherLanguages = saved.2; st.persist = saved.0
            print("languages \(ok ? "OK" : "FAIL"): Settings → Languages decides what live checking checks")
            let note = { () -> String in Gemini.languageAware = true; return Gemini.languageNote("ko") }()
            print("languages \(note.contains("Korean (ko)") && note.contains("띄어쓰기") && !Gemini.languageNote("de").contains("Korean") ? "OK" : "FAIL"): the language line and only that language's rules are added")
        }

        // Oversized fixes are narrowed to what changes (shapes seen from Qwen, Gemini and DeepSeek).
        do {
            func T(_ a: String, _ b: String, _ text: String) -> [String] { Gemini.tighten(a, b, in: text).map { "\($0.0)→\($0.1)" } }
            let zh = T("在来", "我明天再来找你，好吗？", "我明天在来找你，好吗？")
            print("tighten \(zh == ["在→再"] ? "OK" : "FAIL"): a whole-sentence fix for a short span becomes the one changed character (\(zh))")
            let en = T("They was late and he dont know why.", "They were late and he doesn't know why.", "They was late and he dont know why.")
            print("tighten \(en == ["was→were", "dont→doesn't"] ? "OK" : "FAIL"): a sentence-wide fix splits into one issue per change (\(en))")
            let ko = T("공부할수 있어요", "공부할 수 있어요", "저는 한국어를 공부할수 있어요.")
            print("tighten \(ko == ["할수→할 수"] ? "OK" : "FAIL"): a Korean spacing fix keeps both neighbours (\(ko))")
            let same = T("They was", "They were", "They was late.")
            print("tighten \(same == ["was→were"] ? "OK" : "FAIL"): a normal fix stays minimal (\(same))")
            let word = T("dont", "doesn't", "he dont know")
            print("tighten \(word == ["dont→doesn't"] ? "OK" : "FAIL"): an English word is never cut inside (\(word))")
            let ins = T("I need advice", "I need some advice", "I need advice now.")
            print("tighten \(ins == ["need→need some"] ? "OK" : "FAIL"): an insertion is anchored on the word before (\(ins))")
            func applied(_ a: String, _ b: String, _ text: String) -> String {
                Gemini.tighten(a, b, in: text).reduce(text) { t, p in
                    let r = (t as NSString).range(of: p.0); return r.location == NSNotFound ? t : (t as NSString).replacingCharacters(in: r, with: p.1)
                }
            }
            let twice = applied("a cat and a dog", "a cat and the dog", "a cat and a dog")
            print("tighten \(twice == "a cat and the dog" ? "OK" : "FAIL"): the second of two equal words is changed, not the first (\(twice))")
            let uniq = T("我在家，明天在来", "我在家，明天再来", "我在家，明天在来")
            print("tighten \(applied("我在家，明天在来", "我在家，明天再来", "我在家，明天在来") == "我在家，明天再来" ? "OK" : "FAIL"): a span that occurs twice is widened until unique (\(uniq))")
        }

        // Overlapping issues become one suggestion.
        do {
            let t = "he doont know where the files is"
            var kept: [Issue] = []
            for x in [Issue(kind: "spelling", text: "doont", fix: "dont", reason: "typo"),
                      Issue(kind: "grammar", text: "doont", fix: "doesn't", reason: "agreement"),
                      Issue(kind: "grammar", text: "files is", fix: "files are", reason: "agreement"),
                      Issue(kind: "grammar", text: "is", fix: "are", reason: "agreement")] { Gemini.mergeOverlapping(&kept, x, in: t) }
            print("merge \(kept.map(\.fix) == ["doesn't", "files are"] ? "OK" : "FAIL"): overlapping issues merged (\(kept.map(\.fix)))")
            let a = TextMarkers.plausible(CGRect(x: 0, y: 0, width: 920, height: 20), length: 5, textLength: 31, field: CGRect(x: 0, y: 0, width: 927, height: 38))
            let b = TextMarkers.plausible(CGRect(x: 40, y: 10, width: 42, height: 18), length: 5, textLength: 31, field: CGRect(x: 0, y: 0, width: 927, height: 38))
            print("marker rects \(!a && b ? "OK" : "FAIL"): a field-wide rect for 5 characters is rejected, a word-sized one kept")
        }

        // Loop guard: Nib doesn't re-check or revert what it wrote.
        do {
            typealias L = LiveChecker
            let pairs = Set(L.fixPairs(original: "they was happy and buyed it", written: "they were happy and bought it"))
            let issues = [Issue(kind: "grammar", text: "were", fix: "was", reason: "x"),           // reverts was→were
                          Issue(kind: "grammar", text: "they were", fix: "they was", reason: "x"), // same, wider span
                          Issue(kind: "grammar", text: "bought", fix: "buyed", reason: "x"),       // reverts
                          Issue(kind: "grammar", text: "happy", fix: "glad", reason: "x")]         // new, kept
            let kept = L.dropReverts(issues, applied: pairs).map(\.fix)
            let cases: [(String, Bool)] = [
                ("pairs recorded from a ⌥⌥ write (was→were, buyed→bought)", pairs.contains(.init(from: "was", to: "were")) && pairs.contains(.init(from: "buyed", to: "bought"))),
                ("revert suggestions dropped, a new one kept", kept == ["glad"]),
                ("nothing dropped when Nib applied nothing", L.dropReverts(issues, applied: []).count == 4),
                ("paragraph Nib wrote counts as checked", L.cleanParagraphs(field: ["Hello there.", "They were happy and bought it."], written: ["They were happy and bought it."]) == ["They were happy and bought it."]),
                ("a sentence Nib wrote inside a longer paragraph marks that paragraph", L.cleanParagraphs(field: ["Intro. They were happy. Outro."], written: ["They were happy."]).count == 1),
                ("other paragraphs still get checked", L.cleanParagraphs(field: ["Untouched text here."], written: ["They were happy."]).isEmpty),
            ]
            for (name, ok) in cases { print("loop guard \(ok ? "OK" : "FAIL"): \(name)") }
        }

        // Surface coordinator: which floating surface may show.
        do {
            var g = SurfaceGate()
            let t = Date()
            var results: [(String, Bool, Bool)] = []
            results.append(("chip on a user selection, nothing else up", g.chipAllowed(selection: "1:0:5", at: t), true))
            g.begin(.correcting, at: t)
            results.append(("chip while ⌥⌥ is in flight", g.chipAllowed(selection: "1:0:40", at: t.addingTimeInterval(0.2)), false))
            g.begin(.suggestion, at: t.addingTimeInterval(1))
            results.append(("chip on ⌥⌥'s select-all while the panel is up", g.chipAllowed(selection: "1:0:40", at: t.addingTimeInterval(3)), false))
            results.append(("live popup while the panel is up", g.livePopupAllowed(caret: "1:3:0", mouse: .zero, at: t.addingTimeInterval(3)), false))
            g.end(.suggestion, at: t.addingTimeInterval(5))
            results.append(("chip in the quiet second after closing", g.chipAllowed(selection: "1:0:40", at: t.addingTimeInterval(5.5)), false))
            results.append(("chip on the same Nib-made selection later", g.chipAllowed(selection: "1:0:40", at: t.addingTimeInterval(7)), false))
            results.append(("chip once the user selects something new", g.chipAllowed(selection: "1:4:9", at: t.addingTimeInterval(8)), true))
            results.append(("live popup before the caret/mouse moved", g.livePopupAllowed(caret: "1:3:0", mouse: .zero, at: t.addingTimeInterval(8)), false))
            results.append(("live popup after a caret move", g.livePopupAllowed(caret: "1:9:0", mouse: .zero, at: t.addingTimeInterval(8.2)), true))
            g.touched(at: t.addingTimeInterval(10)) // e.g. a replace
            results.append(("chip right after Nib wrote text", g.chipAllowed(selection: "1:4:9", at: t.addingTimeInterval(10.3)), false))
            results.append(("chip after the selection was cleared, then a new one", { _ = g.chipAllowed(selection: nil, at: t.addingTimeInterval(12)); return g.chipAllowed(selection: "1:4:9", at: t.addingTimeInterval(13)) }(), true))
            g.begin(.rewrite, at: t.addingTimeInterval(20))
            results.append(("live popup while the rewrite card is up", g.livePopupAllowed(caret: "1:1:0", mouse: CGPoint(x: 50, y: 50), at: t.addingTimeInterval(21)), false))
            g.end(.correcting, at: t.addingTimeInterval(22)) // ending a different modal changes nothing
            results.append(("rewrite card still owns the screen after an unrelated end", g.modal == .rewrite, true))
            for (name, got, want) in results { print("surfaces \(got == want ? "OK" : "FAIL"): \(name)") }
        }

        // Popup key gate: when do Tab / ⇧Tab / Esc act on the live-checking popup?
        typealias G = LiveChecker.KeyGate
        let now = Date()
        func gate(_ o: G.Origin?, shown: Double, typed: Double) -> G {
            var g = G(); g.origin = o; g.shownAt = now.addingTimeInterval(-shown); g.lastTyped = now.addingTimeInterval(-typed); return g
        }
        let gateCases: [(String, G, Bool)] = [
            ("no popup", gate(nil, shown: 5, typed: 5), false),
            ("caret popup, quiet", gate(.caret, shown: 0.05, typed: 2), true),
            ("caret popup, just typed", gate(.caret, shown: 1, typed: 0.2), false),
            ("hover popup, fresh (0.1 s)", gate(.hover, shown: 0.1, typed: 5), false),
            ("hover popup, rested 0.4 s", gate(.hover, shown: 0.4, typed: 5), true),
            ("hover popup, rested but typing", gate(.hover, shown: 2, typed: 0.1), false),
        ]
        for (name, g, expect) in gateCases {
            print("popup keys \(g.armed(at: now) == expect ? "OK" : "FAIL"): \(name) → \(g.armed(at: now) ? "acts" : "passes through")")
        }
        // Double-tap ⌥ detector: (inputs with ms offsets) → should fire?
        typealias I = DoubleTapDetector.Input
        let tapCases: [(String, [(I, Double)], Bool)] = [
            ("two quick taps", [(.optionDown, 0), (.optionUp, 80), (.optionDown, 200), (.optionUp, 280)], true),
            ("one tap", [(.optionDown, 0), (.optionUp, 80)], false),
            ("⌥E typed between taps", [(.optionDown, 0), (.other, 40), (.optionUp, 80), (.optionDown, 200), (.optionUp, 280)], false),
            ("⌥ held to type (long hold)", [(.optionDown, 0), (.optionUp, 700), (.optionDown, 800), (.optionUp, 880)], false),
            ("taps too far apart", [(.optionDown, 0), (.optionUp, 80), (.optionDown, 700), (.optionUp, 780)], false),
            ("⌥⌘ chord then tap", [(.optionDown, 0), (.other, 30), (.optionUp, 90), (.optionDown, 200), (.optionUp, 260)], false),
            ("typing ⌥-char then double tap", [(.optionDown, 0), (.other, 50), (.optionUp, 100), (.optionDown, 1000), (.optionUp, 1060), (.optionDown, 1200), (.optionUp, 1260)], true),
            ("three taps fire once", [(.optionDown, 0), (.optionUp, 60), (.optionDown, 150), (.optionUp, 210), (.optionDown, 300), (.optionUp, 360)], true),
        ]
        for (name, seq, expect) in tapCases {
            var d = DoubleTapDetector()
            let t0 = Date()
            var fired = 0
            for (i, ms) in seq where d.feed(i, at: t0.addingTimeInterval(ms / 1000)) { fired += 1 }
            let ok = expect ? fired == 1 : fired == 0
            print("double-tap \(ok ? "OK" : "FAIL"): \(name) (fired \(fired)×)")
        }
        let cases: [(String, String)] = [
            ("i has went to the store", "I went to the store"),
            ("buyed three apple, they was delicious.", "bought three apples; they were delicious."),
            ("Same text.", "Same text."),
            ("line one\n\nline  two", "Line one\n\nline  two"),
        ]
        for (a, b) in cases {
            let pieces = WordDiff.diff(a, b)
            var rebuiltA = "", rebuiltB = ""
            for p in pieces {
                switch p {
                case .same(let s): rebuiltA += s; rebuiltB += s
                case .removed(let s): rebuiltA += s
                case .added(let s): rebuiltB += s
                }
            }
            print("\(WordDiff.issueCount(a, b)) issues | roundtrip \(rebuiltA == a && rebuiltB == b ? "OK" : "FAIL") | \(a.debugDescription) → \(b.debugDescription)")
        }
    }
}
