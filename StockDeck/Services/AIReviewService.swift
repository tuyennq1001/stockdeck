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

        init(
            baseURL: String,
            apiKey: String,
            model: String,
            systemContext: String,
            messages: [AIChatSection.APIMessage],
            thinking: Bool? = nil,
            maxTokens: Int? = nil,
            enableSearchGrounding: Bool? = nil
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.systemContext = systemContext
            self.messages = messages
            self.thinking = thinking
            self.maxTokens = maxTokens
            self.enableSearchGrounding = enableSearchGrounding
        }
    }

    /// Sends the conversation + context to the provider and returns the assistant reply.
    func send(request: Request) async throws -> String {
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
                    if s == "gemini-2.0-flash" { return 0 }
                    if s == "gemini-2.5-flash" { return 1 }
                    if s == "gemini-2.5-pro" { return 2 }
                    if s == "gemini-1.5-flash" { return 3 }
                    if s == "gemini-1.5-pro" { return 4 }
                    if s.hasPrefix("gemini-2.0") { return 5 }
                    if s.hasPrefix("gemini-2.5") { return 6 }
                    if s.hasPrefix("gemini-1.5") { return 7 }
                    return 8
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
