import AppKit

/// Decides which floating surface may show. One interactive surface at a time, by priority:
/// rewrite card / suggestion panel (and a correction in flight) > live popup > ✨ chip.
/// A pure state machine so it can be tested; `Surfaces` wires it to the app.
struct SurfaceGate {
    enum Modal: Equatable { case correcting, suggestion, rewrite }

    private(set) var modal: Modal?
    private(set) var touchedAt = Date.distantPast
    /// After Nib selected or wrote text, the chip waits for the user's own next selection,
    /// and the live popup for a caret or mouse move.
    private(set) var needsNewSelection = false
    private var selectionBaseline: String?
    private(set) var needsMove = false
    private var caretBaseline: String?
    private var mouseBaseline: CGPoint?

    /// How long after Nib's own selection or write everything stays quiet.
    static let quiet: TimeInterval = 1.0

    mutating func begin(_ m: Modal, at now: Date) {
        modal = m
        touched(at: now)
    }

    /// Ends `m` (or whatever is up, if nil). Closing counts as Nib touching the text.
    mutating func end(_ m: Modal?, at now: Date) {
        guard m == nil || modal == m else { return }
        modal = nil
        touched(at: now)
    }

    /// Nib made a selection or wrote text (capture, replace, undo, live apply).
    mutating func touched(at now: Date) {
        touchedAt = now
        needsNewSelection = true
        selectionBaseline = nil
        needsMove = true
        caretBaseline = nil
        mouseBaseline = nil
    }

    private func quietOrModal(_ now: Date) -> Bool { modal != nil || now.timeIntervalSince(touchedAt) < Self.quiet }

    /// May the ✨ chip show for this selection (pid:location:length, nil = no selection)?
    mutating func chipAllowed(selection key: String?, at now: Date) -> Bool {
        if quietOrModal(now) {
            // Whatever is selected now is Nib's doing (select-all, a restored range…): remember it.
            if key != nil { selectionBaseline = key }
            return false
        }
        guard let key else { needsNewSelection = false; return false } // cleared: the next selection is the user's
        if needsNewSelection {
            if key == selectionBaseline { return false }
            needsNewSelection = false
        }
        return true
    }

    /// May the live popup open (caret = pid:location of an empty selection, mouse = pointer)?
    mutating func livePopupAllowed(caret: String?, mouse: CGPoint, at now: Date) -> Bool {
        if quietOrModal(now) {
            caretBaseline = caret
            mouseBaseline = mouse
            return false
        }
        if needsMove {
            if caretBaseline == nil && mouseBaseline == nil { caretBaseline = caret; mouseBaseline = mouse; return false }
            let moved = (mouseBaseline.map { hypot($0.x - mouse.x, $0.y - mouse.y) > 4 } ?? true) || caret != caretBaseline
            guard moved else { return false }
            needsMove = false
        }
        return true
    }
}

/// The app-wide coordinator around `SurfaceGate`, plus where the cards are so messages stay clear of them.
final class Surfaces {
    static let shared = Surfaces()
    var gate = SurfaceGate()
    /// Screen frames of open cards (rewrite card, suggestion panel), by name.
    private(set) var cards: [String: NSRect] = [:]

    var modalUp: Bool { gate.modal != nil }

    private var modalSince: Date?

    /// A correction, suggestion or rewrite that somehow never ended mustn't switch live checking off for good.
    var modalUpChecked: Bool {
        if gate.modal != nil, let since = modalSince, Date().timeIntervalSince(since) > 120 {
            log("surfaces: \(String(describing: gate.modal)) open for over 2 minutes; released")
            gate.end(nil, at: Date())
            modalSince = nil
        }
        return gate.modal != nil
    }

    func begin(_ m: SurfaceGate.Modal) {
        modalSince = Date()
        gate.begin(m, at: Date())
        SelectionChip.shared.hide()
        LiveChecker.shared.clear()
    }

    func end(_ m: SurfaceGate.Modal?) { gate.end(m, at: Date()) }
    func touched() { gate.touched(at: Date()) }

    func setCard(_ name: String, _ frame: NSRect?) { cards[name] = frame }

    /// Moves `frame` so it doesn't cover an open card: below it if there's room, else above.
    func avoidingCards(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var f = frame
        for card in cards.values where card.intersects(f) {
            let below = NSRect(x: f.minX, y: card.minY - f.height - 4, width: f.width, height: f.height)
            let above = NSRect(x: f.minX, y: card.maxY + 4, width: f.width, height: f.height)
            f = below.minY >= visible.minY ? below : above
        }
        return f
    }
}
