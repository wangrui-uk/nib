import SwiftUI

/// The active provider's key, model list and connection test (Settings → AI, and the setup guide).
final class KeyTester: ObservableObject {
    enum State: Equatable { case idle, testing, ok, failed(String) }
    @Published var key: String = ""
    @Published var state: State = .idle
    @Published var loadedModels: [String] = []
    @Published var loadingModels = false
    @Published var modelMessage = ""
    /// What's typed in the Model ID field; it takes effect only on Enter (a stray keypress can't break Nib).
    @Published var modelDraft = ""
    @Published var editingModel = false

    init() { reload() }

    private var provider: Provider { Settings.shared.provider }

    /// Shows the saved key for the selected provider (after switching providers).
    func reload() {
        key = provider.keyAccount.flatMap { Keychain.read(account: $0) } ?? ""
        modelDraft = Settings.shared.model(for: provider)
        editingModel = false
        state = .idle
        loadedModels = []
        modelMessage = ""
    }

    @discardableResult
    func saveKey() -> Bool {
        guard let account = provider.keyAccount else { return true }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        key = k
        guard Keychain.save(k, account: account) else { state = .failed("Couldn't save the key to the Keychain."); return false }
        return true
    }

    private func endpoint() -> AIEndpoint {
        let s = Settings.shared
        return AIEndpoint(provider: s.provider, model: s.effectiveModel, key: s.key(for: s.provider))
    }

    /// Saves the key and makes one tiny request with the chosen model.
    func saveAndTest() {
        guard saveKey() else { return }
        state = .testing
        let ep = endpoint()
        Task { @MainActor in
            do {
                try await AI.test(ep)
                self.state = .ok
            } catch {
                self.state = .failed("Not working: " + error.localizedDescription)
            }
        }
    }

    func loadModels() {
        guard saveKey() else { return }
        loadingModels = true
        modelMessage = ""
        let ep = endpoint()
        Task { @MainActor in
            do {
                let list = try await AI.listModels(ep)
                self.loadedModels = list
                self.modelMessage = "\(list.count) model\(list.count == 1 ? "" : "s") available."
            } catch {
                self.loadedModels = []
                self.modelMessage = "Not working: " + error.localizedDescription
            }
            self.loadingModels = false
        }
    }
}

struct KeyStatusView: View {
    let state: KeyTester.State
    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .idle:
                let p = Settings.shared.provider
                if p == .vertex {
                    Image(systemName: "person.badge.key").foregroundColor(.secondary)
                    Text("Uses your gcloud sign-in on this Mac.").foregroundColor(.secondary)
                } else if p.keyAccount.flatMap({ Keychain.read(account: $0) }) != nil {
                    Image(systemName: "key.fill").foregroundColor(.secondary)
                    Text("Key saved in your Keychain.").foregroundColor(.secondary)
                } else if let e = p.envKey, ProcessInfo.processInfo.environment[e] != nil {
                    Image(systemName: "terminal").foregroundColor(.secondary)
                    Text("Using \(e) from the environment.").foregroundColor(.secondary)
                } else {
                    Image(systemName: "key").foregroundColor(.secondary)
                    Text(p.keyRequired ? "No key yet." : "No key (optional).").foregroundColor(.secondary)
                }
            case .testing:
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundColor(.secondary)
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Working: \(Settings.shared.provider.shortName) · \(Settings.shared.effectiveModel)").foregroundColor(.green)
            case .failed(let msg):
                Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                Text(msg).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }
}

struct StatusPill: View {
    let ok: Bool
    let okText: String
    let badText: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(ok ? okText : badText).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill((ok ? Color.green : Color.red).opacity(0.12)))
    }
}
