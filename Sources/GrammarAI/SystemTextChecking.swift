import Foundation

/// Optionally turns off macOS's own spelling/grammar underlines and predictive text while Nib is on.
/// Opt-in only. The user's original values are saved first and put back when the option is turned off,
/// when Nib is paused or quits, and on the next launch if Nib ended without restoring them.
enum SystemTextChecking {
    /// Global preference keys (NSGlobalDomain), all set to false while hidden. Predictive text and
    /// completion (NSAutomaticInlinePredictionEnabled, NSAutomaticTextCompletionEnabled) are never touched.
    /// Verified on macOS 27 in an AppKit process (see `--text-checking-probe`):
    ///   NSAllowContinuousSpellChecking: red spelling and blue grammar underlines in AppKit text views
    ///   NSAutomaticSpellingCorrectionEnabled: autocorrect and its correction bubble
    /// WebKit's own keys (Safari, Mail's message body, web views), not verifiable outside WebKit:
    ///   WebContinuousSpellCheckingEnabled, WebGrammarCheckingEnabled, WebAutomaticSpellingCorrectionEnabled
    /// Writing Tools' floating button can't be switched off by a preference: it's a per-view app setting
    /// (writingToolsBehavior); the user is pointed to System Settings → Apple Intelligence & Siri instead.
    /// Autocorrect's bubbles (the suggestion before, and the ↶ revert bubble after) have no preference of their
    /// own (no such key in AppKit or TextInput on macOS 27), so hiding them means turning autocorrect off.
    static let underlineKeys = ["NSAllowContinuousSpellChecking", "WebContinuousSpellCheckingEnabled", "WebGrammarCheckingEnabled"]
    static let autocorrectKeys = ["NSAutomaticSpellingCorrectionEnabled", "WebAutomaticSpellingCorrectionEnabled"]
    /// The grey inline suggestions (verified on macOS 27). Word completion (NSAutomaticTextCompletionEnabled)
    /// is a separate feature and is never touched.
    static let predictionKeys = ["NSAutomaticInlinePredictionEnabled"]
    static var keys: [String] { underlineKeys + autocorrectKeys + predictionKeys }

    /// The preferences domain (the global one; swapped for a throwaway domain in the self-test).
    static var domain: CFString = kCFPreferencesAnyApplication
    static var savedKey = "systemTextOriginals"
    /// The self-test works on a throwaway domain and mustn't write to the user's log.
    static var quiet = false
    private static func note(_ m: String) { if !quiet { log(m) } }
    private static let absent = "__absent__"

    private static func read(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func write(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetValue(key as CFString, value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func flush() {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// True while Nib holds the user's originals (i.e. it has changed the system values).
    static var isSuppressing: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    /// Puts the system in line with the settings: each group is off only while its option is on and Nib isn't paused.
    static func sync() {
        let s = Settings.shared
        var want: [String] = []
        if !s.isPaused {
            if s.suppressSystemChecking { want += underlineKeys }
            if s.suppressAutocorrect { want += autocorrectKeys }
            if s.suppressPrediction { want += predictionKeys }
        }
        apply(want)
    }

    static func suppress() { apply(keys) }
    static func restore() { apply([]) }

    /// Turns `want` off and restores every other key Nib had changed. Originals are saved per key, once,
    /// so a crash or a second call never overwrites them with "off".
    /// Test copies (E2E) never touch the user's macOS text settings.
    static var disabled = false

    static func apply(_ want: [String]) {
        guard !disabled else { return }
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        for k in Array(saved.keys) where !want.contains(k) {
            let v = saved[k]
            if let s = v as? String, s == absent { write(k, nil) } else { write(k, v as CFPropertyList?) }
            saved.removeValue(forKey: k)
            note("system text checking: restored \(k)")
        }
        for k in want {
            if saved[k] == nil { saved[k] = read(k) ?? absent as CFString; note("system text checking: saved \(k), turning off") }
            write(k, kCFBooleanFalse)
        }
        flush()
        if saved.isEmpty { UserDefaults.standard.removeObject(forKey: savedKey) } else { UserDefaults.standard.set(saved, forKey: savedKey) }
    }

    /// For the report / Settings: the current global values.
    static func describe() -> String {
        keys.map { k in "\(k)=\(read(k).map { "\($0)" } ?? "(not set)")" }.joined(separator: " ")
    }
}

/// `--diff-selftest`: the save → suppress → crash → restore cycle against a throwaway domain.
enum SystemTextSelfTest {
    static func run() -> [(String, Bool)] {
        let realDomain = SystemTextChecking.domain, realSaved = SystemTextChecking.savedKey
        let test = "com.ruiwang.nib.selftest" as CFString
        SystemTextChecking.domain = test
        SystemTextChecking.savedKey = "selftestSystemTextOriginals"
        SystemTextChecking.quiet = true
        defer {
            for k in SystemTextChecking.keys + ["NSAutomaticInlinePredictionEnabled"] { CFPreferencesSetValue(k as CFString, nil, test, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
            CFPreferencesSynchronize(test, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            UserDefaults.standard.removeObject(forKey: SystemTextChecking.savedKey)
            SystemTextChecking.domain = realDomain; SystemTextChecking.savedKey = realSaved; SystemTextChecking.quiet = false
        }
        func get(_ k: String) -> Any? { CFPreferencesCopyValue(k as CFString, test, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
        // The user's originals: autocorrect on, predictive text on (must never be touched), the rest not set.
        CFPreferencesSetValue("NSAutomaticSpellingCorrectionEnabled" as CFString, kCFBooleanTrue, test, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("NSAutomaticInlinePredictionEnabled" as CFString, kCFBooleanTrue, test, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(test, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        var r: [(String, Bool)] = []
        SystemTextChecking.apply(SystemTextChecking.underlineKeys + SystemTextChecking.autocorrectKeys)
        r.append(("predictive text left on unless its switch is on", (get("NSAutomaticInlinePredictionEnabled") as? Bool) == true))
        SystemTextChecking.suppress()
        r.append(("suppress turns every key off", SystemTextChecking.keys.allSatisfy { (get($0) as? Bool) == false }))
        r.append(("word completion is never touched", get("NSAutomaticTextCompletionEnabled") == nil))
        SystemTextChecking.suppress() // e.g. relaunch after a crash: originals must not be overwritten with "off"
        r.append(("a second suppress keeps the saved originals", (UserDefaults.standard.dictionary(forKey: SystemTextChecking.savedKey)?["NSAutomaticSpellingCorrectionEnabled"] as? Bool) == true))
        SystemTextChecking.apply(SystemTextChecking.underlineKeys + SystemTextChecking.autocorrectKeys) // predictive-text switch off
        r.append(("turning off the predictive-text switch restores only predictive text", (get("NSAutomaticInlinePredictionEnabled") as? Bool) == true && (get("NSAutomaticSpellingCorrectionEnabled") as? Bool) == false))
        SystemTextChecking.apply(SystemTextChecking.underlineKeys) // autocorrect option turned off, underlines still hidden
        r.append(("turning off one group restores only that group", (get("NSAutomaticSpellingCorrectionEnabled") as? Bool) == true && (get("NSAllowContinuousSpellChecking") as? Bool) == false))
        SystemTextChecking.restore()
        r.append(("restore puts back a value the user had", (get("NSAutomaticSpellingCorrectionEnabled") as? Bool) == true))
        r.append(("restore removes keys the user never set", get("NSAllowContinuousSpellChecking") == nil && get("WebGrammarCheckingEnabled") == nil))
        r.append(("nothing left saved after restore", !SystemTextChecking.isSuppressing))
        SystemTextChecking.restore()
        r.append(("restore with nothing saved changes nothing", (get("NSAutomaticSpellingCorrectionEnabled") as? Bool) == true && (get("NSAutomaticInlinePredictionEnabled") as? Bool) == true))
        r.append(("everything restored: predictive text back on", (get("NSAutomaticInlinePredictionEnabled") as? Bool) == true))
        return r
    }
}
