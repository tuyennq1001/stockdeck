import Foundation

/// A lightweight connectivity probe for the configured AI provider: sends the
/// tiniest possible chat-completions request and reports whether the provider
/// answered. Used by the "Test connection" button in settings.
@MainActor
enum TestAI {
    /// Returns true if the configured provider responds successfully.
    static func quickCheck(storageService: StorageService) async -> Bool {
        guard !storageService.aiApiKey.isEmpty else { return false }
        let service = AIReviewService.shared
        let request = AIReviewService.Request(
            baseURL: storageService.aiBaseURL,
            apiKey: storageService.aiApiKey,
            model: storageService.aiModel,
            systemContext: "You are a connectivity check. Reply with exactly: ok",
            messages: [AIChatSection.APIMessage(role: "user", content: "ping")],
            thinking: storageService.aiProvider == "deepseek" ? storageService.aiDeepseekThinking : nil
        )
        do {
            let reply = try await service.send(request: request)
            return !reply.isEmpty
        } catch {
            return false
        }
    }
}