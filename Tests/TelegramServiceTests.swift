import XCTest
@testable import StockDeck

final class TelegramServiceTests: XCTestCase {

    func testEscapeHTML() {
        let input = "FPT & Apple <AAPL> > $150"
        let escaped = TelegramService.escapeHTML(input)
        XCTAssertEqual(escaped, "FPT &amp; Apple &lt;AAPL&gt; &gt; $150")
    }

    func testEmptyCredentialsThrows() async {
        do {
            try await TelegramService.sendMessage(botToken: "", chatId: "", text: "Hello")
            XCTFail("Expected error for empty credentials")
        } catch {
            XCTAssertTrue(error is TelegramService.TelegramError)
        }
    }

    func testFriendlyErrorMessageChatNotFound() async {
        let raw = "Bad Request: chat not found"
        let msgVi = await TelegramService.friendlyErrorMessage(for: raw, botToken: "", lang: "vi")
        XCTAssertTrue(msgVi.contains("Chưa kích hoạt bot"))
        XCTAssertTrue(msgVi.contains("/start"))

        let msgEn = await TelegramService.friendlyErrorMessage(for: raw, botToken: "", lang: "en")
        XCTAssertTrue(msgEn.contains("Chat not found"))
        XCTAssertTrue(msgEn.contains("/start"))

        let msgJa = await TelegramService.friendlyErrorMessage(for: raw, botToken: "", lang: "ja")
        XCTAssertTrue(msgJa.contains("Botが未有効化です"))
    }

    func testFriendlyErrorMessageUnauthorized() async {
        let raw = "Unauthorized"
        let msgVi = await TelegramService.friendlyErrorMessage(for: raw, botToken: "", lang: "vi")
        XCTAssertTrue(msgVi.contains("Mã Bot Token không hợp lệ"))

        let msgEn = await TelegramService.friendlyErrorMessage(for: raw, botToken: "", lang: "en")
        XCTAssertTrue(msgEn.contains("Invalid Bot Token"))
    }
}
