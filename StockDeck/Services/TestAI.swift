import Foundation

/// A lightweight connectivity probe for the configured AI provider: sends the
/// tiniest possible chat-completions request and reports detailed status.
/// Used by the "Test connection" button in settings.
@MainActor
enum TestAI {
    struct TestResult {
        let success: Bool
        let message: String
        let latencyMs: Int
        let model: String
    }

    /// Performs a probe chat completion request to diagnose connectivity.
    static func testConnection(storageService: StorageService, apiKeyOverride: String? = nil) async -> TestResult {
        let key = apiKeyOverride ?? storageService.aiApiKey
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            return TestResult(
                success: false,
                message: "Chưa cấu hình API Key. Vui lòng nhập API Key.",
                latencyMs: 0,
                model: storageService.aiModel
            )
        }
        let cleanBaseURL = storageService.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBaseURL.isEmpty else {
            return TestResult(
                success: false,
                message: "Chưa cấu hình Base URL.",
                latencyMs: 0,
                model: storageService.aiModel
            )
        }

        let service = AIReviewService.shared
        let request = AIReviewService.Request(
            baseURL: storageService.aiBaseURL,
            apiKey: cleanKey,
            model: storageService.aiModel,
            systemContext: "You are a test probe. Reply with exactly: ok",
            messages: [AIChatSection.APIMessage(role: "user", content: "ping")],
            thinking: storageService.aiProvider == "deepseek" ? storageService.aiDeepseekThinking : nil
        )

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let reply = try await service.send(request: request)
            let latency = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            if !reply.isEmpty {
                return TestResult(
                    success: true,
                    message: "✓ Đã kết nối thành công tới \(storageService.aiModel) (\(latency)ms)",
                    latencyMs: latency,
                    model: storageService.aiModel
                )
            } else {
                return TestResult(
                    success: false,
                    message: "✗ Phản hồi rỗng từ máy chủ AI.",
                    latencyMs: latency,
                    model: storageService.aiModel
                )
            }
        } catch {
            let latency = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            return TestResult(
                success: false,
                message: "✗ \(error.localizedDescription)",
                latencyMs: latency,
                model: storageService.aiModel
            )
        }
    }

    /// Returns true if the configured provider responds successfully.
    static func quickCheck(storageService: StorageService) async -> Bool {
        let res = await testConnection(storageService: storageService)
        return res.success
    }
}