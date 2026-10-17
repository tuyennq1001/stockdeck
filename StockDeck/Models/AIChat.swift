import Foundation

/// What the AI Review conversation is advising on: the combined portfolio, a
/// specific portfolio, or a watchlist. Drives which real data `AIPortfolioContext`
/// builds into the prompt.
enum AIReviewScope: Hashable {
    case allPortfolios
    case portfolio(UUID)
    case watchlist(UUID)

    var label: String {
        switch self {
        case .allPortfolios: return "All Portfolios"
        case .portfolio: return "Portfolio"
        case .watchlist: return "Watchlist"
        }
    }

    /// Stable identifier persisted in a conversation so scope survives reloads.
    var idString: String {
        switch self {
        case .allPortfolios: return "all"
        case .portfolio(let id): return "portfolio:\(id.uuidString)"
        case .watchlist(let id): return "watchlist:\(id.uuidString)"
        }
    }

    static func parse(_ idString: String) -> AIReviewScope {
        if idString == "all" { return .allPortfolios }
        if idString.hasPrefix("portfolio:"), let uuid = UUID(uuidString: String(idString.dropFirst("portfolio:".count))) {
            return .portfolio(uuid)
        }
        if idString.hasPrefix("watchlist:"), let uuid = UUID(uuidString: String(idString.dropFirst("watchlist:".count))) {
            return .watchlist(uuid)
        }
        return .allPortfolios
    }
}

/// Known OpenAI-compatible and OAuth provider presets used by the AI Review settings.
enum AIProviderOption: String, CaseIterable, Identifiable {
    case geminiOAuth = "gemini_oauth"
    case claudeOAuth = "claude_oauth"
    case codexOAuth = "codex_oauth"
    case gemini
    case openai
    case deepseek
    case groq
    case openrouter
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .geminiOAuth: return "Google Gemini"
        case .claudeOAuth: return "Claude"
        case .codexOAuth: return "OpenAI Codex"
        case .gemini: return "Google Gemini"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter"
        case .custom: return "Custom…"
        }
    }

    var isOAuth: Bool {
        switch self {
        case .geminiOAuth, .claudeOAuth, .codexOAuth:
            return true
        default:
            return false
        }
    }

    static var oauthProviders: [AIProviderOption] {
        allCases.filter { $0.isOAuth }
    }

    static var apiKeyProviders: [AIProviderOption] {
        allCases.filter { !$0.isOAuth }
    }

    func toggledAuthMode(toOAuth: Bool) -> AIProviderOption {
        if toOAuth {
            switch self {
            case .geminiOAuth, .claudeOAuth, .codexOAuth: return self
            case .gemini: return .geminiOAuth
            case .openai: return .codexOAuth
            default: return .geminiOAuth
            }
        } else {
            switch self {
            case .gemini, .openai, .deepseek, .groq, .openrouter, .custom: return self
            case .geminiOAuth: return .gemini
            case .codexOAuth: return .openai
            case .claudeOAuth: return .gemini
            }
        }
    }

    static var all: [(value: AIProviderOption, label: String)] {
        allCases.map { ($0, $0.label) }
    }
}

/// Role of a message in an AI chat section. Mirrors the chat-completions roles
/// so the section can be mapped straight to an API payload. `.report` is kept
/// only for decoding threads persisted by older builds that auto-generated a
/// portfolio health card; it is never produced or sent to the model anymore.
enum AIChatRole: String, Codable {
    case user
    case assistant
    case report
}

/// One message inside an AI chat section.
struct AIChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: AIChatRole
    let content: String
    let imageBase64: String?
    let createdAt: Date

    init(id: UUID = UUID(), role: AIChatRole, content: String, imageBase64: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.imageBase64 = imageBase64
        self.createdAt = createdAt
    }
}

/// A single AI Review conversation: a title plus the message thread. Stored in
/// full locally (so browsing history costs nothing); only a sliding window of
/// the most recent messages is ever sent to the provider.
struct AIChatSection: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [AIChatMessage]
    var createdAt: Date
    var updatedAt: Date
    /// Scope (all portfolios / one portfolio / watchlist) this conversation
    /// advises on. Persisted so each conversation remembers its own target.
    var scopeID: String?

    init(id: UUID = UUID(), title: String, messages: [AIChatMessage] = [], createdAt: Date = Date(), scopeID: String? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.scopeID = scopeID
    }

    var lastMessagePreview: String {
        messages.last?.content ?? ""
    }

    /// Chat-completions payload: the full stored thread is kept locally, but the
    /// API only ever sees the sliding window of the most recent *dialogue*
    /// messages. Forcing an explicit REQUEST to decide this keeps the model
    /// honest (nothing hidden in a stored property).
    func apiMessages(window: Int = 12) -> [AIChatSection.APIMessage] {
        let dialogue = messages.filter { $0.role == .user || $0.role == .assistant }
        let recent = Array(dialogue.suffix(window))
        return recent.map { AIChatSection.APIMessage(role: $0.role.rawValue, content: $0.content, imageBase64: $0.imageBase64) }
    }

    struct APIMessage: Codable {
        let role: String
        let content: String
        let imageBase64: String?

        init(role: String, content: String, imageBase64: String? = nil) {
            self.role = role
            self.content = content
            self.imageBase64 = imageBase64
        }
    }
}