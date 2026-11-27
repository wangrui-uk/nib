import AppKit
import SwiftUI
import Carbon.HIToolbox

enum HUDStyle { case working, success, info, error }

private struct HUDView: View {
    let message: String
    let style: HUDStyle
    var body: some View {
        HStack(spacing: 8) {
            icon
            Wrapping(natural: PopupStyle.width(message, PopupStyle.size, bold: true), maxWidth: 420 * PopupStyle.scale) {
                Text(message).font(PopupStyle.font(PopupStyle.size, weight: .medium))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(HUDBackground())
    }
    @ViewBuilder var icon: some View {
        switch style {
        case .working: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .info: Image(systemName: "info.circle.fill").foregroundColor(.blue)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }
}

private struct HUDBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

struct SuggestionView: View {
    let pieces: [WordDiff.Piece]
    let count: Int
    let accept: () -> Void
    let reject: () -> Void

    /// Short diffs keep their natural width; long ones wrap at a fixed width, so their height is measured right.
    @ViewBuilder var diff: some View {
        let text = WordDiff.text(pieces).font(PopupStyle.textFont).lineLimit(14)
        let length = pieces.reduce(0) { n, p in
            switch p { case .same(let s), .removed(let s), .added(let s): return n + s.count }
        }
        if length > 48 {
            text.frame(width: PopupStyle.wrapWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        } else {
            text.fixedSize()
        }
    }

    var body: some View {
        PopupCard(accent: PopupStyle.color(for: "")) {
            diff
            PopupStyle.caption(count == 1 ? "1 change" : "\(count) changes")
            HStack(spacing: 6) {
                Button(action: accept) { KeyLabel(title: "Accept", glyph: "↩", onAccent: true) }
                    .buttonStyle(PopupButtonStyle(prominent: true))
                Button(action: reject) { KeyLabel(title: "Dismiss", glyph: "esc") }
                    .buttonStyle(PopupButtonStyle())
            }
            .padding(.top, 2)
        }
        .fixedSize()
    }
}

/// For UIRender only.
enum HUDPreview {
    static func message(_ m: String, _ style: HUDStyle) -> some View { HUDView(message: m, style: style).padding(8) }
    static func suggestion(_ a: String, _ b: String) -> some View {
        SuggestionView(pieces: WordDiff.diff(a, b), count: WordDiff.issueCount(a, b), accept: {}, reject: {})
    }
}

/// Lets buttons work on the first click without the panel taking focus.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Floating messages near the text being edited. Never takes focus from the target app.
final class HUD {
    static let shared = HUD()
    private var panel: HUDPanel?        // the suggestion panel
    private var messagePanel: HUDPanel? // messages ("Correcting…", "Fixed…"), never on top of a card
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, style: HUDStyle = .info, near anchor: NSRect? = nil, duration: TimeInterval? = 2) {
        present(FirstMouseHostingView(rootView: AnyView(HUDView(message: message, style: style).padding(8))),
                near: anchor, interactive: false, duration: duration)
    }

    static let acceptKeyID: UInt32 = 3
    static let dismissKeyID: UInt32 = 4

    /// True while the suggestion panel is up; it owns ↩ and esc then.
    private(set) var suggestionVisible = false
    /// Called once when the suggestion panel goes away (accept, dismiss, timeout, app switch, new correction).
    var onSuggestionClosed: (() -> Void)?

    func showSuggestion(original: String, corrected: String, near anchor: NSRect?,
                        accept: @escaping () -> Void, reject: @escaping () -> Void) {
        let pieces = WordDiff.diff(original, corrected)
        let doAccept: () -> Void = { [weak self] in self?.hide(); accept() }
        let doReject: () -> Void = { [weak self] in self?.hide(); reject() }
        let view = SuggestionView(pieces: pieces, count: WordDiff.issueCount(original, corrected),
                                  accept: doAccept, reject: doReject)
        // The panel never takes focus, so Return/Esc are caught as temporary global shortcuts while it's up.
        HotKey.shared.actions[HUD.acceptKeyID] = doAccept
        HotKey.shared.actions[HUD.dismissKeyID] = doReject
        HotKey.shared.register(id: HUD.acceptKeyID, keyCode: UInt32(kVK_Return), modifiers: 0)
        HotKey.shared.register(id: HUD.dismissKeyID, keyCode: UInt32(kVK_Escape), modifiers: 0)
        present(FirstMouseHostingView(rootView: AnyView(view)), near: anchor, interactive: true, duration: 30)
        suggestionVisible = true
        // Leaving the app dismisses the suggestion, so ↩ goes back to being a normal key.
        appSwitchObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.hide() }
    }

    private var appSwitchObserver: NSObjectProtocol?

    func hide() {
        appSwitchObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        appSwitchObserver = nil
        HotKey.shared.unregister(id: HUD.acceptKeyID)
        HotKey.shared.unregister(id: HUD.dismissKeyID)
        hideWork?.cancel()
        messageHideWork?.cancel()
        panel?.orderOut(nil)
        messagePanel?.orderOut(nil)
        Surfaces.shared.setCard("suggestion", nil)
        if suggestionVisible {
            suggestionVisible = false
            let closed = onSuggestionClosed
            onSuggestionClosed = nil
            closed?()
        }
    }

    private var messageHideWork: DispatchWorkItem?

    private func present(_ host: NSView, near anchor: NSRect?, interactive: Bool, duration: TimeInterval?) {
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        // The suggestion panel and messages use separate windows, so a message never replaces or covers the panel.
        let p: HUDPanel
        if interactive {
            hideWork?.cancel()
            p = panel ?? makePanel(); panel = p
        } else {
            messageHideWork?.cancel()
            p = messagePanel ?? makePanel(); messagePanel = p
        }
        p.ignoresMouseEvents = !interactive
        p.contentView = host
        p.setContentSize(size)
        var frame = NSRect(origin: origin(for: size, anchor: anchor), size: size)
        let vf = CardPlacement.screen(for: NSPoint(x: frame.midX, y: frame.midY)).visibleFrame
        if interactive {
            frame = CardPlacement.clamp(frame, padding: 10, in: vf)
            Surfaces.shared.setCard("suggestion", frame.insetBy(dx: 8, dy: 8))
        } else {
            frame = CardPlacement.clamp(Surfaces.shared.avoidingCards(frame, in: vf), in: vf)
        }
        p.setFrameOrigin(frame.origin)
        p.orderFrontRegardless()
        if let duration {
            let work = DispatchWorkItem { [weak self] in
                if interactive { self?.hide() } else { self?.messagePanel?.orderOut(nil) }
            }
            if interactive { hideWork = work } else { messageHideWork = work }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    private func makePanel() -> HUDPanel {
        let p = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }

    /// Just below the anchor (caret / field), else above it, else below the mouse pointer.
    private func origin(for size: NSSize, anchor: NSRect?) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let a = anchor ?? NSRect(x: mouse.x - 10, y: mouse.y - 24, width: 0, height: 24)
        let center = NSPoint(x: a.midX, y: a.midY)
        let vf = CardPlacement.screen(for: center).visibleFrame
        var x = a.minX - 8
        var y = a.minY - size.height - 2
        if y < vf.minY { y = a.maxY + 2 }
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        return NSPoint(x: x, y: y)
    }
}
