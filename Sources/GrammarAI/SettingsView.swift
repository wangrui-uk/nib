import SwiftUI
import Combine
import ServiceManagement
import Carbon.HIToolbox

/// View state lives in ObservableObjects: the Command Line Tools have no SwiftUI macro plugin for @State.
final class SettingsModel: ObservableObject {
    @Published var recording = false
    @Published var recordingPause = false
    var monitor: Any?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError = ""
    @Published var axTrusted = AXIsProcessTrusted()
}

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var m: SettingsModel
    @ObservedObject var keys: KeyTester
    var onHotKeyChange: () -> Void = {}
    var onRewriteTriggerChange: () -> Void = {}
    var onPauseKeyChange: () -> Void = {}
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            AISection(settings: settings, keys: keys)

            Section("Correction") {
                Picker("When a correction is ready", selection: $settings.suggestFirst) {
                    Text("Apply it").tag(false)
                    Text("Show it first").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("Extra instruction", text: $settings.customInstruction,
                          prompt: Text("Optional, e.g. “Use British English”"), axis: .vertical)
                    .lineLimit(1...4)
            }

            Section {
                Toggle("Underline mistakes as I type", isOn: $settings.liveChecking)
                    .onChange(of: settings.liveChecking) { on in
                        guard on, !settings.privacyConsent else { return }
                        DispatchQueue.main.async { if !Consent.ask() { settings.liveChecking = false } }
                    }
                Toggle("Allow underlines in code editors (experimental)", isOn: $settings.allowCodeEditors)
                Text("VS Code, Cursor and Windsurf. In the main editor only prose files are checked (.md, .markdown, .txt, .rst and untitled files), and only the lines on screen; code files are never sent. In VS Code, also turn on its Settings → “Editor: Accessibility Support” → on, or it doesn't show where its text is. Side boxes (commit message, search, chat) are checked like any field. ⌥⌥ and ⇧⇧ work in code editors either way.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Hide macOS spelling & grammar underlines while Nib is on", isOn: $settings.suppressSystemChecking)
                    .onChange(of: settings.suppressSystemChecking) { _ in SystemTextChecking.sync() }
                Toggle("Also turn off macOS autocorrect (removes its bubbles too)", isOn: $settings.suppressAutocorrect)
                    .onChange(of: settings.suppressAutocorrect) { _ in SystemTextChecking.sync() }
                Toggle("Also turn off macOS predictive text (grey inline suggestions)", isOn: $settings.suppressPrediction)
                    .onChange(of: settings.suppressPrediction) { _ in SystemTextChecking.sync() }
                Text("macOS has no setting for autocorrect's bubbles on their own (the suggestion bubble and the ↶ revert bubble), so they go only if autocorrect goes. Each switch is separate; word completion is never touched. Your own settings are saved and put back when you turn a switch off (only its settings), pause Nib or quit it. Apps pick changes up when reopened: quit and reopen TextEdit, Notes, Mail, Messages, Pages, Safari…")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Slack, Chrome, VS Code and other Electron apps use their own spell checker — turn it off in that app (Slack: Settings → Language & region → Enable spellcheck).")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("The Writing Tools button that appears on selected text can't be turned off by another app. To hide it, open System Settings → Apple Intelligence & Siri and turn off Apple Intelligence (this removes Writing Tools everywhere).")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if !settings.liveDisabledApps.isEmpty {
                    ForEach(settings.liveDisabledApps, id: \.self) { id in
                        HStack {
                            Text("Off in \(appName(id))").foregroundColor(.secondary)
                            Spacer()
                            Button("Turn On") { settings.liveDisabledApps.removeAll { $0 == id } }.controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Live checking")
            } footer: {
                Text("Hover over an underline, or put the cursor in it, to see the fix. Works in apps that report text positions (TextEdit, Notes, Mail, Messages, Safari…). To turn it off for one app, use the menu bar icon while that app is in front.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Picker("Font", selection: $settings.popupFont) {
                    Text("System").tag("")
                    Text("System Monospaced").tag("__mono__")
                    Divider()
                    ForEach(SettingsView.fontFamilies, id: \.self) { f in
                        Text(f).tag(f)
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.popupFontSize, in: 11...20, step: 1).frame(width: 180)
                        Text("\(Int(settings.popupFontSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                AppearancePreview(settings: settings)
                HStack {
                    Spacer()
                    Button("Reset to Default") {
                        settings.popupFont = ""
                        settings.popupFontSize = Settings.defaultPopupFontSize
                    }
                    .disabled(settings.popupFont.isEmpty && settings.popupFontSize == Settings.defaultPopupFontSize)
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Used by the underline popup, the suggestion panel and the “Fixed” message.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle("Show ✨ Rewrite button when text is selected", isOn: $settings.showRewriteChip)
                Picker("Shortcut", selection: $settings.rewriteTrigger) {
                    Text("Double-tap ⇧").tag("doubleShift")
                    Text("Menu only").tag("none")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.rewriteTrigger) { _ in onRewriteTriggerChange() }
                RewriteStylesEditor(settings: settings)
            } header: {
                Text("Rewrite selection")
            } footer: {
                Text("Select text and click ✨ Rewrite, double-tap ⇧ Shift, or use the menu bar icon. Nothing is sent to the AI until you do. The style menu in the card remembers your last choice.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Shortcuts") {
                Picker("Correct text with", selection: $settings.trigger) {
                    Text("Double-tap ⌥").tag("doubleOption")
                    Text("Custom shortcut").tag("custom")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.trigger) { _ in onHotKeyChange() }
                if settings.usesDoubleOption {
                    Text("Tap the Option key twice quickly, with nothing else pressed. Using ⌥ to type characters or with other keys doesn't trigger it.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    LabeledContent("Shortcut") {
                        HStack {
                            Text(m.recording ? "Press a shortcut…" : settings.hotKeyDisplay)
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .foregroundColor(m.recording ? .accentColor : .primary)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                            Button(m.recording ? "Cancel" : "Change…") { m.recording ? stopRecording() : startRecording() }
                        }
                    }
                }
                Picker("Pause / resume Nib with", selection: $settings.pauseTrigger) {
                    Text("Double-tap ⌘").tag("doubleCommand")
                    Text("Custom shortcut").tag("custom")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.pauseTrigger) { _ in onPauseKeyChange() }
                if settings.pauseTrigger == "custom" {
                    LabeledContent("Pause shortcut") {
                        HStack {
                            Text(m.recordingPause ? "Press a shortcut…" : settings.pauseKeyDisplay)
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .foregroundColor(m.recordingPause ? .accentColor : .primary)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                            Button(m.recordingPause ? "Cancel" : "Change…") { m.recordingPause ? stopRecording() : startRecording(pause: true) }
                        }
                    }
                } else {
                    Text("Tap ⌘ Command twice quickly, with nothing else pressed. ⌘C, ⌘Tab, ⌘-click or holding ⌘ don't trigger it. Correct is ⌥⌥ and Rewrite is ⇧⇧.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Undo last correction") {
                    Text(settings.undoDisplay)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                }
            }

            Section("Privacy") {
                Text(Consent.notice()).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if settings.privacyConsent {
                    HStack {
                        StatusPill(ok: true, okText: "Live checking allowed", badText: "")
                        Spacer()
                        Button("Withdraw") { settings.privacyConsent = false; settings.liveChecking = false }
                    }
                } else {
                    HStack {
                        StatusPill(ok: false, okText: "", badText: "Live checking not allowed")
                        Spacer()
                        Button("Allow Live Checking") { Consent.ask() }
                    }
                }
                Link("Privacy details →", destination: URL(string: "https://wangrui-uk.github.io/nib/privacy.html")!).font(.callout)
            }

            if Updates.shared.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(get: { Updates.shared.automaticallyChecks },
                                                                           set: { Updates.shared.automaticallyChecks = $0 }))
                    HStack {
                        Text("Nib \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").foregroundColor(.secondary)
                        Spacer()
                        Button("Check Now") { Updates.shared.checkForUpdates(nil) }
                    }
                }
            }

            Section("System") {
                LabeledContent("Accessibility") {
                    HStack {
                        StatusPill(ok: m.axTrusted, okText: "Allowed", badText: "Not allowed")
                        if !m.axTrusted { Button("Open Settings") { AppDelegate.openAccessibilitySettings() } }
                    }
                }
                Toggle("Open at login", isOn: $m.launchAtLogin)
                    .onChange(of: m.launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            m.loginError = ""
                        } catch { m.loginError = error.localizedDescription }
                    }
                if !m.loginError.isEmpty { Text(m.loginError).font(.caption).foregroundColor(.red) }
            }
        }
        .formStyle(.grouped)
        // Taller than most screens with every section open: a fixed height, and the form scrolls.
        .frame(width: 480, height: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .onReceive(tick) { _ in
            let t = AXIsProcessTrusted()
            if t != m.axTrusted { m.axTrusted = t }
        }
        .onDisappear { if m.recording || m.recordingPause { stopRecording() } }
    }

    static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func startRecording(pause: Bool = false) {
        if m.monitor != nil { stopRecording() }
        if pause { m.recordingPause = true } else { m.recording = true }
        HotKey.shared.unregister(id: pause ? AppDelegate.pauseID : AppDelegate.correctID)
        m.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }
            guard !mods.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            let code = UInt32(event.keyCode), carbon = HotKey.carbonModifiers(mods), display = HotKey.display(mods, key: keyName(event))
            if pause {
                settings.pauseKeyCode = code; settings.pauseKeyModifiers = carbon; settings.pauseKeyDisplay = display
            } else {
                settings.hotKeyCode = code; settings.hotKeyModifiers = carbon; settings.hotKeyDisplay = display
            }
            stopRecording()
            return nil
        }
    }

    private func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        default:
            // The plain character: ⌥ changes the character on macOS.
            return event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        }
    }

    private func stopRecording() {
        if let mon = m.monitor { NSEvent.removeMonitor(mon) }
        m.monitor = nil
        let wasPause = m.recordingPause
        m.recording = false
        m.recordingPause = false
        if wasPause { onPauseKeyChange() } else { onHotKeyChange(); onPauseKeyChange() }
    }
}

/// Both popups, redrawn as the font and size change.
struct AppearancePreview: View {
    @ObservedObject var settings: Settings
    var body: some View {
        // Reading the settings here makes SwiftUI redraw the preview when they change.
        let _ = (settings.popupFont, settings.popupFontSize)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                IssueView(issue: Issue(kind: "grammar", text: "has went", fix: "went", reason: "wrong verb form"),
                          total: 3, apply: {}, ignore: {})
                SuggestionView(pieces: WordDiff.diff("i has went to the store", "I went to the store"),
                               count: 1, accept: {}, reject: {})
            }
            .id("\(settings.popupFont)|\(settings.popupFontSize)")
        }
        .allowsHitTesting(false)
    }
}

/// Rewrite styles: show/hide, reorder, edit instructions, add your own.
struct RewriteStylesEditor: View {
    @ObservedObject var settings: Settings
    var body: some View {
        DisclosureGroup("Styles (\(settings.visibleRewriteStyles.count) shown)") {
            ForEach(Array(settings.rewriteStyles.enumerated()), id: \.element.id) { i, style in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Name", text: binding(i, \.name))
                        TextEditor(text: binding(i, \.instruction))
                            .font(.callout)
                            .frame(height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        HStack {
                            if style.builtIn, let original = RewriteStyles.builtIns.first(where: { $0.id == style.id }),
                               original.instruction != style.instruction || original.name != style.name {
                                Button("Restore Original") {
                                    settings.rewriteStyles[i].name = original.name
                                    settings.rewriteStyles[i].instruction = original.instruction
                                }
                            }
                            Spacer()
                            if !style.builtIn {
                                Button("Delete", role: .destructive) { settings.rewriteStyles.remove(at: i) }
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        Toggle("", isOn: Binding(get: { !settings.rewriteStyles[i].hidden },
                                                 set: { settings.rewriteStyles[i].hidden = !$0 }))
                            .labelsHidden().toggleStyle(.checkbox)
                        Text(style.name).foregroundColor(style.hidden ? .secondary : .primary)
                        Spacer()
                        Button { move(i, -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(i == settings.rewriteStyles.count - 1)
                    }
                }
            }
            HStack {
                Button("Add Style") {
                    settings.rewriteStyles.append(RewriteStyle(id: "custom-\(UUID().uuidString.prefix(8))", name: "My style",
                                                               instruction: "Describe the tone and purpose, e.g. “Short, upbeat Slack message to my team.”",
                                                               builtIn: false))
                }
                Spacer()
                Button("Reset All Styles") { settings.rewriteStyles = RewriteStyles.builtIns }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    private func binding(_ i: Int, _ key: WritableKeyPath<RewriteStyle, String>) -> Binding<String> {
        Binding(get: { i < settings.rewriteStyles.count ? settings.rewriteStyles[i][keyPath: key] : "" },
                set: { if i < settings.rewriteStyles.count { settings.rewriteStyles[i][keyPath: key] = $0 } })
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard j >= 0, j < settings.rewriteStyles.count else { return }
        settings.rewriteStyles.swapAt(i, j)
    }
}

/// Settings → AI: provider, key, model, test.
struct AISection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var keys: KeyTester
    var body: some View {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(Provider.allCases) { Text($0.name).tag($0) }
                }
                .onChange(of: settings.provider) { _ in keys.reload() }
                if settings.provider == .qwen {
                    Picker("Region", selection: $settings.qwenRegion) {
                        Text("International").tag("intl")
                        Text("China (mainland)").tag("cn")
                    }
                    .pickerStyle(.segmented)
                }
                if settings.provider == .vertex {
                    TextField("Project ID", text: $settings.vertexProject, prompt: Text("my-gcp-project"))
                    TextField("Region", text: $settings.vertexRegion, prompt: Text("global"))
                }
                if settings.provider == .custom {
                    TextField("Base URL", text: $settings.customBaseURL, prompt: Text("https://example.com/v1"))
                }
                if settings.provider != .vertex {
                    HStack {
                        SecureField(settings.provider.keyRequired ? "API key" : "API key (optional)", text: $keys.key,
                                    prompt: Text(settings.provider == .custom ? "Paste the server's API key" : "Paste your \(settings.provider.shortName) API key"))
                            .onSubmit { keys.saveAndTest() }
                        Button("Save") { if keys.saveKey() { keys.state = .idle } }
                    }
                }
                HStack {
                    Picker("Model", selection: modelBinding) {
                        ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Button(keys.loadingModels ? "Loading…" : "Load models") { keys.loadModels() }
                        .disabled(keys.loadingModels)
                }
                // The model ID is shown read-only; a custom ID only changes through Edit… → Save.
                if keys.editingModel {
                    HStack {
                        TextField("Model ID", text: $keys.modelDraft, prompt: Text(settings.provider.defaultModel.isEmpty ? "model id" : settings.provider.defaultModel))
                            .onSubmit { saveModelDraft() }
                        Button("Save") { saveModelDraft() }
                            .disabled(keys.modelDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { keys.modelDraft = settings.model(for: settings.provider); keys.editingModel = false }
                    }
                } else {
                    LabeledContent("Model ID") {
                        HStack {
                            Text(settings.model(for: settings.provider)).font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Button("Edit…") { keys.modelDraft = settings.model(for: settings.provider); keys.editingModel = true }
                                .controlSize(.small)
                        }
                    }
                }
                if !keys.modelMessage.isEmpty {
                    Text(keys.modelMessage).font(.caption)
                        .foregroundColor(keys.modelMessage.hasPrefix("Not working") ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Test connection") { keys.saveAndTest() }.disabled(keys.state == .testing)
                    KeyStatusView(state: keys.state)
                }
            } header: {
                Text("AI")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(providerHelp).font(.caption).foregroundColor(.secondary)
                    if let url = settings.provider.keyHelpURL {
                        Link("Get an API key →", destination: url).font(.caption)
                    }
                }
            }

    }

    private func saveModelDraft() {
        let m = keys.modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return }
        settings.setModel(m, for: settings.provider)
        keys.editingModel = false
        keys.state = .idle
        log("settings: model set to \(m) for \(settings.provider.rawValue)")
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.model(for: settings.provider) }, set: { settings.setModel($0, for: settings.provider); keys.modelDraft = $0 })
    }

    /// Loaded models (or the built-in list), always including the current choice.
    private var modelOptions: [String] {
        var list = keys.loadedModels.isEmpty ? settings.provider.fallbackModels : keys.loadedModels
        let current = settings.model(for: settings.provider)
        if !current.isEmpty && !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    private var providerHelp: String {
        switch settings.provider {
        case .gemini: return "One provider and model are used for everything: underlines, ⌥⌥ and rewrites."
        case .vertex: return "Uses your existing Google Cloud sign-in on this Mac (gcloud, or Application Default Credentials). Nib doesn't sign you in."
        case .qwen: return "International and China keys are different: pick the region your key is from."
        case .custom: return "Any server with an OpenAI-compatible /chat/completions endpoint (e.g. Ollama, LM Studio, OpenRouter)."
        case .deepseek: return "deepseek-chat is the fast choice; deepseek-reasoner is slower."
        default: return "One provider and model are used for everything: underlines, ⌥⌥ and rewrites."
        }
    }

}

/// For UIRender only.
struct AISectionPreview: View {
    @ObservedObject var keys: KeyTester
    var body: some View {
        Form { AISection(settings: Settings.shared, keys: keys) }.formStyle(.grouped).frame(width: 480).fixedSize(horizontal: false, vertical: true)
    }
}
