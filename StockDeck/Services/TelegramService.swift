import Foundation

/// Service for sending Telegram Bot messages and verifying credentials.
enum TelegramService {

    enum TelegramError: LocalizedError {
        case invalidURL
        case missingCredentials
        case apiError(description: String)
        case networkError(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid Telegram API URL or Bot Token format."
            case .missingCredentials:
                return "Bot Token and Chat ID cannot be empty."
            case .apiError(let description):
                return description
            case .networkError(let underlying):
                return underlying.localizedDescription
            }
        }
    }

    /// Safely escapes reserved HTML characters (&, <, >) so they don't break parse_mode: HTML.
    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Queries the Telegram Bot API to get the bot's username (e.g. "my_portfolio_bot").
    static func fetchBotUsername(botToken: String) async -> String? {
        let trimmedToken = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty, let url = URL(string: "https://api.telegram.org/bot\(trimmedToken)/getMe") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let username = result["username"] as? String else {
            return nil
        }
        return username
    }

    /// Converts raw Telegram API error messages into user-friendly localized instructions.
    static func friendlyErrorMessage(for rawError: String, botToken: String, lang: String = "en") async -> String {
        let lower = rawError.lowercased()
        if lower.contains("chat not found") {
            let username = await fetchBotUsername(botToken: botToken)
            let botRef = (username != nil && !username!.isEmpty) ? "@\(username!)" : "bot"
            switch lang {
            case "vi":
                return "Chưa kích hoạt bot. Hãy mở \(botRef) trên Telegram và bấm START (/start) trước."
            case "ja":
                return "Botが未有効化です。Telegramで\(botRef)を開き、/start を押してください。"
            default:
                return "Chat not found. Please open \(botRef) on Telegram and press START (/start) first."
            }
        }
        if lower.contains("unauthorized") || (lower.contains("not found") && lower.contains("token")) {
            switch lang {
            case "vi":
                return "Mã Bot Token không hợp lệ. Vui lòng kiểm tra lại token từ @BotFather."
            case "ja":
                return "無効なBotトークンです。@BotFatherのトークンを確認してください。"
            default:
                return "Invalid Bot Token. Please check the token provided by @BotFather."
            }
        }
        return rawError
    }

    /// Sends an HTML-formatted message to the specified Telegram chat.
    static func sendMessage(botToken: String, chatId: String, text: String) async throws {
        let trimmedToken = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChatId = chatId.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedToken.isEmpty && !trimmedChatId.isEmpty else {
            throw TelegramError.missingCredentials
        }

        guard let url = URL(string: "https://api.telegram.org/bot\(trimmedToken)/sendMessage") else {
            throw TelegramError.invalidURL
        }

        let payload: [String: Any] = [
            "chat_id": trimmedChatId,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 12

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TelegramError.networkError(underlying: error)
        }

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let desc = json["description"] as? String {
                throw TelegramError.apiError(description: desc)
            }
            throw TelegramError.apiError(description: "Telegram API HTTP Error \(httpResponse.statusCode)")
        }
    }

    /// Sends an aggregated portfolio report to Telegram immediately to verify connection and preview real content.
    @MainActor
    static func sendReport(
        storageService: StorageService,
        stockService: StockService
    ) async -> Result<String, Error> {
        let botToken = storageService.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatId = storageService.telegramChatId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !botToken.isEmpty && !chatId.isEmpty else {
            return .failure(TelegramError.missingCredentials)
        }

        let lang = storageService.appLanguage.lowercased()
        let reportText = TelegramReportBuilder.buildAllPortfoliosReport(
            storageService: storageService,
            stockService: stockService
        )

        do {
            try await sendMessage(botToken: botToken, chatId: chatId, text: reportText)
            let successMsg: String
            switch lang {
            case "vi":
                successMsg = "Đã gửi báo cáo danh mục thành công! Hãy kiểm tra Telegram."
            case "ja":
                successMsg = "ポートフォリオレポートを送信しました。Telegramをご確認ください。"
            default:
                successMsg = "Portfolio report sent successfully! Check your Telegram."
            }
            return .success(successMsg)
        } catch {
            let friendly = await friendlyErrorMessage(for: error.localizedDescription, botToken: botToken, lang: lang)
            return .failure(TelegramError.apiError(description: friendly))
        }
    }

    /// Sends a friendly test ping to verify credentials and ensure the bot can reach the chat.
    static func testConnection(botToken: String, chatId: String, lang: String = "en") async -> Result<String, Error> {
        let testMessage = """
        🤖 <b>StockDeck Telegram Connection Verified!</b>
        ━━━━━━━━━━━━━━━━━━━━━
        Your Telegram Bot is successfully connected to StockDeck.
        Daily summaries and portfolio updates will be delivered here.
        """
        do {
            try await sendMessage(botToken: botToken, chatId: chatId, text: testMessage)
            let successMsg: String
            switch lang {
            case "vi":
                successMsg = "Đã gửi tin nhắn kiểm tra thành công! Hãy kiểm tra Telegram."
            case "ja":
                successMsg = "テストメッセージを送信しました。Telegramをご確認ください。"
            default:
                successMsg = "Test message sent successfully! Check your Telegram."
            }
            return .success(successMsg)
        } catch {
            let friendly = await friendlyErrorMessage(for: error.localizedDescription, botToken: botToken, lang: lang)
            return .failure(TelegramError.apiError(description: friendly))
        }
    }
}
