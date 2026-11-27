import Carbon.HIToolbox
import AppKit

/// Global hotkeys via Carbon (they need no Accessibility permission).
final class HotKey {
    static let shared = HotKey()
    var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x47524149), id: id) // 'GRAI'
        guard RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func display(_ f: NSEvent.ModifierFlags, key: String) -> String {
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}
