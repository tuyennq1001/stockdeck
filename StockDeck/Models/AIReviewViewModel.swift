import SwiftUI
import Combine

/// View model for the AI Review tab: owns the chat sections, the conversation
/// state, and the provider calls. Chat history lives in `StorageService`
/// (persisted locally, free); this model only drives the send flow and
/// the loading/error state of the current request.
@MainActor
@Observable
final class AIReviewViewModel {
    let stockService: StockService
    let storageService: StorageService

    private let service = AIReviewService.shared

    /// The section currently open in the chat pane.
    var selectedSectionID: UUID?
    /// The draft text in the composer.
    var draft = ""
    /// True while a user message is being sent.
    var isSending = false
    /// Last error surfaced in the chat pane.
    var errorMessage: String?

    init(stockService: StockService, storageService: StorageService) {
        self.stockService = stockService
        self.storageService = storageService
    }

    var selectedSection: AIChatSection? {
        guard let id = selectedSectionID else { return nil }
        return storageService.aiChatSections.first { $0.id == id }
    }

    // MARK: - Conversation management

    func newChat() {
        let section = AIChatSection(title: "New conversation")
        storageService.aiChatSections.insert(section, at: 0)
        selectedSectionID = section.id
        draft = ""
        errorMessage = nil
    }

    func select(_ section: AIChatSection) {
        selectedSectionID = section.id
        draft = ""
        errorMessage = nil
    }

    func delete(_ section: AIChatSection) {
        storageService.aiChatSections.removeAll { $0.id == section.id }
        if selectedSectionID == section.id {
            selectedSectionID = storageService.aiChatSections.first?.id
        }
    }

    func rename(_ section: AIChatSection, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = storageService.aiChatSections.firstIndex(where: { $0.id == section.id }) else { return }
        var updated = storageService.aiChatSections[idx]
        updated.title = trimmed
        storageService.aiChatSections[idx] = updated
    }

    // MARK: - Sending

    /// Appends the user message and sends the conversation to the provider.
    /// On success the draft is cleared; failures set `errorMessage` without
    /// losing the user's text.
    func sendCurrentMessage() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard !storageService.aiApiKey.isEmpty else {
            errorMessage = "Set an API key in Settings → AI Review first."
            return
        }
        guard let sectionID = selectedSectionID else { return }

        append(sectionID, role: .user, content: text)
        draft = ""
        errorMessage = nil
        isSending = true
        defer { isSending = false }

        do {
            let rawReply = try await service.send(request: makeRequest(sectionID: sectionID))
            let reply = strippingSaveMarker(from: rawReply)
            append(sectionID, role: .assistant, content: reply)
            await persistWorkspaceSave(from: rawReply)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the `[SAVE_TO_WORKSPACE]…[/SAVE_TO_WORKSPACE]` marker so it never
    /// shows up in the chat. Persisting the note happens separately.
    private func strippingSaveMarker(from reply: String) -> String {
        let pattern = "\\[SAVE_TO_WORKSPACE\\]\\s*[\\s\\S]*?\\s*\\[/SAVE_TO_WORKSPACE\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return reply }
        let range = NSRange(reply.startIndex..., in: reply)
        let stripped = regex.stringByReplacingMatches(in: reply, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts any `[SAVE_TO_WORKSPACE]…[/SAVE_TO_WORKSPACE]` block the model
    /// emitted and persists its content to `ai-context.md`, so the assistant's
    /// "remember this" notes survive across conversations.
    private func persistWorkspaceSave(from reply: String) async {
        let pattern = "\\[SAVE_TO_WORKSPACE\\]\\s*([\\s\\S]*?)\\s*\\[/SAVE_TO_WORKSPACE\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: reply, range: NSRange(reply.startIndex..., in: reply)),
              match.numberOfRanges >= 2,
              let contentRange = Range(match.range(at: 1), in: reply) else { return }
        let note = String(reply[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        storageService.appendAIWorkspaceNote(note)
    }

    // MARK: - Request building

    private func makeRequest(sectionID: UUID, extraUserPrompt: String? = nil) -> AIReviewService.Request {
        let context = AIPortfolioContext.build(
            storageService: storageService,
            stockService: stockService,
            scope: .allPortfolios,
            viewModel: nil
        )
        var messages: [AIChatSection.APIMessage] = []
        if let section = storageService.aiChatSections.first(where: { $0.id == sectionID }) {
            messages = section.apiMessages(window: 12)
        }
        if let extraUserPrompt {
            messages.append(AIChatSection.APIMessage(role: "user", content: extraUserPrompt))
        }
        return AIReviewService.Request(
            baseURL: storageService.aiBaseURL,
            apiKey: storageService.aiApiKey,
            model: storageService.aiModel,
            systemContext: context.contextText,
            messages: messages,
            thinking: storageService.aiProvider == "deepseek" ? storageService.aiDeepseekThinking : nil
        )
    }

    private func append(_ sectionID: UUID, role: AIChatRole, content: String) {
        guard let idx = storageService.aiChatSections.firstIndex(where: { $0.id == sectionID }) else { return }
        var section = storageService.aiChatSections[idx]
        section.messages.append(AIChatMessage(role: role, content: content))
        section.updatedAt = Date()
        if role == .user, section.title == "New conversation" {
            section.title = String(content.prefix(48))
        }
        storageService.aiChatSections[idx] = section
    }

    // MARK: - Workspace memory

    /// Writes a note into the workspace `ai-context.md` so the assistant
    /// remembers it across conversations. Returns true on success.
    @discardableResult
    func saveToWorkspace(_ note: String) -> Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return storageService.appendAIWorkspaceNote(trimmed)
    }
}