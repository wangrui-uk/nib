import Foundation
import Security
import Carbon.HIToolbox

/// User settings in UserDefaults; the API key in the Keychain.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    /// Command-line checks set values in memory only (never saved to the user's preferences).
    var persist = true

    static var defaultModel: String { Provider.gemini.defaultModel }
    /// Former defaults: a stored value equal to one of these means "use the default".
    static let oldDefaultModels: Set<String> = ["gemini-3.1-flash-lite"]

    /// The one provider used for everything (live checking, ⌥⌥, rewrite).
    @Published var provider: Provider { didSet { guard persist else { return }; defaults.set(provider.rawValue, forKey: "provider") } }
    /// Chosen model per provider (missing = the provider's default, so default changes reach everyone).
    @Published var models: [String: String] {
        didSet {
            guard persist else { return }
            defaults.set(models, forKey: "models")
            if models != oldValue { log("settings: models changed to \(models)") } // so a change can always be traced
        }
    }
    @Published var qwenRegion: String { didSet { guard persist else { return }; defaults.set(qwenRegion, forKey: "qwenRegion") } }       // "intl" | "cn"
    @Published var vertexProject: String { didSet { guard persist else { return }; defaults.set(vertexProject, forKey: "vertexProject") } }
    @Published var vertexRegion: String { didSet { guard persist else { return }; defaults.set(vertexRegion, forKey: "vertexRegion") } }  // e.g. "global", "europe-west2"
    @Published var customBaseURL: String { didSet { guard persist else { return }; defaults.set(customBaseURL, forKey: "customBaseURL") } }
    @Published var customInstruction: String { didSet { guard persist else { return }; defaults.set(customInstruction, forKey: "customInstruction") } }
    @Published var hotKeyCode: UInt32 { didSet { guard persist else { return }; defaults.set(Int(hotKeyCode), forKey: "hotKeyCode") } }
    @Published var hotKeyModifiers: UInt32 { didSet { guard persist else { return }; defaults.set(Int(hotKeyModifiers), forKey: "hotKeyModifiers") } }
    @Published var hotKeyDisplay: String { didSet { guard persist else { return }; defaults.set(hotKeyDisplay, forKey: "hotKeyDisplay") } }
    /// How Correct Now is triggered: "doubleOption" (default) or "custom" (the recorded shortcut).
    @Published var trigger: String { didSet { guard persist else { return }; defaults.set(trigger, forKey: "trigger") } }
    var usesDoubleOption: Bool { trigger != "custom" }
    /// What to tell the user to press.
    var triggerDisplay: String { usesDoubleOption ? "⌥ ⌥" : hotKeyDisplay }
    var triggerPhrase: String { usesDoubleOption ? "double-tap ⌥ Option" : "press \(hotKeyDisplay)" }
    /// Popup text: "" = system font, "__mono__" = system monospaced, else a font family name.
    @Published var popupFont: String { didSet { guard persist else { return }; defaults.set(popupFont, forKey: "popupFont") } }
    /// Popup text size in points (11–20); captions and keycaps scale from it.
    @Published var popupFontSize: Double { didSet { guard persist else { return }; defaults.set(popupFontSize, forKey: "popupFontSize") } }
    static let defaultPopupFontSize = 13.0
    /// Rewrite styles (built-ins, possibly edited, plus the user's own), in menu order.
    @Published var rewriteStyles: [RewriteStyle] { didSet { guard persist else { return }; defaults.set(RewriteStyles.encode(rewriteStyles), forKey: "rewriteStyles") } }
    @Published var lastRewriteStyle: String { didSet { guard persist else { return }; defaults.set(lastRewriteStyle, forKey: "lastRewriteStyle") } }
    /// Show the ✨ Rewrite chip when text is selected.
    @Published var showRewriteChip: Bool { didSet { guard persist else { return }; defaults.set(showRewriteChip, forKey: "showRewriteChip") } }
    /// "doubleShift" (default) or "none".
    @Published var rewriteTrigger: String { didSet { guard persist else { return }; defaults.set(rewriteTrigger, forKey: "rewriteTrigger") } }
    var visibleRewriteStyles: [RewriteStyle] { rewriteStyles.filter { !$0.hidden } }
    var currentRewriteStyle: RewriteStyle {
        visibleRewriteStyles.first { $0.id == lastRewriteStyle } ?? visibleRewriteStyles.first ?? RewriteStyles.builtIns[0]
    }
    /// Master switch: paused until this time (distantFuture = until resumed). Nil = on.
    @Published var pausedUntil: Date? {
        didSet {
            guard persist else { return }
            if let d = pausedUntil { defaults.set(d.timeIntervalSince1970, forKey: "pausedUntil") } else { defaults.removeObject(forKey: "pausedUntil") }
        }
    }
    var isPaused: Bool { pausedUntil.map { Date() < $0 } ?? false }
    /// Pause trigger: "doubleCommand" (default, ⌘⌘) or "custom" (the recorded shortcut below).
    @Published var pauseTrigger: String { didSet { guard persist else { return }; defaults.set(pauseTrigger, forKey: "pauseTrigger") } }
    var pauseDisplay: String { pauseTrigger == "custom" ? pauseKeyDisplay : "⌘⌘" }
    /// Custom pause / resume shortcut (when pauseTrigger == "custom"; default ⌥⌘N).
    @Published var pauseKeyCode: UInt32 { didSet { guard persist else { return }; defaults.set(Int(pauseKeyCode), forKey: "pauseKeyCode") } }
    @Published var pauseKeyModifiers: UInt32 { didSet { guard persist else { return }; defaults.set(Int(pauseKeyModifiers), forKey: "pauseKeyModifiers") } }
    @Published var pauseKeyDisplay: String { didSet { guard persist else { return }; defaults.set(pauseKeyDisplay, forKey: "pauseKeyDisplay") } }
    /// Turn off macOS's own spelling/grammar underlines and predictive text while Nib is on (opt-in).
    @Published var suppressSystemChecking: Bool { didSet { guard persist else { return }; defaults.set(suppressSystemChecking, forKey: "suppressSystemChecking") } }
    /// Also turn off macOS autocorrect (and with it its bubbles) while Nib is on (opt-in).
    @Published var suppressAutocorrect: Bool { didSet { guard persist else { return }; defaults.set(suppressAutocorrect, forKey: "suppressAutocorrect") } }
    /// Also turn off macOS's grey inline predictive text while Nib is on (opt-in).
    @Published var suppressPrediction: Bool { didSet { guard persist else { return }; defaults.set(suppressPrediction, forKey: "suppressPrediction") } }
    /// Experimental: live underlines and the ✨ chip in VS Code, Cursor and Windsurf (prose files only in the main editor).
    @Published var allowCodeEditors: Bool { didSet { guard persist else { return }; defaults.set(allowCodeEditors, forKey: "allowCodeEditors") } }
    /// Show a diff with Accept/Dismiss instead of replacing straight away.
    @Published var suggestFirst: Bool { didSet { guard persist else { return }; defaults.set(suggestFirst, forKey: "suggestFirst") } }
    let undoDisplay = "⌃⌥Z"
    /// Underlines while typing.
    @Published var liveChecking: Bool { didSet { guard persist else { return }; defaults.set(liveChecking, forKey: "liveChecking") } }
    /// Bundle ids where live checking is off.
    @Published var liveDisabledApps: [String] { didSet { guard persist else { return }; defaults.set(liveDisabledApps, forKey: "liveDisabledApps") } }

    private init() {
        if let stored = defaults.string(forKey: "model"), Settings.oldDefaultModels.contains(stored) {
            defaults.removeObject(forKey: "model")
        }
        // v2: providers. Existing users stay on Gemini (AI Studio) with their key and model.
        provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .gemini
        var m = defaults.dictionary(forKey: "models") as? [String: String] ?? [:]
        if m["gemini"] == nil, let old = defaults.string(forKey: "model"), !old.isEmpty { m["gemini"] = old }
        models = m
        qwenRegion = defaults.string(forKey: "qwenRegion") ?? "intl"
        vertexProject = defaults.string(forKey: "vertexProject") ?? ""
        vertexRegion = defaults.string(forKey: "vertexRegion") ?? "global"
        customBaseURL = defaults.string(forKey: "customBaseURL") ?? ""
        customInstruction = defaults.string(forKey: "customInstruction") ?? ""
        suggestFirst = defaults.bool(forKey: "suggestFirst")
        allowCodeEditors = defaults.bool(forKey: "allowCodeEditors")
        suppressSystemChecking = defaults.bool(forKey: "suppressSystemChecking")
        suppressAutocorrect = defaults.bool(forKey: "suppressAutocorrect")
        suppressPrediction = defaults.bool(forKey: "suppressPrediction")
        pauseTrigger = defaults.string(forKey: "pauseTrigger") ?? "doubleCommand"
        let until = defaults.double(forKey: "pausedUntil")
        pausedUntil = until > 0 ? Date(timeIntervalSince1970: until) : nil
        if defaults.object(forKey: "pauseKeyCode") != nil {
            pauseKeyCode = UInt32(defaults.integer(forKey: "pauseKeyCode"))
            pauseKeyModifiers = UInt32(defaults.integer(forKey: "pauseKeyModifiers"))
            pauseKeyDisplay = defaults.string(forKey: "pauseKeyDisplay") ?? "⌥⌘N"
        } else {
            pauseKeyCode = UInt32(kVK_ANSI_N)
            pauseKeyModifiers = UInt32(optionKey | cmdKey)
            pauseKeyDisplay = "⌥⌘N"
        }
        rewriteStyles = RewriteStyles.load(from: defaults.data(forKey: "rewriteStyles"))
        lastRewriteStyle = defaults.string(forKey: "lastRewriteStyle") ?? RewriteStyles.defaultID
        showRewriteChip = defaults.object(forKey: "showRewriteChip") as? Bool ?? true
        rewriteTrigger = defaults.string(forKey: "rewriteTrigger") ?? "doubleShift"
        popupFont = defaults.string(forKey: "popupFont") ?? ""
        let size = defaults.double(forKey: "popupFontSize")
        popupFontSize = size >= 11 && size <= 20 ? size : Settings.defaultPopupFontSize
        trigger = defaults.string(forKey: "trigger") ?? "doubleOption"
        liveChecking = defaults.object(forKey: "liveChecking") as? Bool ?? true
        liveDisabledApps = defaults.stringArray(forKey: "liveDisabledApps") ?? []
        if defaults.object(forKey: "hotKeyCode") != nil {
            hotKeyCode = UInt32(defaults.integer(forKey: "hotKeyCode"))
            hotKeyModifiers = UInt32(defaults.integer(forKey: "hotKeyModifiers"))
            hotKeyDisplay = defaults.string(forKey: "hotKeyDisplay") ?? "?"
        } else {
            hotKeyCode = UInt32(kVK_ANSI_G)
            hotKeyModifiers = UInt32(controlKey | optionKey)
            hotKeyDisplay = "⌃⌥G"
        }
    }

    func model(for p: Provider) -> String {
        let m = (models[p.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? p.defaultModel : m
    }

    func setModel(_ m: String, for p: Provider) {
        let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == p.defaultModel { models.removeValue(forKey: p.rawValue) } else { models[p.rawValue] = t }
    }

    var effectiveModel: String { model(for: provider) }

    /// A provider's key: the Keychain first, then its environment variable (GEMINI_API_KEY, ANTHROPIC_API_KEY…).
    func key(for p: Provider) -> String? {
        if let acc = p.keyAccount, let k = Keychain.read(account: acc), !k.isEmpty { return k }
        if let e = p.envKey, let k = ProcessInfo.processInfo.environment[e], !k.isEmpty { return k }
        return nil
    }

    /// Non-nil when the active provider is set up enough to try (a key, or a Vertex project / custom server).
    var apiKey: String? {
        switch provider {
        case .vertex: return vertexProject.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "gcloud"
        case .custom: return customBaseURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (key(for: .custom) ?? "")
        default: return key(for: provider)
        }
    }
}

/// API keys in the login Keychain, one item per provider account, under the service "Nib".
/// Keys saved before v1.0.1 live under the service "GrammarAI" and belong to the older signature; they're read
/// once (macOS may ask "Nib wants to use … in your keychain": Always Allow) and copied into a "Nib" item the
/// current app owns, so later reads never prompt. If access is denied, the key simply counts as missing and the
/// setup guide asks for it again.
enum Keychain {
    static var service = "Nib"
    static var legacyService = "GrammarAI"
    static let defaultAccount = "gemini-api-key"

    private static var cache: [String: String?] = [:]
    /// Command-line test runs read an old "GrammarAI" key without moving it, so the move happens in the app itself.
    static var migrate = true
    static func clearCache() { cache.removeAll() }

    /// `--diff-selftest`: the legacy → Nib move, on throwaway items.
    static func selfTest() -> [(String, Bool)] {
        let (realService, realLegacy, realMigrate) = (service, legacyService, migrate)
        service = "NibSelftest"; legacyService = "NibSelftestLegacy"; migrate = true // throwaway items only
        defer {
            for svc in [service, legacyService] {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc] as CFDictionary)
            }
            service = realService; legacyService = realLegacy; migrate = realMigrate; cache.removeAll()
        }
        cache.removeAll()
        let addLegacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService,
                                        kSecAttrAccount as String: defaultAccount, kSecValueData as String: Data("legacy-test-key".utf8)]
        SecItemAdd(addLegacy as CFDictionary, nil)
        var r: [(String, Bool)] = []
        r.append(("an old GrammarAI key is found", read() == "legacy-test-key"))
        r.append(("…and copied into the Nib item", raw(service, defaultAccount) == "legacy-test-key"))
        r.append(("saving replaces the key", save("new-test-key") && raw(service, defaultAccount) == "new-test-key"))
        cache.removeAll()
        r.append(("other providers' keys are separate", read(account: "anthropic-api-key") == nil))
        r.append(("an empty key removes it", save("") && raw(service, defaultAccount) == nil))
        return r
    }

    private static func raw(_ service: String, _ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func read(account: String = defaultAccount) -> String? {
        if let c = cache[account] { return c }
        var value = raw(service, account)
        if value == nil, account == defaultAccount, let legacy = raw(legacyService, account) {
            if migrate, save(legacy, account: account), service == "Nib" { log("keychain: moved the API key to the Nib item") }
            value = legacy
        }
        cache[account] = .some(value)
        return value
    }

    @discardableResult
    static func save(_ key: String, account: String = defaultAccount) -> Bool {
        cache[account] = nil
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { cache[account] = .some(nil); return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrLabel as String] = "Nib API key (\(account))"
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // An item we weren't allowed to delete (owned by an older build): update it instead.
            status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: Data(trimmed.utf8)] as CFDictionary)
        }
        let ok = status == errSecSuccess
        if ok { cache[account] = .some(trimmed) }
        return ok
    }
}
