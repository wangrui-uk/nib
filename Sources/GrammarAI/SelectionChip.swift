import AppKit
import SwiftUI
import ApplicationServices

/// The small "✨ Rewrite" chip that appears at the end of a selection after a short pause.
/// It only watches the selection locally; nothing is sent anywhere until it's clicked.
final class SelectionChip {
    static let shared = SelectionChip()
    var action: (() -> Void)?

    private var timer: Timer?
    private var panel: HUDPanel?
    private var lastKey = Date.distantPast
    private var keyMonitor: Any?
    private var range: NSRange?
    private var element: AXUIElement?
    private var changedAt = Date()
    private(set) var isVisible = false

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.lastKey = Date()
            self?.hide()
        }
    }

    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        isVisible = false
    }

    private func tick() {
        let s = Settings.shared
        guard !Surfaces.shared.modalUpChecked else { hide(); range = nil; _ = Surfaces.shared.gate.chipAllowed(selection: nil, at: Date()); return }
        guard s.showRewriteChip, !s.isPaused, AXIsProcessTrusted(), s.apiKey != nil, !RewriteController.shared.isVisible,
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let id = app.bundleIdentifier, !TextAccess.blockedBundleIDs.contains(id), !s.liveDisabledApps.contains(id),
              !TextAccess.copyLineBundleIDs.contains(id) else { hide(); range = nil; return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Same field-finding as live checking (rich editors in Chromium/Electron apps included).
        let (found, _) = TextTarget.resolve(app, axApp)
        guard let found, let sel = LiveChecker.selectedRange(found.element), sel.length > 0,
              NSMaxRange(sel) <= (found.text as NSString).length,
              (found.text as NSString).substring(with: sel).contains(where: \.isLetter)
        else { hide(); range = nil; _ = Surfaces.shared.gate.chipAllowed(selection: nil, at: Date()); return }
        let el = found.element
        // Not for selections Nib made itself, nor while anything else is up.
        guard Surfaces.shared.gate.chipAllowed(selection: "\(app.processIdentifier):\(sel.location):\(sel.length)", at: Date()) else {
            hide(); range = nil; return
        }

        if range != sel || element == nil || !CFEqual(element!, el) {
            range = sel; element = el; changedAt = Date(); hide(); return
        }
        // Wait until the selection has settled: no change, no typing and no mouse button held for 0.5 s.
        let now = Date()
        guard !isVisible, now.timeIntervalSince(changedAt) >= 0.5, now.timeIntervalSince(lastKey) >= 0.5,
              NSEvent.pressedMouseButtons == 0 else { return }
        // At the end of the selection; no chip if the app can't say where that is (⇧⇧ still works).
        if let end = LiveChecker.bounds(el, NSRange(location: NSMaxRange(sel) - 1, length: 1)) {
            show(at: TextAccess.flip(end))
        } else if let frame = LiveChecker.frame(el).map(TextAccess.flip) {
            // No text positions (some Electron editors): at the pointer if it's in the field (where a drag-selection
            // ends), else at the field's bottom-left corner.
            let mouse = NSEvent.mouseLocation
            let at = frame.contains(mouse) ? NSRect(x: mouse.x, y: mouse.y - 8, width: 1, height: 16)
                                           : NSRect(x: frame.minX + 8, y: frame.minY + 4, width: 1, height: 16)
            show(at: at)
        }
    }

    private func show(at r: NSRect) {
        let host = FirstMouseHostingView(rootView: ChipView { [weak self] in self?.hide(); self?.action?() })
        let size = host.fittingSize
        let p = panel ?? make()
        p.contentView = host
        let vf = CardPlacement.screen(for: NSPoint(x: r.midX, y: r.midY)).visibleFrame
        var origin = NSPoint(x: r.maxX - 6, y: r.minY - size.height + 4)
        if origin.y < vf.minY + CardPlacement.margin { origin.y = r.maxY - 4 }
        p.setFrame(CardPlacement.clamp(NSRect(origin: origin, size: size), in: vf), display: true)
        p.orderFrontRegardless()
        isVisible = true
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

struct ChipView: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4 * PopupStyle.scale) {
                Image(systemName: "sparkles").foregroundColor(.purple)
                Text("Rewrite")
            }
            .font(PopupStyle.font(PopupStyle.size * 12 / 13, weight: .medium))
            .padding(.horizontal, 8 * PopupStyle.scale).padding(.vertical, 4 * PopupStyle.scale)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(6)
    }
}
