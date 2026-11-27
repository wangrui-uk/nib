import AppKit

/// Two quick taps of Option on its own. Any other key, modifier or click in between cancels,
/// so Option used for typing characters (⌥E, ⌥-arrow…) or held as a modifier never fires it.
struct DoubleTapDetector {
    enum Input { case optionDown, optionUp, other }
    /// A tap: Option down → up within this.
    var maxHold: TimeInterval = 0.30
    /// Between the first tap's release and the second press.
    var maxGap: TimeInterval = 0.35
    private var downAt: Date?
    private var lastUp: Date?
    private var taps = 0

    mutating func feed(_ input: Input, at t: Date) -> Bool {
        switch input {
        case .other:
            reset()
        case .optionDown:
            if let up = lastUp, t.timeIntervalSince(up) > maxGap { taps = 0; lastUp = nil }
            downAt = t
        case .optionUp:
            guard let d = downAt, t.timeIntervalSince(d) <= maxHold else { reset(); return false }
            downAt = nil
            taps += 1
            lastUp = t
            if taps >= 2 { reset(); return true }
        }
        return false
    }

    mutating func reset() { downAt = nil; lastUp = nil; taps = 0 }
}

/// Watches the keyboard for the double-tap. Global monitors need the Accessibility permission
/// (which correcting needs anyway); a local monitor covers Nib's own windows.
final class DoubleTapMonitor {
    /// ⌥ ⌥: correct.
    static let shared = DoubleTapMonitor(keyCodes: [58, 61], flag: .option)
    /// ⇧ ⇧: rewrite the selection.
    static let shift = DoubleTapMonitor(keyCodes: [56, 60], flag: .shift)
    /// ⌘ ⌘: pause / resume Nib.
    static let command = DoubleTapMonitor(keyCodes: [55, 54], flag: .command)

    var action: (() -> Void)?
    private var detector = DoubleTapDetector()
    private var monitors: [Any] = []
    let keyCodes: Set<UInt16>
    let flag: NSEvent.ModifierFlags

    static let optionKeyCodes: Set<UInt16> = [58, 61] // left, right Option

    init(keyCodes: Set<UInt16>, flag: NSEvent.ModifierFlags) {
        self.keyCodes = keyCodes
        self.flag = flag
    }

    private var appSwitch: NSObjectProtocol?

    func start() {
        guard monitors.isEmpty else { return }
        // ⌘Tab, ⌘Space and other system shortcuts are swallowed before any app sees the key, so the
        // detector would only see ⌘ going down and up. They switch or open something: reset on app switches.
        appSwitch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.detector.reset() }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .gesture, .magnify, .swipe]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) { monitors.append(l) }
    }

    func stop() {
        appSwitch.map(NSWorkspace.shared.notificationCenter.removeObserver)
        appSwitch = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        detector.reset()
    }

    func input(for e: NSEvent) -> DoubleTapDetector.Input {
        guard e.type == .flagsChanged, keyCodes.contains(e.keyCode) else { return .other }
        let mods = e.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        if mods == flag { return .optionDown }
        if mods.isEmpty { return .optionUp }
        return .other // the key together with another modifier
    }

    private func handle(_ e: NSEvent) {
        if e.type == .flagsChanged, !keyCodes.contains(e.keyCode) {
            // Another modifier changing (Shift, ⌘…) cancels; Caps Lock does too.
            _ = detector.feed(.other, at: Date())
            return
        }
        if detector.feed(input(for: e), at: Date()) {
            DispatchQueue.main.async { self.action?() }
        }
    }
}
