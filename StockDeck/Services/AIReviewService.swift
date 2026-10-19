import Foundation

/// Errors surfaced by the AI Review service.
enum AIReviewError: LocalizedError {
    case noConfiguration
    case invalidURL
    case badStatus(Int, String)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noConfiguration:
            return "Set an API key in Settings → AI Review first."
        case .invalidURL:
            return "The provider base URL is invalid."
        case .badStatus(let code, let body):
            let snippet = String(body.prefix(300))
            return "Provider returned HTTP \(code)\(snippet.isEmpty ? "" : ": \(snippet)")"
        case .decoding(let msg):
            return "Could not parse the provider response: \(msg)"
        case .network(let msg):
            return "Network error: \(msg)"
        }
    }
}

/// Thin OpenAI-compatible chat-completions client. The base URL, model and API
/// key are user-configurable so the same code works with OpenAI, DeepSeek, Groq,
/// OpenRouter, etc. Non-streaming: a single request returns the whole reply.
@MainActor
final class AIReviewService {
    static let shared = AIReviewService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        session = URLSession(configuration: config)
    }

    struct Request {
        let baseURL: String
        let apiKey: String
        let model: String
        let systemContext: String
        let messages: [AIChatSection.APIMessage]
        /// DeepSeek V4 thinking mode toggle (nil = leave to provider default).
        let thinking: Bool?
        let maxTokens: Int?
        /// Enable Google Search Grounding for real-time web search (Gemini).
        let enableSearchGrounding: Bool?
        let provider: String?

        init(
            baseURL: String,
            apiKey: String,
            model: String,
            systemContext: String,
            messages: [AIChatSection.APIMessage],
            thinking: Bool? = nil,
            maxTokens: Int? = nil,
            enableSearchGrounding: Bool? = nil,
            provider: String? = nil
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.systemContext = systemContext
            self.messages = messages
            self.thinking = thinking
            self.maxTokens = maxTokens
            self.enableSearchGrounding = enableSearchGrounding
            self.provider = provider
        }
    }

    /// Sends the conversation + context to the provider and returns the assistant reply.
    func send(request: Request) async throws -> String {
        if let provider = request.provider {
            switch provider {
            case "claude_oauth":
                return try await sendClaudeOAuth(request: request)
            case "codex_oauth":
                return try await sendCodexOAuth(request: request)
            case "gemini_oauth":
                return try await sendGeminiOAuth(request: request)
            default:
                break
            }
        }

        let cleanApiKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBaseURL = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanApiKey.isEmpty, !cleanBaseURL.isEmpty else {
            throw AIReviewError.noConfiguration
        }

        // Use Gemini native endpoint when Google Search grounding is enabled
        if cleanBaseURL.contains("googleapis.com") && request.enableSearchGrounding == true {
            do {
                return try await sendGeminiNative(request: request, cleanApiKey: cleanApiKey)
            } catch {
                NSLog("[AIReview] Gemini native search grounding failed (\(error.localizedDescription)), falling back to standard completions")
            }
        }

        let baseString = cleanBaseURL.hasSuffix("/") ? cleanBaseURL : cleanBaseURL + "/"
        guard let url = URL(string: baseString)?.appendingPathComponent("chat/completions") else {
            throw AIReviewError.invalidURL
        }

        var payload = [String: Any]()
        payload["model"] = request.model
        payload["messages"] = Self.buildMessages(systemContext: request.systemContext, messages: request.messages)
        payload["temperature"] = 0.4
        payload["max_tokens"] = request.maxTokens ?? 4096
        if let thinking = request.thinking, cleanBaseURL.contains("deepseek") {
            payload["thinking"] = ["type": thinking ? "enabled" : "disabled"]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cleanApiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AIReviewError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIReviewError.network("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            NSLog("[AIReview] HTTP \(http.statusCode) body: \(String(body.prefix(500)))")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let errMsg = errObj["message"] as? String {
                throw AIReviewError.badStatus(http.statusCode, errMsg)
            } else if let jsonArr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let first = jsonArr.first,
                      let errObj = first["error"] as? [String: Any],
                      let errMsg = errObj["message"] as? String {
                throw AIReviewError.badStatus(http.statusCode, errMsg)
            }
            throw AIReviewError.badStatus(http.statusCode, body)
        }

        let bodyText = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
        do {
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let message = decoded.choices.first?.message else {
                NSLog("[AIReview] No choices in response. Body: \(String(bodyText.prefix(500)))")
                throw AIReviewError.decoding("empty choices. Body: \(String(bodyText.prefix(300)))")
            }
            // Never surface `reasoning_content` as the answer — a thinking model's
            // scratchpad is not user-facing. If the provider left `content` empty
            // (e.g. it burned the token budget reasoning), report it clearly.
            if let content = message.content, !content.isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let reasoning = message.reasoningContent, !reasoning.isEmpty,
               let firstBrace = reasoning.firstIndex(of: "{"),
               let lastBrace = reasoning.lastIndex(of: "}"), firstBrace <= lastBrace {
                let jsonSub = String(reasoning[firstBrace...lastBrace])
                return jsonSub.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            NSLog("[AIReview] Empty message content. finish_reason=\(decoded.choices.first?.finishReason ?? "?"). Body: \(String(bodyText.prefix(500)))")
            throw AIReviewError.decoding("empty content (finish_reason=\(decoded.choices.first?.finishReason ?? "?")). Body: \(String(bodyText.prefix(300)))")
        } catch let err as AIReviewError {
            throw err
        } catch {
            NSLog("[AIReview] Decode failed. Body: \(String(bodyText.prefix(500)))")
            throw AIReviewError.decoding("\(error.localizedDescription). Body: \(String(bodyText.prefix(300)))")
        }
    }

    /// Fetches the available models from the provider's /models endpoint (OpenAI-compatible)
    /// or Google Gemini models API.
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let cleanApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanApiKey.isEmpty, !cleanBaseURL.isEmpty else {
            throw AIReviewError.noConfiguration
        }

        let isGemini = cleanBaseURL.contains("googleapis.com")
        let url: URL
        if isGemini {
            guard let u = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(cleanApiKey)") else {
                throw AIReviewError.invalidURL
            }
            url = u
        } else {
            let baseString = cleanBaseURL.hasSuffix("/") ? cleanBaseURL : cleanBaseURL + "/"
            guard let u = URL(string: baseString)?.appendingPathComponent("models") else {
                throw AIReviewError.invalidURL
            }
            url = u
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if isGemini {
            req.setValue(cleanApiKey, forHTTPHeaderField: "x-goog-api-key")
        } else {
            req.setValue("Bearer \(cleanApiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AIReviewError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIReviewError.network("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            NSLog("[AIReview] fetchModels HTTP \(http.statusCode) body: \(String(body.prefix(500)))")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let errMsg = errObj["message"] as? String {
                throw AIReviewError.badStatus(http.statusCode, errMsg)
            }
            throw AIReviewError.badStatus(http.statusCode, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIReviewError.decoding("Invalid JSON in /models response")
        }

        var rawList: [String] = []
        if let dataArr = json["data"] as? [[String: Any]] {
            for item in dataArr {
                if let id = item["id"] as? String {
                    rawList.append(id)
                }
            }
        } else if let modelsArr = json["models"] as? [[String: Any]] {
            for item in modelsArr {
                if let methods = item["supportedGenerationMethods"] as? [String],
                   !methods.contains("generateContent") {
                    continue
                }
                if let id = item["name"] as? String ?? item["id"] as? String {
                    rawList.append(id)
                }
            }
        }

        var cleaned: [String] = []
        for raw in rawList {
            var item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("models/") {
                item = String(item.dropFirst(7))
            }
            let lower = item.lowercased()
            if cleanBaseURL.contains("googleapis.com") {
                if lower.contains("embedding") || lower.contains("aqa") || lower.contains("imagen") || lower.contains("tts") || lower.contains("whisper") || lower.contains("babbage") || lower.contains("davinci") {
                    continue
                }
            } else if cleanBaseURL.contains("openai.com") {
                if lower.contains("embedding") || lower.contains("tts") || lower.contains("dall-e") || lower.contains("whisper") || lower.contains("moderation") || lower.contains("babbage") || lower.contains("davinci") {
                    continue
                }
            }
            if !item.isEmpty && !cleaned.contains(item) {
                cleaned.append(item)
            }
        }

        // Sort intelligently based on provider
        return cleaned.sorted { a, b in
            if cleanBaseURL.contains("googleapis.com") {
                func geminiScore(_ s: String) -> Int {
                    if s == "gemini-3.8-flash" { return 0 }
                    if s == "gemini-3.1-pro" { return 1 }
                    if s == "gemini-3.5-flash-lite" { return 2 }
                    if s == "gemini-3-flash" { return 3 }
                    if s.hasPrefix("gemini-3") { return 4 }
                    if s == "gemini-2.5-pro" { return 5 }
                    if s == "gemini-2.5-flash" { return 6 }
                    if s == "gemini-2.0-flash" { return 7 }
                    if s == "gemini-1.5-pro" { return 8 }
                    if s == "gemini-1.5-flash" { return 9 }
                    if s.hasPrefix("gemini-2.5") { return 10 }
                    if s.hasPrefix("gemini-2.0") { return 11 }
                    if s.hasPrefix("gemini-1.5") { return 12 }
                    return 13
                }
                let scoreA = geminiScore(a)
                let scoreB = geminiScore(b)
                if scoreA != scoreB {
                    return scoreA < scoreB
                }
            } else if cleanBaseURL.contains("openai.com") {
                func openaiScore(_ s: String) -> Int {
                    if s == "gpt-4o-mini" { return 0 }
                    if s == "gpt-4o" { return 1 }
                    if s == "gpt-4.5-preview" { return 2 }
                    if s.hasPrefix("o3") { return 3 }
                    if s.hasPrefix("o1") { return 4 }
                    if s.hasPrefix("gpt-4") { return 5 }
                    return 6
                }
                let scoreA = openaiScore(a)
                let scoreB = openaiScore(b)
                if scoreA != scoreB {
                    return scoreA < scoreB
                }
            }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Fetches models dynamically for OAuth providers from their servers.
    func fetchOAuthModels(provider: String) async throws -> [String] {
        switch provider {
        case "gemini_oauth":
            let token = try await AIOAuthService.shared.getValidAccessToken(for: "gemini_oauth")
            let hosts = [
                "https://daily-cloudcode-pa.googleapis.com",
                "https://cloudcode-pa.googleapis.com"
            ]
            for host in hosts {
                guard let url = URL(string: "\(host)/v1internal:fetchAvailableModels") else { continue }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                applyAntigravityHeaders(to: &req, accessToken: token)
                req.httpBody = Data("{}".utf8)

                if let (data, response) = try? await session.data(for: req),
                   let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let modelsDict = json["models"] as? [String: [String: Any]] {
                    var list: [String] = ["gemini-4-argon"]
                    for key in modelsDict.keys {
                        let lower = key.lowercased()
                        guard lower.hasPrefix("gemini-") else { continue }
                        if lower.contains("image") || lower.contains("tiered") || lower.contains("embedding") {
                            continue
                        }
                        if !list.contains(key) {
                            list.append(key)
                        }
                    }
                    if list.count > 1 {
                        return sortGeminiModels(list)
                    }
                }
            }
            return StorageService.providerPresetModels["gemini_oauth"] ?? []

        case "codex_oauth":
            let token = try await AIOAuthService.shared.getValidAccessToken(for: "codex_oauth")
            if let url = URL(string: "https://api.openai.com/v1/models") {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                if let (data, response) = try? await session.data(for: req),
                   let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArr = json["data"] as? [[String: Any]] {
                    var list: [String] = []
                    for item in dataArr {
                        if let id = item["id"] as? String {
                            let lower = id.lowercased()
                            if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("chatgpt") {
                                if !list.contains(id) { list.append(id) }
                            }
                        }
                    }
                    if !list.isEmpty {
                        return list.sorted()
                    }
                }
            }
            return StorageService.providerPresetModels["codex_oauth"] ?? []

        case "claude_oauth":
            return StorageService.providerPresetModels["claude_oauth"] ?? []

        default:
            return StorageService.providerPresetModels[provider] ?? []
        }
    }

    private func sortGeminiModels(_ models: [String]) -> [String] {
        func geminiScore(_ s: String) -> Int {
            if s == "gemini-4-argon" { return 0 }
            if s.hasPrefix("gemini-4") { return 1 }
            if s == "gemini-3.8-flash-high" { return 2 }
            if s == "gemini-3.8-flash-medium" { return 3 }
            if s == "gemini-3.8-flash-low" { return 4 }
            if s.hasPrefix("gemini-3.8") { return 5 }
            if s.hasPrefix("gemini-3.7") { return 6 }
            if s.hasPrefix("gemini-3.6") { return 7 }
            if s == "gemini-3.5-flash-lite" { return 8 }
            if s.hasPrefix("gemini-3.5") { return 9 }
            if s == "gemini-3.1-pro-high" || s == "gemini-3.1-pro" { return 10 }
            if s.hasPrefix("gemini-3.1") { return 11 }
            if s == "gemini-3-flash-agent" { return 12 }
            if s == "gemini-3-flash" { return 13 }
            if s.hasPrefix("gemini-3") { return 14 }
            if s == "gemini-2.5-pro" { return 15 }
            if s == "gemini-2.5-flash" { return 16 }
            if s.hasPrefix("gemini-2.5") { return 17 }
            if s == "gemini-2.0-flash" { return 18 }
            return 19
        }
        return models.sorted { a, b in
            let scoreA = geminiScore(a)
            let scoreB = geminiScore(b)
            if scoreA != scoreB { return scoreA < scoreB }
            return a < b
        }
    }

    private static func buildMessages(systemContext: String, messages: [AIChatSection.APIMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        out.append(["role": "system", "content": systemContext])
        for m in messages {
            if let img = m.imageBase64, !img.isEmpty {
                var parts: [[String: Any]] = []
                if !m.content.isEmpty {
                    parts.append(["type": "text", "text": m.content])
                }
                let formattedURL = img.hasPrefix("data:") ? img : "data:image/jpeg;base64,\(img)"
                parts.append(["type": "image_url", "image_url": ["url": formattedURL]])
                out.append(["role": m.role, "content": parts])
            } else {
                out.append(["role": m.role, "content": m.content])
            }
        }
        return out
    }

    // MARK: - Gemini Native API with Google Search Grounding

    private func sendGeminiNative(request: Request, cleanApiKey: String) async throws -> String {
        let rawModel = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = rawModel.isEmpty ? "gemini-2.0-flash" : rawModel
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(cleanApiKey)") else {
            throw AIReviewError.invalidURL
        }

        var payload: [String: Any] = [:]
        if !request.systemContext.isEmpty {
            payload["systemInstruction"] = [
                "parts": [["text": request.systemContext]]
            ]
        }

        var contents: [[String: Any]] = []
        for m in request.messages {
            let role = m.role == "assistant" ? "model" : "user"
            var parts: [[String: Any]] = []
            if !m.content.isEmpty {
                parts.append(["text": m.content])
            }
            if let img = m.imageBase64, !img.isEmpty {
                let cleanBase64 = img.contains(",") ? String(img.components(separatedBy: ",").last ?? img) : img
                parts.append([
                    "inlineData": [
                        "mimeType": "image/jpeg",
                        "data": cleanBase64
                    ]
                ])
            }
            if !parts.isEmpty {
                contents.append([
                    "role": role,
                    "parts": parts
                ])
            }
        }
        if contents.isEmpty {
            contents.append([
                "role": "user",
                "parts": [["text": "Phân tích"]]
            ])
        }
        payload["contents"] = contents

        if request.enableSearchGrounding == true {
            payload["tools"] = [
                ["googleSearch": [String: Any]()]
            ]
        }

        let genConfig: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": request.maxTokens ?? 4096
        ]
        payload["generationConfig"] = genConfig

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AIReviewError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIReviewError.network("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let errMsg = errObj["message"] as? String {
                throw AIReviewError.badStatus(http.statusCode, errMsg)
            }
            throw AIReviewError.badStatus(http.statusCode, body)
        }

        struct GeminiNativeResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                    }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }

        do {
            let decoded = try JSONDecoder().decode(GeminiNativeResponse.self, from: data)
            if let parts = decoded.candidates?.first?.content?.parts {
                let fullText = parts.compactMap(\.text).joined()
                if !fullText.isEmpty {
                    return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            throw AIReviewError.decoding("Empty candidate content from Gemini")
        } catch let err as AIReviewError {
            throw err
        } catch {
            throw AIReviewError.decoding(error.localizedDescription)
        }
    }

    // MARK: - OAuth Senders

    private func sendClaudeOAuth(request: Request) async throws -> String {
        let accessToken = try await AIOAuthService.shared.getValidAccessToken(for: "claude_oauth")
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIReviewError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var anthropicMessages: [[String: Any]] = []
        for m in request.messages {
            let role = m.role == "assistant" ? "assistant" : "user"
            if let img = m.imageBase64, !img.isEmpty {
                let cleanBase64 = img.contains(",") ? String(img.components(separatedBy: ",").last ?? img) : img
                anthropicMessages.append([
                    "role": role,
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": cleanBase64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": m.content
                        ]
                    ]
                ])
            } else {
                anthropicMessages.append([
                    "role": role,
                    "content": m.content
                ])
            }
        }
        if anthropicMessages.isEmpty {
            anthropicMessages.append(["role": "user", "content": "Analyze portfolio."])
        }

        var payload: [String: Any] = [
            "model": request.model.isEmpty ? "claude-3-7-sonnet-20250219" : request.model,
            "max_tokens": request.maxTokens ?? 4096,
            "messages": anthropicMessages
        ]
        if !request.systemContext.isEmpty {
            payload["system"] = request.systemContext
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AIReviewError.network("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIReviewError.badStatus(http.statusCode, body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArr = json["content"] as? [[String: Any]] else {
            throw AIReviewError.decoding("Invalid Claude response structure")
        }
        let reply = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendCodexOAuth(request: Request) async throws -> String {
        let accessToken = try await AIOAuthService.shared.getValidAccessToken(for: "codex_oauth")
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIReviewError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload = [String: Any]()
        payload["model"] = request.model.isEmpty ? "gpt-4o" : request.model
        payload["messages"] = Self.buildMessages(systemContext: request.systemContext, messages: request.messages)
        payload["temperature"] = 0.4
        payload["max_tokens"] = request.maxTokens ?? 4096

        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AIReviewError.network("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIReviewError.badStatus(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let reply = decoded.choices.first?.message.content else {
            throw AIReviewError.decoding("Empty response choices")
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cachedCloudCodeProject: String?

    private func applyAntigravityHeaders(to req: inout URLRequest, accessToken: String) {
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("antigravity/2.24.0 darwin/arm64", forHTTPHeaderField: "User-Agent")
        req.setValue("google-cloud-sdk vscode_cloudshelleditor/0.1", forHTTPHeaderField: "X-Goog-Api-Client")
        req.setValue("{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}", forHTTPHeaderField: "Client-Metadata")
    }

    private func resolveGeminiCloudCodeProject(accessToken: String) async -> String {
        if let cached = cachedCloudCodeProject, !cached.isEmpty {
            return cached
        }
        let hosts = [
            "https://cloudcode-pa.googleapis.com"
        ]
        let bodyDict: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            ]
        ]
        let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict)

        for host in hosts {
            guard let url = URL(string: "\(host)/v1internal:loadCodeAssist") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            applyAntigravityHeaders(to: &req, accessToken: accessToken)
            req.httpBody = bodyData

            if let (data, response) = try? await session.data(for: req),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let proj = json["cloudaicompanionProject"] as? String, !proj.isEmpty {
                cachedCloudCodeProject = proj
                return proj
            }
        }
        return "aicode-consumers"
    }

    private func extractGeminiCandidateText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let respObj = (json["response"] as? [String: Any]) ?? json
        guard let candidates = respObj["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        let nonThoughtTexts = parts.compactMap { part -> String? in
            if (part["thought"] as? Bool) == true { return nil }
            if part["thoughtSignature"] != nil && part["text"] == nil { return nil }
            guard let t = part["text"] as? String, !t.isEmpty else { return nil }
            return t
        }
        let joined = nonThoughtTexts.isEmpty
            ? parts.compactMap({ $0["text"] as? String }).joined()
            : nonThoughtTexts.joined()
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sendGeminiOAuth(request: Request) async throws -> String {
        let accessToken = try await AIOAuthService.shared.getValidAccessToken(for: "gemini_oauth")
        let projectId = await resolveGeminiCloudCodeProject(accessToken: accessToken)

        var contents: [[String: Any]] = []
        if !request.systemContext.isEmpty {
            contents.append([
                "role": "user",
                "parts": [["text": "System context:\n" + request.systemContext]]
            ])
            contents.append([
                "role": "model",
                "parts": [["text": "Understood. I will analyze your portfolio based on these instructions."]]
            ])
        }
        for m in request.messages {
            contents.append([
                "role": m.role == "assistant" ? "model" : "user",
                "parts": [["text": m.content]]
            ])
        }
        if contents.isEmpty {
            contents.append(["role": "user", "parts": [["text": "Analyze portfolio."]]])
        }

        let primaryModel = request.model.isEmpty ? "gemini-3.8-flash-high" : request.model
        var candidateModels: [String] = [primaryModel]
        for fallback in ["gemini-3.8-flash-high", "gemini-3-flash", "gemini-2.5-flash"] {
            if !candidateModels.contains(fallback) {
                candidateModels.append(fallback)
            }
        }

        let hosts = [
            "https://cloudcode-pa.googleapis.com"
        ]

        var lastStatus: Int = 500
        var lastErrorBody: String = "Unknown error"

        for host in hosts {
            guard let url = URL(string: "\(host)/v1internal:generateContent") else { continue }
            for modelId in candidateModels {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                applyAntigravityHeaders(to: &req, accessToken: accessToken)

                let payload: [String: Any] = [
                    "project": projectId,
                    "model": modelId,
                    "request": [
                        "contents": contents,
                        "generationConfig": [
                            "temperature": 0.4,
                            "maxOutputTokens": max(request.maxTokens ?? 4096, 512)
                        ]
                    ]
                ]
                req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

                if let (data, response) = try? await session.data(for: req),
                   let http = response as? HTTPURLResponse {
                    if http.statusCode == 200, let reply = extractGeminiCandidateText(from: data) {
                        return reply
                    }
                    lastStatus = http.statusCode
                    lastErrorBody = String(data: data, encoding: .utf8) ?? ""
                }
            }
        }

        throw AIReviewError.badStatus(lastStatus, lastErrorBody)
    }

    // MARK: - DTOs

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let reasoningContent: String?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                }
            }
            let message: Message
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }
}
