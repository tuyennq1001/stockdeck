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
    }

    /// Sends the conversation + context to the provider and returns the assistant reply.
    func send(request: Request) async throws -> String {
        guard !request.apiKey.isEmpty, !request.baseURL.isEmpty else {
            throw AIReviewError.noConfiguration
        }
        guard let url = URL(string: request.baseURL.hasSuffix("/") ? request.baseURL : request.baseURL + "/")?
            .appendingPathComponent("chat/completions") else {
            throw AIReviewError.invalidURL
        }

        var payload = [String: Any]()
        payload["model"] = request.model
        payload["messages"] = Self.buildMessages(systemContext: request.systemContext, messages: request.messages)
        payload["temperature"] = 0.4
        payload["max_tokens"] = 1600
        if let thinking = request.thinking {
            payload["thinking"] = ["type": thinking ? "enabled" : "disabled"]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
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
            NSLog("[AIReview] Empty message content. finish_reason=\(decoded.choices.first?.finishReason ?? "?"). Body: \(String(bodyText.prefix(500)))")
            throw AIReviewError.decoding("empty content (finish_reason=\(decoded.choices.first?.finishReason ?? "?")). Body: \(String(bodyText.prefix(300)))")
        } catch let err as AIReviewError {
            throw err
        } catch {
            NSLog("[AIReview] Decode failed. Body: \(String(bodyText.prefix(500)))")
            throw AIReviewError.decoding("\(error.localizedDescription). Body: \(String(bodyText.prefix(300)))")
        }
    }

    private static func buildMessages(systemContext: String, messages: [AIChatSection.APIMessage]) -> [[String: String]] {
        var out: [[String: String]] = []
        out.append(["role": "system", "content": systemContext])
        for m in messages {
            out.append(["role": m.role, "content": m.content])
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
