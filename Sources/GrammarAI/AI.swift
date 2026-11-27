import Foundation

// MARK: - Providers

/// One active provider + model is used for everything (live checking, ⌥⌥, rewrite).
enum Provider: String, CaseIterable, Identifiable {
    case gemini, claude, openai, deepseek, qwen, vertex, custom
    var id: String { rawValue }

    enum Proto { case gemini, anthropic, openai }

    var name: String {
        switch self {
        case .gemini: return "Gemini (AI Studio)"
        case .claude: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen (DashScope)"
        case .vertex: return "Gemini via Vertex AI"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var shortName: String {
        switch self {
        case .gemini, .vertex: return "Gemini"
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen"
        case .custom: return "the server"
        }
    }

    var proto: Proto {
        switch self {
        case .gemini, .vertex: return .gemini
        case .claude: return .anthropic
        case .openai, .deepseek, .qwen, .custom: return .openai
        }
    }

    /// Keychain account for the key (Vertex uses gcloud credentials instead).
    var keyAccount: String? {
        switch self {
        case .gemini: return Keychain.defaultAccount // "gemini-api-key", as before v2
        case .vertex: return nil
        default: return "\(rawValue)-api-key"
        }
    }

    /// Environment variable checked when no key is saved.
    var envKey: String? {
        switch self {
        case .gemini: return "GEMINI_API_KEY"
        case .claude: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .deepseek: return "DEEPSEEK_API_KEY"
        case .qwen: return "DASHSCOPE_API_KEY"
        case .vertex, .custom: return nil
        }
    }

    var keyRequired: Bool { self != .vertex && self != .custom }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-3.5-flash-lite"
        case .vertex: return "gemini-2.5-flash-lite"
        case .claude: return "claude-haiku-5-5"
        case .openai: return "gpt-5-mini"
        case .deepseek: return "deepseek-chat"
        case .qwen: return "qwen-flash"
        case .custom: return ""
        }
    }

    /// Shown when the provider has no model list (or it can't be loaded).
    var fallbackModels: [String] {
        switch self {
        case .gemini: return ["gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-flash"]
        case .vertex: return ["gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .claude: return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        case .openai: return ["gpt-5-mini", "gpt-5-nano", "gpt-5", "gpt-4.1-mini"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .qwen: return ["qwen-flash", "qwen-plus", "qwen-turbo", "qwen-max"]
        case .custom: return []
        }
    }

    var keyHelpURL: URL? {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .qwen: return URL(string: "https://bailian.console.alibabacloud.com/?apiKey=1")
        case .vertex, .custom: return nil
        }
    }

    /// Base URL for the OpenAI-compatible providers and Anthropic.
    func baseURL(_ s: Settings) -> String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .qwen: return s.qwenRegion == "cn" ? "https://dashscope.aliyuncs.com/compatible-mode/v1"
                                                : "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .custom:
            var b = s.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while b.hasSuffix("/") { b.removeLast() }
            return b
        case .claude: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .vertex:
            let r = s.vertexRegion.isEmpty ? "global" : s.vertexRegion
            let host = r == "global" ? "aiplatform.googleapis.com" : "\(r)-aiplatform.googleapis.com"
            return "https://\(host)/v1/projects/\(s.vertexProject)/locations/\(r)/publishers/google"
        }
    }
}

// MARK: - Errors (plain English)

/// Errors from any provider, normalised into the messages Nib shows.
enum AIError: LocalizedError {
    case noKey, http(Int, String), empty, network(String), incomplete(String)
    case notSetUp(String), credentials(String)

    var errorDescription: String? { describe(Settings.shared.provider) }

    /// The message for a given provider (errors from a provider being tested name that provider).
    func describe(_ p: Provider) -> String {
        let provider = p.shortName
        switch self {
        case .noKey: return "No API key for \(Settings.shared.provider.name). Open Settings… to add one."
        case .notSetUp(let what): return what
        case .credentials(let why): return why
        case .http(let code, let msg):
            let m = msg.lowercased()
            if code == 401 || m.contains("api key not valid") || m.contains("invalid api key") || m.contains("incorrect api key")
                || m.contains("invalid x-api-key") || m.contains("authentication") || m.contains("api_key_invalid") || m.contains("unauthorized") {
                return "The API key isn't valid. Check it in Settings."
            }
            if code == 402 || m.contains("insufficient") || m.contains("credit") || m.contains("balance") || m.contains("arrearage")
                || m.contains("billing") || m.contains("exceeded your current quota") || m.contains("prepayment") {
                return "No credit or quota left on this \(provider) account. Top it up, or pick another provider in Settings."
            }
            if code == 404 || m.contains("model not found") || m.contains("does not exist") || m.contains("not_found") || m.contains("model_not_found") {
                return "Model not found. Check the model in Settings."
            }
            if code == 429 { return "\(provider) rate limit reached. Try again in a moment." }
            if code == 403 { return p == .vertex ? "Vertex AI refused (403): \(msg)" : "This key isn't allowed to use \(provider) (403): \(msg)" }
            return "\(provider) error \(code): \(msg)"
        case .empty: return "\(provider) sent back nothing."
        case .incomplete(let r):
            return r == "MAX_TOKENS" || r == "max_tokens" || r == "length" ? "The text is too long for one pass. Select a smaller part."
                                                                         : "\(provider) stopped early (\(r)); nothing was changed."
        case .network(let m): return "Couldn't reach \(provider): \(m)"
        }
    }

    /// Account- or setup-level problems that won't fix themselves by retrying soon.
    var isBlocking: Bool {
        switch self {
        case .noKey, .notSetUp, .credentials: return true
        case .http(let code, _): return [400, 401, 402, 403, 404].contains(code)
        default: return false
        }
    }
}

typealias GeminiError = AIError

/// An AIError from a specific provider, so its message names that provider.
struct ProviderError: LocalizedError {
    let base: AIError
    let provider: Provider
    var errorDescription: String? { base.describe(provider) }
    var isBlocking: Bool { base.isBlocking }
}

extension Error {
    /// Whether this is an account/setup problem that retrying soon won't fix.
    var isBlockingAIError: Bool { (self as? ProviderError)?.isBlocking ?? (self as? AIError)?.isBlocking ?? false }
}

// MARK: - Requests

struct AIRequest {
    var system: String
    var user: String
    var temperature: Double
    /// JSON schema for a structured answer (the issue list); nil = plain text.
    var schema: [String: Any]? = nil
    var seed: Int? = nil
    var maxTokens = 4096
    var timeout: TimeInterval = 30
}

/// Everything needed to talk to one provider (the active one, or one being tested in Settings).
struct AIEndpoint {
    var provider: Provider
    var model: String
    var key: String?
    var settings: Settings = .shared

    static func active() -> AIEndpoint {
        let s = Settings.shared
        return AIEndpoint(provider: s.provider, model: s.effectiveModel, key: s.key(for: s.provider))
    }
}

enum AI {
    // MARK: Entry points

    static func complete(_ r: AIRequest, _ ep: AIEndpoint = .active()) async throws -> String {
        do { return try await completeRaw(r, ep) } catch let e as AIError { throw ProviderError(base: e, provider: ep.provider) }
    }

    private static func completeRaw(_ r: AIRequest, _ ep: AIEndpoint) async throws -> String {
        try check(ep)
        switch ep.provider.proto {
        case .gemini: return try await gemini(r, ep)
        case .anthropic: return try await anthropic(r, ep)
        case .openai: return try await openAI(r, ep)
        }
    }

    /// A tiny request that proves key, model and endpoint work.
    static func test(_ ep: AIEndpoint) async throws {
        _ = try await complete(AIRequest(system: "Reply with the single word OK.", user: "ping", temperature: 0, maxTokens: 64, timeout: 20), ep)
    }

    static func listModels(_ ep: AIEndpoint) async throws -> [String] {
        do { return try await listModelsRaw(ep) } catch let e as AIError { throw ProviderError(base: e, provider: ep.provider) }
    }

    private static func listModelsRaw(_ ep: AIEndpoint) async throws -> [String] {
        try check(ep, needModel: false)
        let p = ep.provider
        switch p.proto {
        case .gemini:
            if p == .vertex {
                // Vertex has no simple per-project list of Gemini models: the publisher list, else the built-in one.
                let s = ep.settings
                let r = s.vertexRegion.isEmpty ? "global" : s.vertexRegion
                let host = r == "global" ? "aiplatform.googleapis.com" : "\(r)-aiplatform.googleapis.com"
                let json = try await send(url: "https://\(host)/v1beta1/publishers/google/models?pageSize=200", method: "GET", body: nil,
                                          headers: try await authHeaders(ep), timeout: 20)
                let names = (json["publisherModels"] as? [[String: Any]] ?? []).compactMap { ($0["name"] as? String)?.components(separatedBy: "/").last }
                let gem = names.filter { $0.hasPrefix("gemini") }.sorted()
                return gem.isEmpty ? p.fallbackModels : gem
            }
            let json = try await send(url: p.baseURL(ep.settings) + "/models?pageSize=200", method: "GET", body: nil,
                                      headers: try await authHeaders(ep), timeout: 20)
            let models = (json["models"] as? [[String: Any]] ?? []).filter {
                ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") ?? true
            }.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
            let textOnly = models.filter { m in
                m.hasPrefix("gemini") && !["tts", "image", "computer-use", "embedding", "live", "audio", "robotics"].contains { m.contains($0) }
            }
            return sortModels(textOnly, fallback: p.fallbackModels)
        case .anthropic:
            let json = try await send(url: p.baseURL(ep.settings) + "/v1/models?limit=100", method: "GET", body: nil,
                                      headers: try await authHeaders(ep), timeout: 20)
            return sortModels((json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }, fallback: p.fallbackModels)
        case .openai:
            let json = try await send(url: p.baseURL(ep.settings) + "/models", method: "GET", body: nil,
                                      headers: try await authHeaders(ep), timeout: 20)
            var ids = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            if p == .openai {
                // Only chat models: drop embeddings, audio, images, moderation…
                ids = ids.filter { id in
                    (id.hasPrefix("gpt-") || id.hasPrefix("o") || id.hasPrefix("chatgpt"))
                        && !["embedding", "audio", "realtime", "tts", "transcribe", "image", "search", "moderation", "dall-e", "whisper"].contains { id.contains($0) }
                }
            }
            return sortModels(ids, fallback: p.fallbackModels)
        }
    }

    private static func sortModels(_ ids: [String], fallback: [String]) -> [String] {
        let unique = Array(Set(ids)).sorted()
        return unique.isEmpty ? fallback : unique
    }

    private static func check(_ ep: AIEndpoint, needModel: Bool = true) throws {
        let p = ep.provider, s = ep.settings
        if p == .vertex && s.vertexProject.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AIError.notSetUp("Enter your Google Cloud project ID for Vertex AI in Settings.")
        }
        if p == .custom && URL(string: p.baseURL(s))?.scheme == nil {
            throw AIError.notSetUp("Enter the base URL of your OpenAI-compatible server in Settings (e.g. http://localhost:11434/v1).")
        }
        if p.keyRequired && (ep.key ?? "").isEmpty { throw AIError.noKey }
        if needModel && ep.model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AIError.notSetUp("Pick a model in Settings (Load models).")
        }
    }

    // MARK: Gemini generateContent (AI Studio + Vertex)

    private static func gemini(_ r: AIRequest, _ ep: AIEndpoint) async throws -> String {
        var gen: [String: Any] = ["temperature": r.temperature, "maxOutputTokens": r.maxTokens]
        if let schema = r.schema {
            gen["responseMimeType"] = "application/json"
            gen["responseSchema"] = schema
        } else {
            gen["responseMimeType"] = "text/plain"
        }
        if let seed = r.seed { gen["seed"] = seed }
        // Lowest thinking: Gemini 3.x already defaults to "minimal" (it can't be off); 2.5 Flash/Flash-Lite: budget 0.
        let m = ep.model.lowercased()
        if m.contains("2.5") && !m.contains("pro") { gen["thinkingConfig"] = ["thinkingBudget": 0] }
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": r.system]]],
            "contents": [["role": "user", "parts": [["text": r.user]]]],
            "generationConfig": gen,
        ]
        let model = ep.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ep.model
        let url = ep.provider.baseURL(ep.settings) + "/models/\(model):generateContent"
        let json = try await sendWithRetry(url: url, body: &body, headers: try await authHeaders(ep), timeout: r.timeout, droppable: [
            ("thinkingConfig", { b in Self.dropGen(&b, "thinkingConfig") }),
            ("seed", { b in Self.dropGen(&b, "seed") }),
            ("responseSchema", { b in Self.dropGen(&b, "responseSchema") }),
        ])
        let candidates = json["candidates"] as? [[String: Any]]
        if let reason = candidates?.first?["finishReason"] as? String, reason != "STOP" { throw AIError.incomplete(reason) }
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let out = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        guard !out.isEmpty else { throw AIError.empty }
        return out
    }

    private static func dropGen(_ b: inout [String: Any], _ key: String) {
        var g = b["generationConfig"] as? [String: Any] ?? [:]
        g.removeValue(forKey: key)
        b["generationConfig"] = g
    }

    // MARK: Anthropic Messages

    private static func anthropic(_ r: AIRequest, _ ep: AIEndpoint) async throws -> String {
        var body: [String: Any] = [
            "model": ep.model,
            "max_tokens": r.maxTokens,
            "system": r.system,
            "messages": [["role": "user", "content": r.user]],
            "temperature": r.temperature,
        ]
        // No "thinking" parameter = thinking off (the lowest effort).
        if let schema = r.schema {
            // Structured answer through a forced tool call: works on every Claude model.
            body["tools"] = [["name": "report", "description": "Report the result as structured data.", "input_schema": schema]]
            body["tool_choice"] = ["type": "tool", "name": "report"]
        }
        let json = try await sendWithRetry(url: ep.provider.baseURL(ep.settings) + "/v1/messages", body: &body,
                                           headers: try await authHeaders(ep), timeout: r.timeout,
                                           droppable: [("temperature", { $0.removeValue(forKey: "temperature") })])
        let content = json["content"] as? [[String: Any]] ?? []
        if r.schema != nil, let input = content.first(where: { $0["type"] as? String == "tool_use" })?["input"],
           let data = try? JSONSerialization.data(withJSONObject: input), let s = String(data: data, encoding: .utf8) {
            return s
        }
        if let stop = json["stop_reason"] as? String, stop == "max_tokens" { throw AIError.incomplete("max_tokens") }
        let out = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !out.isEmpty else { throw AIError.empty }
        return out
    }

    // MARK: OpenAI Chat Completions (OpenAI, DeepSeek, Qwen, Custom)

    private static func openAI(_ r: AIRequest, _ ep: AIEndpoint) async throws -> String {
        var system = r.system
        var body: [String: Any] = [
            "model": ep.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": r.user]],
            "temperature": r.temperature,
        ]
        let m = ep.model.lowercased()
        let reasoningModel = ep.provider == .openai && (m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4"))
        if reasoningModel {
            // Lowest effort these models accept ("minimal"; dropped → "low" if rejected, see below). They only take temperature 1.
            body["reasoning_effort"] = "minimal"
            body.removeValue(forKey: "temperature")
            body["max_completion_tokens"] = r.maxTokens * 2
        } else {
            body["max_tokens"] = r.maxTokens
        }
        if ep.provider == .qwen { body["enable_thinking"] = false } // Qwen3 models: required off without streaming
        if let seed = r.seed { body["seed"] = seed }
        if let schema = r.schema {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "result", "schema": schema, "strict": false]]
        }
        let url = ep.provider.baseURL(ep.settings) + "/chat/completions"
        let headers = try await authHeaders(ep)
        let json = try await sendWithRetry(url: url, body: &body, headers: headers, timeout: r.timeout, droppable: [
            ("reasoning_effort", { b in
                // "minimal" rejected: try "low" once, then leave it out.
                if b["reasoning_effort"] as? String == "minimal" { b["reasoning_effort"] = "low" } else { b.removeValue(forKey: "reasoning_effort") }
            }),
            ("temperature", { $0.removeValue(forKey: "temperature") }),
            ("enable_thinking", { $0.removeValue(forKey: "enable_thinking") }),
            ("seed", { $0.removeValue(forKey: "seed") }),
            ("max_tokens", { b in b.removeValue(forKey: "max_tokens"); b["max_completion_tokens"] = r.maxTokens }),
            ("response_format", { b in
                // json_schema unsupported: JSON mode + the schema in the prompt; then no format at all.
                if (b["response_format"] as? [String: Any])?["type"] as? String == "json_schema", let schema = r.schema {
                    b["response_format"] = ["type": "json_object"]
                    let schemaText = (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    system = r.system + "\n\nReply with JSON only, matching this JSON schema: " + schemaText
                    b["messages"] = [["role": "system", "content": system], ["role": "user", "content": r.user]]
                } else {
                    b.removeValue(forKey: "response_format")
                }
            }),
        ])
        let choice = (json["choices"] as? [[String: Any]])?.first
        if let reason = choice?["finish_reason"] as? String, reason == "length" { throw AIError.incomplete("length") }
        let out = ((choice?["message"] as? [String: Any])?["content"] as? String) ?? ""
        guard !out.isEmpty else { throw AIError.empty }
        return stripFences(out)
    }

    private static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            var lines = t.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            t = lines.joined(separator: "\n")
        }
        return t
    }

    // MARK: Auth

    private static func authHeaders(_ ep: AIEndpoint) async throws -> [String: String] {
        let key = ep.key ?? ""
        switch ep.provider {
        case .gemini: return ["x-goog-api-key": key]
        case .vertex:
            // The project also pays for the call (user credentials need a quota project).
            return ["Authorization": "Bearer \(try await VertexAuth.token())", "x-goog-user-project": ep.settings.vertexProject]
        case .claude: return ["x-api-key": key, "anthropic-version": "2023-06-01"]
        case .openai, .deepseek, .qwen: return ["Authorization": "Bearer \(key)"]
        case .custom: return key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"]
        }
    }

    // MARK: HTTP

    /// Sends, and when the provider rejects (400) a parameter Nib chose (e.g. a reasoning level a model
    /// doesn't accept), adjusts that parameter and tries again. At most one adjustment per parameter.
    private static func sendWithRetry(url: String, body: inout [String: Any], headers: [String: String], timeout: TimeInterval,
                                      droppable: [(String, (inout [String: Any]) -> Void)]) async throws -> [String: Any] {
        var adjusted = Set<String>()
        while true {
            do {
                return try await send(url: url, method: "POST", body: body, headers: headers, timeout: timeout)
            } catch AIError.http(let code, let msg) where code == 400 || code == 422 {
                let m = msg.lowercased()
                guard let (name, fix) = droppable.first(where: { !adjusted.contains($0.0) && m.contains($0.0.lowercased()) })
                        ?? droppable.first(where: { !adjusted.contains($0.0) && $0.0 == "reasoning_effort" && m.contains("reasoning") })
                        ?? droppable.first(where: { !adjusted.contains($0.0) && $0.0 == "thinkingConfig" && m.contains("thinking") })
                else { throw AIError.http(code, msg) }
                // "minimal" → "low" is a second step for reasoning_effort only.
                if name == "reasoning_effort", body["reasoning_effort"] as? String == "minimal" { fix(&body); continue }
                adjusted.insert(name)
                fix(&body)
                log("ai: \(name) not accepted by this model; adjusted and retried")
            }
        }
    }

    static func send(url: String, method: String, body: [String: Any]?, headers: [String: String], timeout: TimeInterval) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw AIError.notSetUp("That base URL isn't valid.") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AIError.network(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else { throw AIError.http(status, errorMessage(json, data)) }
        guard let json else { throw AIError.empty }
        return json
    }

    /// The provider's error message, short and with anything key-like removed.
    static func errorMessage(_ json: [String: Any]?, _ data: Data) -> String {
        var msg: String?
        if let e = json?["error"] as? [String: Any] {
            msg = e["message"] as? String
            if let code = e["code"] as? String, msg == nil { msg = code }
            if let type = e["type"] as? String, let m = msg, !m.lowercased().contains(type.lowercased()) { msg = "\(m) (\(type))" }
        } else if let e = json?["error"] as? String {
            msg = e
        } else if let m = json?["message"] as? String {
            msg = m
            if let c = json?["code"] as? String { msg = "\(m) (\(c))" } // DashScope: {"code":"Arrearage","message":…}
        }
        let raw = msg ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
        return sanitise(raw)
    }

    static func sanitise(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        for pattern in ["AIza[0-9A-Za-z_\\-]{10,}", "sk-[A-Za-z0-9_\\-]{8,}", "sk-ant-[A-Za-z0-9_\\-]{8,}", "ya29\\.[A-Za-z0-9_\\-\\.]{10,}",
                        "(?i)(key|token)=[^&\\s]+", "Bearer [A-Za-z0-9_\\-\\.]{10,}"] {
            t = t.replacingOccurrences(of: pattern, with: "[hidden]", options: .regularExpression)
        }
        return t.count > 200 ? String(t.prefix(200)) + "…" : t
    }
}

// MARK: - Vertex credentials (no login flows: uses what's already on the Mac)

enum VertexAuth {
    private static var cached: (token: String, until: Date)?

    static let gcloudPaths = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
                              "/usr/local/share/google-cloud-sdk/bin/gcloud", "\(NSHomeDirectory())/google-cloud-sdk/bin/gcloud",
                              "/usr/local/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin/gcloud"]

    static func token() async throws -> String {
        if let c = cached, Date() < c.until { return c.token }
        var problems: [String] = []
        // 1. Application Default Credentials (a refresh token from `gcloud auth application-default login`).
        do { if let t = try await adcToken() { cached = (t, Date().addingTimeInterval(45 * 60)); return t } }
        catch { problems.append("Application Default Credentials: \(error.localizedDescription)") }
        // 2. gcloud in the background.
        guard let gcloud = gcloudPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AIError.credentials("Not working: gcloud wasn't found and there are no Application Default Credentials. "
                + "Sign in with gcloud in Terminal first." + (problems.isEmpty ? "" : " (\(problems.joined(separator: "; ")))"))
        }
        let (out, err, status) = run(gcloud, ["auth", "print-access-token", "--quiet"])
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, t.hasPrefix("ya29.") || t.count > 40 else {
            let firstLine = err.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "exit \(status)"
            throw AIError.credentials("Not working: gcloud couldn't give a token: \(AI.sanitise(firstLine))")
        }
        cached = (t, Date().addingTimeInterval(45 * 60))
        return t
    }

    /// Exchanges the ADC refresh token, if the file exists and is a user credential.
    private static func adcToken() async throws -> String? {
        let path = NSHomeDirectory() + "/.config/gcloud/application_default_credentials.json"
        guard let data = FileManager.default.contents(atPath: path),
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["type"] as? String == "authorized_user",
              let id = j["client_id"] as? String, let secret = j["client_secret"] as? String, let refresh = j["refresh_token"] as? String
        else { return nil }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        req.httpBody = "grant_type=refresh_token&client_id=\(enc(id))&client_secret=\(enc(secret))&refresh_token=\(enc(refresh))".data(using: .utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200,
              let tok = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["access_token"] as? String
        else { throw AIError.credentials("the saved credentials were refused; sign in again with gcloud") }
        return tok
    }

    private static func run(_ exe: String, _ args: [String]) -> (String, String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ("", error.localizedDescription, -1) }
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return ("", "gcloud took too long", -1) }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (o, e, p.terminationStatus)
    }
}
