import AppKit

/// The privacy notice, and the user's OK before live checking runs. ⌥⌥ and ⇧⇧ send text only when the user asks,
/// so only live checking (which sends paragraphs as you type) needs this explicit confirmation.
enum Consent {
    static func notice(_ p: Provider = Settings.shared.provider) -> String {
        let to: String
        if p == .custom, let host = URL(string: Settings.shared.customBaseURL)?.host { to = "your server (\(host))" }
        else { to = p.name }
        return "Your text is sent to \(to) using your own key. Live checking sends paragraphs as you type (about a second after you stop), "
            + "only from the field you're typing in; ⌥⌥ and ⇧⇧ send the text you correct or rewrite. "
            + "There's no Nib server and no analytics, and Nib's log never contains your text. Password fields and terminals are never read."
    }

    private static var asking = false

    /// Asks for the OK (once at a time). Returns true if the user allowed live checking.
    @discardableResult
    static func ask() -> Bool {
        let s = Settings.shared
        if s.privacyConsent { return true }
        guard !asking else { return false }
        asking = true
        defer { asking = false }
        let a = NSAlert()
        a.messageText = "Allow live checking?"
        a.informativeText = notice() + "\n\nYou can change this any time in Settings → Privacy."
        a.addButton(withTitle: "Allow Live Checking")
        a.addButton(withTitle: "Not Now")
        if let icon = NSApp.applicationIconImage { a.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        let allowed = a.runModal() == .alertFirstButtonReturn
        if allowed {
            s.privacyConsent = true
            s.liveChecking = true
            log("privacy: live checking allowed")
        } else {
            log("privacy: live checking not allowed yet")
        }
        return allowed
    }
}
