import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

/// "Rewrite selection": the selected text in a chosen style, shown in a card to replace, retry, copy or dismiss.
/// Nothing is sent to Gemini until the user asks (chip click, ⇧⇧ or the menu).
final class RewriteController: ObservableObject {
    static let shared = RewriteController()

    enum Phase: Equatable { case idle, loading, ready(String), failed(String) }
    @Published var phase: Phase = .idle
    @Published var showChanges = true
    @Published var styleID: String = Settings.shared.currentRewriteStyle.id

    /// Called with an undo record after a replace (⌃⌥Z puts the original back).
    var onApplied: ((LastCorrection) -> Void)?
    /// Called when the card closes, for resuming live checking.
    var onClosed: (() -> Void)?

    private(set) var capture: Capture?
    private(set) var original = ""
    private var lead = "", trail = ""
    private var attempt = 0
    private var token = 0
    private let panel = RewritePanel()
    var isVisible: Bool { panel.isVisible }

    var style: RewriteStyle {
        Settings.shared.visibleRewriteStyles.first { $0.id == styleID } ?? Settings.shared.currentRewriteStyle
    }

    // MARK: Flow

    /// Reads the selection and opens the card. `inApp` = one of Nib's own windows.
    func start(inApp: Bool) {
        Surfaces.shared.begin(.rewrite)
        let cap: Capture
        do { cap = try inApp ? TextAccess.captureInApp(selectionOnly: true) : TextAccess.capture(selectionOnly: true) }
        catch {
            Surfaces.shared.end(.rewrite)
            HUD.shared.show(error.localizedDescription, style: .info)
            onClosed?()
            return
        }
        let chars = Array(cap.text)
        var s = 0, e = chars.count
        while s < e, chars[s].isWhitespace { s += 1 }
        while e > s, chars[e - 1].isWhitespace { e -= 1 }
        guard s < e else { Surfaces.shared.end(.rewrite); HUD.shared.show(CaptureError.noSelection.localizedDescription, style: .info); onClosed?(); return }
        guard e - s <= TextAccess.maxLength else {
            Surfaces.shared.end(.rewrite); HUD.shared.show(CaptureError.tooLong(e - s).localizedDescription, style: .error); onClosed?(); return
        }
        capture = cap
        lead = String(chars[..<s]); original = String(chars[s..<e]); trail = String(chars[e...])
        styleID = Settings.shared.currentRewriteStyle.id
        attempt = 0
        showChanges = true
        panel.show(controller: self, near: cap.anchor ?? cap.fieldFrame)
        registerKeys()
        generate()
    }

    func generate() {
        token += 1
        let my = token
        let text = original, style = self.style, attempt = self.attempt
        phase = .loading
        let started = Date()
        Task { @MainActor in
            do {
                let out = try await Gemini.rewrite(text, style: style, attempt: attempt)
                guard my == token else { return } // a newer request (style change / try again) superseded this one
                log("rewrite: \(style.id), \(text.count) chars, \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                phase = .ready(out)
            } catch {
                guard my == token else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func choose(_ id: String) {
        guard id != styleID else { return }
        styleID = id
        Settings.shared.lastRewriteStyle = id
        attempt = 0
        generate()
    }

    func tryAgain() {
        attempt += 1
        generate()
    }

    func replace() {
        guard case .ready(let text) = phase, let cap = capture else { return }
        let replacement = lead + text + trail
        close()
        do {
            let how = try TextAccess.replace(cap, with: replacement)
            Surfaces.shared.touched()
            LiveChecker.shared.noteNibWrite(original: cap.text, written: replacement)
            log("rewrite: replaced via \(how)")
            onApplied?(LastCorrection(capture: cap, original: cap.text, corrected: replacement, via: how))
            HUD.shared.show("Rewritten · \(Settings.shared.undoDisplay) to undo", style: .success, near: cap.anchor, duration: 2.2)
        } catch {
            HUD.shared.show(error.localizedDescription, style: .error, near: cap.anchor, duration: 3.5)
        }
    }

    func copy() {
        guard case .ready(let text) = phase else { return }
        TextAccess.copyToClipboard(text)
        let anchor = capture?.anchor
        close()
        HUD.shared.show("Copied to the clipboard", style: .success, near: anchor, duration: 1.4)
    }

    func close() {
        token += 1
        unregisterKeys()
        let wasVisible = panel.isVisible
        panel.hide()
        phase = .idle
        Surfaces.shared.setCard("rewrite", nil)
        if Surfaces.shared.gate.modal == .rewrite { Surfaces.shared.end(.rewrite) }
        if wasVisible { onClosed?() }
    }

    /// For UIRender only.
    static func preview(_ original: String, _ phase: Phase, changes: Bool = true) -> RewriteController {
        let c = RewriteController()
        c.original = original
        c.phase = phase
        c.showChanges = changes
        return c
    }

    // MARK: Keys (only while the card is up)

    static let returnID: UInt32 = 8, escID: UInt32 = 9, retryID: UInt32 = 10
    private var appSwitch: NSObjectProtocol?

    private func registerKeys() {
        let hk = HotKey.shared
        hk.actions[Self.returnID] = { [weak self] in self?.replace() }
        hk.actions[Self.escID] = { [weak self] in self?.close() }
        hk.actions[Self.retryID] = { [weak self] in self?.tryAgain() }
        hk.register(id: Self.returnID, keyCode: UInt32(kVK_Return), modifiers: 0)
        hk.register(id: Self.escID, keyCode: UInt32(kVK_Escape), modifiers: 0)
        hk.register(id: Self.retryID, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey))
        // Leaving the app closes the card, so ↩, esc and ⌘R go back to being normal keys.
        appSwitch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.close() }
    }

    private func unregisterKeys() {
        [Self.returnID, Self.escID, Self.retryID].forEach { HotKey.shared.unregister(id: $0) }
        appSwitch.map(NSWorkspace.shared.notificationCenter.removeObserver)
        appSwitch = nil
    }
}

// MARK: - Card

struct RewriteCard: View {
    @ObservedObject var c: RewriteController
    @ObservedObject var settings = Settings.shared

    var body: some View {
        PopupCard(accent: .purple) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(.purple).font(PopupStyle.captionFont)
                Menu {
                    ForEach(settings.visibleRewriteStyles) { s in
                        Button { c.choose(s.id) } label: {
                            if s.id == c.styleID { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                        }
                    }
                } label: {
                    Text(c.style.name).font(PopupStyle.font(PopupStyle.size * 12 / 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 12)
                if case .ready = c.phase {
                    Button(c.showChanges ? "Show result" : "Show changes") { c.showChanges.toggle() }
                        .buttonStyle(.plain)
                        .font(PopupStyle.captionFont).foregroundColor(.accentColor)
                }
            }
            content
            HStack(spacing: 6) {
                Button(action: c.replace) { KeyLabel(title: "Replace", glyph: "↩", onAccent: true) }
                    .buttonStyle(PopupButtonStyle(prominent: true)).disabled(!isReady)
                Button(action: c.tryAgain) { KeyLabel(title: "Try again", glyph: "⌘R") }
                    .buttonStyle(PopupButtonStyle()).disabled(c.phase == .loading)
                Button(action: c.copy) { Text("Copy").padding(.trailing, 4) }
                    .buttonStyle(PopupButtonStyle()).disabled(!isReady)
                Button(action: c.close) { KeyLabel(title: "Dismiss", glyph: "esc") }
                    .buttonStyle(PopupButtonStyle())
            }
            .padding(.top, 2)
        }
        .frame(width: PopupStyle.wrapWidth + 40 * PopupStyle.scale)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isReady: Bool { if case .ready = c.phase { return true } else { return false } }

    @ViewBuilder private var content: some View {
        switch c.phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                PopupStyle.caption("Rewriting…")
            }
            .frame(maxWidth: .infinity, minHeight: 34 * PopupStyle.scale, alignment: .leading)
        case .ready(let text):
            Group {
                if c.showChanges {
                    WordDiff.text(WordDiff.diff(c.original, text))
                } else {
                    Text(text).foregroundColor(.primary)
                }
            }
            .font(PopupStyle.textFont)
            .lineLimit(18)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        case .failed(let msg):
            Text(msg).font(PopupStyle.captionFont).foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Panel

final class RewritePanel {
    private var panel: HUDPanel?
    private var anchor: NSRect?
    private var sub: AnyCancellable?
    var isVisible: Bool { panel?.isVisible ?? false }

    func show(controller: RewriteController, near anchor: NSRect?) {
        self.anchor = anchor
        let host = FirstMouseHostingView(rootView: RewriteCard(c: controller))
        let p = panel ?? make()
        p.contentView = host
        place()
        p.orderFrontRegardless()
        // Resize (keeping the top edge where it was) whenever the card's content changes.
        sub = controller.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.place() } }
    }

    func hide() {
        sub = nil
        panel?.orderOut(nil)
    }

    private func place() {
        guard let p = panel, let host = p.contentView else { return }
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let a = anchor ?? NSRect(x: mouse.x, y: mouse.y - 20, width: 0, height: 20)
        let vf = CardPlacement.screen(for: NSPoint(x: a.midX, y: a.midY)).visibleFrame
        // Below the selection so the text stays visible; above if there's no room. (10 pt transparent margin.)
        var y = a.minY - size.height + 6
        if y + 10 < vf.minY + CardPlacement.margin { y = a.maxY - 6 }
        let frame = CardPlacement.clamp(NSRect(x: a.minX - 10, y: y, width: size.width, height: size.height), padding: 10, in: vf)
        p.setFrame(frame, display: true)
        Surfaces.shared.setCard("rewrite", frame.insetBy(dx: 10, dy: 10))
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
