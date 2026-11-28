import AppKit
import SwiftUI

/// When to say "no underlines here": only with evidence that the user is typing into an editable field Nib failed on,
/// and the failure has lasted. Never for buttons, links, lists, the desktop, address or search bars, empty fields
/// that haven't received text, right after a click, or a transient state (e.g. while an app rebuilds its tree).
enum Hints {
    struct Evidence {
        var bundleID: String
        var role: String
        var subrole = ""
        var description = ""
        var editable: Bool
        var keys: Int              // printable keystrokes into this element since it got focus (reset by clicks)
        var failingFor: TimeInterval
        var ticks: Int
        var textChanged: Bool      // its text changed since the failure began
        var textReadable: Bool
    }

    /// Apps where a hint never makes sense.
    static let neverIn: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.Spotlight", "com.apple.loginwindow"]

    static func warranted(_ e: Evidence) -> Bool {
        guard !neverIn.contains(e.bundleID), e.editable, !TextTarget.isControlRole(e.role) else { return false }
        let d = e.description.lowercased()
        if e.role == "AXSearchField" || e.subrole == "AXSearchField" || d.contains("address") || d.contains("search") { return false }
        guard e.failingFor >= 5, e.ticks >= 3, e.keys >= 5 else { return false }
        return e.textChanged || (!e.textReadable && e.keys >= 15)
    }

    /// Editable: a text role, a settable value, or inside an editable web area (contenteditable).
    static func isEditable(_ el: AXUIElement) -> Bool {
        let role = TextAccess.attr(el, kAXRoleAttribute) as? String ?? ""
        if ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) { return true }
        if TextAccess.attr(el, "AXEditableAncestor") != nil { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           !TextTarget.isControlRole(role) { return true }
        return false
    }

    /// A cheap fingerprint of the element's text (nil = unreadable).
    static func signature(_ el: AXUIElement) -> Int? {
        if let (t, _) = TextTarget.text(el) { return t.hashValue }
        return TextTarget.number(el, kAXNumberOfCharactersAttribute)
    }

    // MARK: Shown once per app, ever

    static func alreadyHinted(_ id: String) -> Bool { Settings.shared.hintedApps.contains(id) }
    static func markHinted(_ id: String) { if !alreadyHinted(id) { Settings.shared.hintedApps.append(id) } }
}

/// The small card: "No underlines in Chrome here — double-tap ⌥ to correct." with "Don't show again".
final class HintCard {
    static let shared = HintCard()
    private var panel: HUDPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, near anchor: NSRect?) {
        let view = HintCardView(text: text, dismiss: { [weak self] in self?.hide() },
                                never: { [weak self] in Settings.shared.showUnavailableHints = false; self?.hide() })
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? make()
        p.contentView = host
        p.setContentSize(size)
        let mouse = NSEvent.mouseLocation
        let a = anchor ?? NSRect(x: mouse.x, y: mouse.y - 20, width: 0, height: 20)
        let origin = NSPoint(x: a.minX - 10, y: a.minY - size.height - 2 + 10)
        p.setFrameOrigin(CardPlacement.clamp(NSRect(origin: origin, size: size), padding: 10, anchor: NSPoint(x: a.midX, y: a.midY)).origin)
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: work)
    }

    func hide() { panel?.orderOut(nil) }

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

struct HintCardView: View {
    let text: String
    let dismiss: () -> Void
    let never: () -> Void
    var body: some View {
        PopupCard(accent: .orange) {
            Wrapping(natural: PopupStyle.width(text, PopupStyle.size), maxWidth: 360 * PopupStyle.scale) {
                Text(text).font(PopupStyle.textFont)
            }
            HStack(spacing: 6) {
                Button(action: never) { Text("Don't show again") }.buttonStyle(PopupButtonStyle())
                Button(action: dismiss) { Text("OK") }.buttonStyle(PopupButtonStyle(prominent: true))
            }
        }
        .fixedSize()
    }
}
