import SwiftUI
import Combine

final class OnboardingModel: ObservableObject {
    static let sample = "i has went to the store yesterday and buyed three apple, they was delicious."
    /// For UIRender only: draw the "not allowed" state.
    static var forceUntrusted = false
    static func trusted() -> Bool { !forceUntrusted && AXIsProcessTrusted() }
    @Published var axTrusted = OnboardingModel.trusted()
    @Published var text = OnboardingModel.sample
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @ObservedObject var keys: KeyTester
    @ObservedObject var settings = Settings.shared
    var onDone: () -> Void
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var keyReady: Bool { keys.state == .ok || (keys.state == .idle && Settings.shared.apiKey != nil) }
    private var tried: Bool { m.text != OnboardingModel.sample }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Nib").font(.title2.weight(.semibold))
                    Text("Fix grammar and spelling in any app with one shortcut.").foregroundColor(.secondary)
                }
            }

            step(1, "Allow Accessibility access", done: m.axTrusted) {
                Text("Nib needs this to read the text you're writing and put the fixed version back.")
                    .foregroundColor(.secondary)
                HStack {
                    Button("Open Accessibility Settings") { AppDelegate.openAccessibilitySettings() }
                    StatusPill(ok: m.axTrusted, okText: "Allowed", badText: "Not allowed yet")
                }
                if !m.axTrusted {
                    Text("Turn on **Nib** in the list. If Nib is already on but still shows Not allowed: remove it with **−**, then click **Restart Nib** below — macOS will add it back. Turn it on.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Restart Nib") { AppDelegate.relaunch(forAccessibility: true) }
                }
            }

            step(2, "Add your \(Settings.shared.provider.shortName) API key", done: keyReady) {
                HStack {
                    SecureField("API key", text: $keys.key, prompt: Text("Paste your \(Settings.shared.provider.shortName) API key"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { keys.saveAndTest() }
                    Button("Save & Test") { keys.saveAndTest() }.disabled(keys.state == .testing)
                }
                KeyStatusView(state: keys.state)
                if let url = Settings.shared.provider.keyHelpURL {
                    Link("Get an API key →", destination: url).font(.callout)
                }
            }

            step(3, "Privacy: what's sent where", done: settings.privacyConsent) {
                Text(Consent.notice()).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if settings.privacyConsent {
                    StatusPill(ok: true, okText: "Live checking allowed", badText: "")
                } else {
                    HStack {
                        Button("Allow Live Checking") { settings.privacyConsent = true; settings.liveChecking = true }
                        Text("Until you do, nothing is checked as you type.").font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            step(4, "Try it", done: tried) {
                Text(settings.usesDoubleOption
                     ? "Click in the box below, then tap **⌥ Option** twice quickly."
                     : "Click in the box below, then press **\(settings.hotKeyDisplay)**.").foregroundColor(.secondary)
                TextEditor(text: $m.text)
                    .font(.system(size: 14))
                    .frame(height: 64)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("Works the same in Mail, Notes, Messages, Safari, Chrome, Slack and other apps. With nothing selected the whole field is corrected; select text to correct just that part. Press **\(settings.undoDisplay)** to undo.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("You can reopen this from the menu bar icon.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(m.axTrusted && keyReady && settings.privacyConsent ? "Done" : "Finish later") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(tick) { _ in
            let t = OnboardingModel.trusted()
            if t != m.axTrusted { m.axTrusted = t }
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                } else {
                    Text("\(n)").font(.system(size: 13, weight: .semibold)).foregroundColor(.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
