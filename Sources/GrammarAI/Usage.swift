import AppKit

/// Local usage statistics: per AI call the time, feature, provider, model and token counts. Never any text.
/// Stored in ~/Library/Application Support/Nib/usage.json: the last 1,000 calls and 90 days of daily totals.
/// Nothing is sent anywhere.
enum UsageFeature: String, Codable, CaseIterable {
    case live, correct, rewrite, test, other
    var label: String {
        switch self {
        case .live: return "Live checking"
        case .correct: return "Correct (⌥⌥)"
        case .rewrite: return "Rewrite"
        case .test: return "Test connection"
        case .other: return "Other"
        }
    }
}

/// Token counts as the provider reported them; nil = not reported. Thinking/reasoning tokens are counted separately
/// (and not included in `output`).
struct TokenUsage: Equatable {
    var input: Int?
    var output: Int?
    var thinking: Int?
    var reported: Bool { input != nil || output != nil }
}

/// Reads the usage block of each protocol's response. Pure, for self-tests.
enum UsageParse {
    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    /// Gemini: usageMetadata.promptTokenCount / candidatesTokenCount / thoughtsTokenCount (candidates exclude thoughts).
    static func gemini(_ json: [String: Any]) -> TokenUsage {
        guard let u = json["usageMetadata"] as? [String: Any] else { return TokenUsage() }
        return TokenUsage(input: int(u["promptTokenCount"]), output: int(u["candidatesTokenCount"]), thinking: int(u["thoughtsTokenCount"]))
    }

    /// Anthropic: usage.input_tokens (+ cache reads/writes, also input) / output_tokens.
    static func anthropic(_ json: [String: Any]) -> TokenUsage {
        guard let u = json["usage"] as? [String: Any] else { return TokenUsage() }
        var input = int(u["input_tokens"])
        if let i = input { input = i + (int(u["cache_creation_input_tokens"]) ?? 0) + (int(u["cache_read_input_tokens"]) ?? 0) }
        return TokenUsage(input: input, output: int(u["output_tokens"]), thinking: nil)
    }

    /// OpenAI-compatible: usage.prompt_tokens / completion_tokens; reasoning tokens (completion_tokens_details.
    /// reasoning_tokens, or DeepSeek's top-level reasoning_tokens) are inside completion_tokens, so they're taken out.
    static func openAI(_ json: [String: Any]) -> TokenUsage {
        guard let u = json["usage"] as? [String: Any] else { return TokenUsage() }
        let reasoning = int((u["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]) ?? int(u["reasoning_tokens"])
        var output = int(u["completion_tokens"])
        if let o = output, let r = reasoning, r <= o { output = o - r }
        return TokenUsage(input: int(u["prompt_tokens"]), output: output, thinking: reasoning.flatMap { $0 > 0 ? $0 : nil })
    }
}

struct UsageCall: Codable, Equatable {
    var date: Date
    var feature: UsageFeature
    var provider: String
    var model: String
    var input: Int?
    var output: Int?
    var thinking: Int?
}

/// One day's totals for one feature, provider and model.
struct UsageDay: Codable, Equatable {
    var day: String // yyyy-MM-dd, local time
    var feature: UsageFeature
    var provider: String
    var model: String
    var calls = 0
    var unreported = 0
    var input = 0
    var output = 0
    var thinking = 0
}

struct UsageSummary: Equatable {
    var calls = 0, unreported = 0, input = 0, output = 0, thinking = 0
    var byFeature: [(UsageFeature, Int, Int)] = [] // feature, calls, tokens (in + out + thinking)
    var byModel: [(String, Int, Int)] = []        // "Provider · model", calls, tokens
    var tokens: Int { input + output + thinking }
    static func == (a: UsageSummary, b: UsageSummary) -> Bool {
        a.calls == b.calls && a.unreported == b.unreported && a.input == b.input && a.output == b.output && a.thinking == b.thinking
    }
}

final class Usage: ObservableObject {
    static let shared = Usage()
    static let maxCalls = 1000
    static let keepDays = 90

    /// Only a normal launch of the app records (not tests or command-line modes).
    var recording = false
    @Published private(set) var revision = 0

    private struct Store: Codable { var calls: [UsageCall] = []; var days: [UsageDay] = [] }
    private var store = Store()
    private let queue = DispatchQueue(label: "nib.usage")
    private let url: URL?

    init(url: URL? = Usage.defaultURL()) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            store = (try? d.decode(Store.self, from: data)) ?? Store()
        }
    }

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib", isDirectory: true).appendingPathComponent("usage.json")
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The last parsed usage, recorded or not (for `--ai-check`).
    static var lastParsed: TokenUsage?

    func record(_ feature: UsageFeature, provider: Provider, model: String, _ u: TokenUsage, at date: Date = Date()) {
        Self.lastParsed = u
        guard recording else { return }
        add(feature, provider: provider.name, model: model, u, at: date)
    }

    /// Adds a call (also used by self-tests on a private instance).
    func add(_ feature: UsageFeature, provider: String, model: String, _ u: TokenUsage, at date: Date = Date()) {
        queue.sync {
            store.calls.append(UsageCall(date: date, feature: feature, provider: provider, model: model, input: u.input, output: u.output, thinking: u.thinking))
            if store.calls.count > Self.maxCalls { store.calls.removeFirst(store.calls.count - Self.maxCalls) }
            let key = Self.dayKey(date)
            if let i = store.days.firstIndex(where: { $0.day == key && $0.feature == feature && $0.provider == provider && $0.model == model }) {
                apply(u, to: &store.days[i])
            } else {
                var d = UsageDay(day: key, feature: feature, provider: provider, model: model)
                apply(u, to: &d)
                store.days.append(d)
            }
            let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: date) ?? date)
            store.days.removeAll { $0.day < cutoff }
            save()
        }
        DispatchQueue.main.async { self.revision += 1 }
    }

    private func apply(_ u: TokenUsage, to d: inout UsageDay) {
        d.calls += 1
        if !u.reported { d.unreported += 1 }
        d.input += u.input ?? 0
        d.output += u.output ?? 0
        d.thinking += u.thinking ?? 0
    }

    /// Totals for the last `days` calendar days including today (1 = today).
    func summary(days: Int, now: Date = Date()) -> UsageSummary {
        let from = Self.dayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let rows = queue.sync { store.days.filter { $0.day >= from } }
        var s = UsageSummary()
        var feat: [UsageFeature: (Int, Int)] = [:], model: [String: (Int, Int)] = [:]
        for r in rows {
            s.calls += r.calls; s.unreported += r.unreported; s.input += r.input; s.output += r.output; s.thinking += r.thinking
            let t = r.input + r.output + r.thinking
            feat[r.feature, default: (0, 0)].0 += r.calls; feat[r.feature, default: (0, 0)].1 += t
            let m = "\(r.provider) · \(r.model)"
            model[m, default: (0, 0)].0 += r.calls; model[m, default: (0, 0)].1 += t
        }
        s.byFeature = UsageFeature.allCases.compactMap { f in feat[f].map { (f, $0.0, $0.1) } }
        s.byModel = model.sorted { $0.value.1 > $1.value.1 }.map { ($0.key, $0.value.0, $0.value.1) }
        return s
    }

    func reset() {
        queue.sync { store = Store(); save() }
        DispatchQueue.main.async { self.revision += 1 }
    }

    /// The last 1,000 calls as CSV (no text, ever).
    func csv() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        func q(_ s: String) -> String { s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        var out = "time,feature,provider,model,input_tokens,output_tokens,thinking_tokens,tokens_reported\n"
        for c in queue.sync(execute: { store.calls }) {
            out += [f.string(from: c.date), c.feature.rawValue, q(c.provider), q(c.model), c.input.map(String.init) ?? "", c.output.map(String.init) ?? "",
                    c.thinking.map(String.init) ?? "", (c.input != nil || c.output != nil) ? "yes" : "no"].joined(separator: ",") + "\n"
        }
        return out
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(store) { try? data.write(to: url, options: .atomic) }
    }

    /// "1,234" / "12.3k" / "1.2M".
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

import SwiftUI
import UniformTypeIdentifiers

final class UsagePeriod: ObservableObject { @Published var days = 1 }

/// Settings → Usage: calls and tokens for today, 7 or 30 days, by feature and (if more than one) by model.
struct UsageSection: View {
    @ObservedObject var usage: Usage = .shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject var period = UsagePeriod()

    var body: some View {
        let _ = usage.revision
        let s = usage.summary(days: period.days)
        Section {
            Picker("Period", selection: $period.days) {
                Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            LabeledContent("Calls", value: Usage.short(s.calls))
            LabeledContent("Tokens") {
                Text("\(Usage.short(s.input)) in · \(Usage.short(s.output)) out" + (s.thinking > 0 ? " · \(Usage.short(s.thinking)) thinking" : ""))
            }
            if s.unreported > 0 {
                Text("\(s.unreported) call\(s.unreported == 1 ? "" : "s") without token counts (the provider didn't report them).")
                    .font(.caption).foregroundColor(.secondary)
            }
            if !s.byFeature.isEmpty {
                ForEach(s.byFeature, id: \.0) { f, calls, tokens in
                    LabeledContent(f.label) { Text("\(Usage.short(calls)) call\(calls == 1 ? "" : "s") · \(Usage.short(tokens)) tokens").foregroundColor(.secondary) }
                }
            }
            if s.byModel.count > 1 {
                ForEach(s.byModel, id: \.0) { m, calls, tokens in
                    LabeledContent(m) { Text("\(Usage.short(calls)) call\(calls == 1 ? "" : "s") · \(Usage.short(tokens)) tokens").foregroundColor(.secondary) }
                }
            }
            Toggle("Show today's usage in the menu", isOn: $settings.showUsageInMenu)
            HStack {
                Button("Export CSV…") { Self.export() }
                Spacer()
                Button("Reset Statistics…") { Self.confirmReset() }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Counted on this Mac only and never sent anywhere: time, feature, provider, model and token counts — never your text. Keeps the last 1,000 calls and 90 days of daily totals.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    static func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Nib usage \(Usage.dayKey(Date())).csv"
        p.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        try? Usage.shared.csv().write(to: url, atomically: true, encoding: .utf8)
    }

    static func confirmReset() {
        let a = NSAlert()
        a.messageText = "Reset usage statistics?"
        a.informativeText = "This deletes all recorded calls and daily totals on this Mac."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { Usage.shared.reset() }
    }
}
