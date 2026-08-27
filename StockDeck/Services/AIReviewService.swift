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

        init(baseURL: String, apiKey: String, model: String, systemContext: String, messages: [AIChatSection.APIMessage], thinking: Bool? = nil, maxTokens: Int? = nil) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.systemContext = systemContext
            self.messages = messages
            self.thinking = thinking
            self.maxTokens = maxTokens
        }
    }

    /// Sends the conversation + context to the provider and returns the assistant reply.
    func send(request: Request) async throws -> String {
        let cleanApiKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBaseURL = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanApiKey.isEmpty, !cleanBaseURL.isEmpty else {
            throw AIReviewError.noConfiguration
        }
        let baseString = cleanBaseURL.hasSuffix("/") ? cleanBaseURL : cleanBaseURL + "/"
        guard var url = URL(string: baseString)?.appendingPathComponent("chat/completions") else {
            throw AIReviewError.invalidURL
        }

        // Google Gemini API Gateway expects x-goog-api-key or ?key=
        if cleanBaseURL.contains("googleapis.com"), var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "key", value: cleanApiKey))
            components.queryItems = items
            if let u = components.url {
                url = u
            }
        }

        var payload = [String: Any]()
        payload["model"] = request.model
        payload["messages"] = Self.buildMessages(systemContext: request.systemContext, messages: request.messages)
        payload["temperature"] = 0.4
        payload["max_tokens"] = request.maxTokens ?? 4096
        if let thinking = request.thinking {
            payload["thinking"] = ["type": thinking ? "enabled" : "disabled"]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cleanApiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(cleanApiKey, forHTTPHeaderField: "x-goog-api-key")
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

    /// Fetches the available models from the provider's /models endpoint (OpenAI-compatible).
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let cleanApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanApiKey.isEmpty, !cleanBaseURL.isEmpty else {
            throw AIReviewError.noConfiguration
        }
        let baseString = cleanBaseURL.hasSuffix("/") ? cleanBaseURL : cleanBaseURL + "/"
        guard var url = URL(string: baseString)?.appendingPathComponent("models") else {
            throw AIReviewError.invalidURL
        }

        // Google Gemini API Gateway expects x-goog-api-key or ?key=
        if cleanBaseURL.contains("googleapis.com"), var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "key", value: cleanApiKey))
            components.queryItems = items
            if let u = components.url {
                url = u
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(cleanApiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(cleanApiKey, forHTTPHeaderField: "x-goog-api-key")
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
                if let id = item["id"] as? String ?? item["name"] as? String {
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
            if cleanBaseURL.contains("googleapis.com") {
                let lower = item.lowercased()
                if lower.contains("embedding") || lower.contains("aqa") || lower.contains("imagen") || lower.contains("tts") || lower.contains("whisper") {
                    continue
                }
            }
            if !item.isEmpty && !cleaned.contains(item) {
                cleaned.append(item)
            }
        }

        // Sort intelligently: prioritize Gemini chat models
        return cleaned.sorted { a, b in
            if cleanBaseURL.contains("googleapis.com") {
                let scoreA = a.hasPrefix("gemini-2.5") ? 0 : (a.hasPrefix("gemini-2.0") ? 1 : (a.hasPrefix("gemini-1.5") ? 2 : 3))
                let scoreB = b.hasPrefix("gemini-2.5") ? 0 : (b.hasPrefix("gemini-2.0") ? 1 : (b.hasPrefix("gemini-1.5") ? 2 : 3))
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
