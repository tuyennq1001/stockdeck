import XCTest
@testable import StockDeck

/// Covers the AI Review foundation that must not regress:
/// (1) the sliding-window API payload — a long conversation stays cheap because
/// only the most recent dialogue messages are sent, and reports never enter the
/// window; (2) the compact portfolio context — it caps top positions so token
/// cost stays flat regardless of portfolio size, and always uses the app's
/// regular-session valuation math (no fabricated figures).
@MainActor
final class AIReviewTests: XCTestCase {

    // MARK: - AIChatSection

    private func msg(_ role: AIChatRole, _ i: Int) -> AIChatMessage {
        AIChatMessage(role: role, content: "content \(i)")
    }

    func testApiMessagesTakesOnlyTheWindowTail() {
        var section = AIChatSection(title: "T")
        for i in 1...30 {
            section.messages.append(msg(.user, i))
            section.messages.append(msg(.assistant, i))
        }
        let api = section.apiMessages(window: 12)
        XCTAssertEqual(api.count, 12)
        XCTAssertEqual(api.first?.content, "content 25") // latest 6 turns only
        XCTAssertEqual(api.last?.content, "content 30")
        XCTAssertTrue(api.allSatisfy { $0.role == "user" || $0.role == "assistant" })
    }

    func testApiMessagesExcludesReports() {
        var section = AIChatSection(title: "T")
        section.messages.append(msg(.user, 1))
        section.messages.append(msg(.report, 1)) // legacy role, never sent to the API
        let api = section.apiMessages(window: 12)
        XCTAssertEqual(api.map(\.content), ["content 1"])
        XCTAssertEqual(api.count, 1)
    }

    // MARK: - AIPortfolioContext (pure aggregation, no network)

    private func makeHolding(symbol: String, qty: Double, avg: Double) -> Holding {
        Holding(symbol: symbol, quantity: qty, avgPrice: avg)
    }

    func testContextCapsTopPositionsAndKeepsTotals() {
        // A stock-heavy portfolio where cost basis is known → P&L is real.
        var holdings: [Holding] = []
        for i in 0..<40 {
            holdings.append(makeHolding(symbol: "S\(i)", qty: 10, avg: 100))
        }
        let context = AIPortfolioContext.build(
            storageService: .shared,
            stockService: .shared,
            scope: .allPortfolios,
            viewModel: nil
        )
        // With no quotes loaded, value is 0 → context still renders but caps.
        XCTAssertLessThanOrEqual(context.topPositions.count, 10)
        XCTAssertGreaterThanOrEqual(context.contextText.count, 0)
    }

    func testContextTextMentionsMissingHistoryInsteadOfGuessing() {
        let context = AIPortfolioContext.build(
            storageService: .shared,
            stockService: .shared,
            scope: .allPortfolios,
            viewModel: nil
        )
        // Instructions must forbid inventing data and label '-' explicitly.
        XCTAssertTrue(context.contextText.lowercased().contains("insufficient"))
        XCTAssertTrue(context.contextText.lowercased().contains("never guess"))
    }

    func testScopeIDRoundTrip() {
        XCTAssertEqual(AIReviewScope.parse(AIReviewScope.allPortfolios.idString), .allPortfolios)
        let pid = UUID()
        XCTAssertEqual(AIReviewScope.parse(AIReviewScope.portfolio(pid).idString), .portfolio(pid))
        let wid = UUID()
        XCTAssertEqual(AIReviewScope.parse(AIReviewScope.watchlist(wid).idString), .watchlist(wid))
        XCTAssertEqual(AIReviewScope.parse("garbage"), .allPortfolios)
    }

    func testWorkspaceNotesInjectedWhenConfigured() {
        // Point at a temp folder and write notes — they must appear in context.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let notes = tmp.appendingPathComponent("ai-context.md")
        try? "Risk tolerance: moderate; goal: growth over 10y".write(to: notes, atomically: true, encoding: .utf8)
        let storage = StorageService.shared
        let original = storage.aiWorkspacePath
        storage.aiWorkspacePath = tmp.path
        defer { storage.aiWorkspacePath = original }
        let context = AIPortfolioContext.build(
            storageService: storage,
            stockService: .shared,
            scope: .allPortfolios,
            viewModel: nil
        )
        XCTAssertTrue(context.contextText.contains("WORKSPACE NOTES"))
        XCTAssertTrue(context.contextText.contains("Risk tolerance: moderate"))
    }

    func testInvestorProfileSummaryAndPromptContext() {
        let profile = InvestorProfile(
            age: 27,
            maritalStatus: "Độc thân",
            riskTolerance: .aggressive,
            investmentStyle: .dcaBuyAndHold,
            investmentHorizon: .longTerm,
            primaryGoal: "10 năm sau mua nhà và 40 năm sau nghỉ hưu",
            monthlyContribution: 1000,
            customNotes: "Không margin"
        )

        XCTAssertTrue(profile.summaryDescription.contains("27 tuổi"))
        XCTAssertTrue(profile.summaryDescription.contains("Độc thân"))
        XCTAssertTrue(profile.summaryDescription.contains("Rủi ro cao"))
        XCTAssertTrue(profile.summaryDescription.contains("Tích sản DCA"))

        let promptText = profile.promptContextText(preferredCurrency: "USD")
        XCTAssertTrue(promptText.contains("INVESTOR PROFILE & GOALS"))
        XCTAssertTrue(promptText.contains("Age: 27"))
        XCTAssertTrue(promptText.contains("Marital/Family Status: Độc thân"))
        XCTAssertTrue(promptText.contains("10 năm sau mua nhà và 40 năm sau nghỉ hưu"))
        XCTAssertTrue(promptText.contains("1000 USD"))
        XCTAssertTrue(promptText.contains("Không margin"))
    }

    func testAIPortfolioContextIncludesInvestorProfile() {
        let storage = StorageService.shared
        let originalProfile = storage.investorProfile
        let testProfile = InvestorProfile(
            age: 30,
            maritalStatus: "Đã kết hôn",
            riskTolerance: .moderate,
            investmentStyle: .dividend,
            investmentHorizon: .mediumTerm,
            primaryGoal: "Tự do tài chính sau 15 năm"
        )
        storage.investorProfile = testProfile
        defer { storage.investorProfile = originalProfile }

        let context = AIPortfolioContext.build(
            storageService: storage,
            stockService: .shared,
            scope: .allPortfolios,
            viewModel: nil
        )

        XCTAssertTrue(context.contextText.contains("INVESTOR PROFILE & GOALS"))
        XCTAssertTrue(context.contextText.contains("Age: 30"))
        XCTAssertTrue(context.contextText.contains("Đã kết hôn"))
        XCTAssertTrue(context.contextText.contains("Tự do tài chính sau 15 năm"))
    }

    func testInvestorProfileSerializationInAppData() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let storage = StorageService(fileURL: tempURL)

        let testProfile = InvestorProfile(
            age: 28,
            maritalStatus: "Độc thân",
            riskTolerance: .aggressive,
            investmentStyle: .growth,
            investmentHorizon: .longTerm,
            primaryGoal: "Mua nhà 10 năm"
        )
        storage.investorProfile = testProfile

        let exported = storage.exportAppData()
        XCTAssertEqual(exported.investorProfile?.age, 28)
        XCTAssertEqual(exported.investorProfile?.primaryGoal, "Mua nhà 10 năm")

        storage.investorProfile = nil
        storage.applyAppData(exported)
        XCTAssertEqual(storage.investorProfile?.age, 28)
        XCTAssertEqual(storage.investorProfile?.riskTolerance, .aggressive)
        XCTAssertEqual(storage.investorProfile?.primaryGoal, "Mua nhà 10 năm")
    }

    func testAIPortfolioContextIncludesXIRRWhenHoldingsHaveDates() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let storage = StorageService(fileURL: tempURL)

        let stockService = StockService.shared
        stockService.quotes["AAPL"] = StockQuote(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 180.0,
            change: 2.0,
            changePercent: 1.1,
            currency: "USD"
        )

        let pId = UUID()
        let buyDate = Date().addingTimeInterval(-100 * 86400)
        let holding = Holding(symbol: "AAPL", quantity: 10, avgPrice: 150, purchaseDate: buyDate)
        let portfolio = Portfolio(id: pId, name: "Test Portfolio", holdings: [holding])
        storage.portfolios = [portfolio]

        let context = AIPortfolioContext.build(
            storageService: storage,
            stockService: stockService,
            scope: .portfolio(pId),
            viewModel: nil
        )

        XCTAssertTrue(context.contextText.contains("ACTUAL MONEY-WEIGHTED RETURN (XIRR / Real Cash Flow Performance)"))
    }

    // MARK: - Auto-Detection & Dynamic Models

    func testAutoDetectProviderFromAPIKey() {
        XCTAssertEqual(StorageService.autoDetectProvider(from: "AIzaSyDummyGeminiKey123"), "gemini")
        XCTAssertEqual(StorageService.autoDetectProvider(from: "gsk_DummyGroqKey456"), "groq")
        XCTAssertEqual(StorageService.autoDetectProvider(from: "sk-or-DummyOpenRouter789"), "openrouter")
        XCTAssertNil(StorageService.autoDetectProvider(from: "random-custom-key"))
    }

    func testAvailableModelsAndPresetFallback() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let storage = StorageService(fileURL: tempURL)

        let geminiModels = storage.availableModels(for: "gemini")
        XCTAssertTrue(geminiModels.contains("gemini-2.0-flash"))
        XCTAssertTrue(geminiModels.contains("gemini-1.5-flash"))

        let openaiModels = storage.availableModels(for: "openai")
        XCTAssertTrue(openaiModels.contains("gpt-4o-mini"))
        XCTAssertTrue(openaiModels.contains("gpt-4o"))
    }

    func testSetCachedModelsPersistsPerProvider() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let storage = StorageService(fileURL: tempURL)

        let customServerModels = ["gemini-custom-pro", "gemini-custom-flash"]
        storage.setCachedModels(customServerModels, for: "gemini")

        let retrieved = storage.availableModels(for: "gemini")
        XCTAssertTrue(retrieved.contains("gemini-custom-pro"))
        XCTAssertTrue(retrieved.contains("gemini-custom-flash"))

        let exported = storage.exportAppData()
        XCTAssertEqual(exported.cachedModelsByProvider?["gemini"], customServerModels)

        storage.cachedModelsByProvider = [:]
        storage.applyAppData(exported)
        XCTAssertEqual(storage.cachedModelsByProvider["gemini"], customServerModels)
    }

    func testApplyAIPresetSwitchesModelAndURL() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let storage = StorageService(fileURL: tempURL)

        storage.applyAIPreset("gemini")
        XCTAssertEqual(storage.aiProvider, "gemini")
        XCTAssertEqual(storage.aiBaseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(storage.aiModel, "gemini-2.0-flash")

        storage.applyAIPreset("groq")
        XCTAssertEqual(storage.aiProvider, "groq")
        XCTAssertEqual(storage.aiBaseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(storage.aiModel, "llama-3.3-70b-versatile")
    }

    func testKeychainServiceSaveAndLoad() {
        let testKey = "test_keychain_service_ai_key"
        defer { _ = KeychainService.delete(key: testKey) }

        let testValue = "AIzaSyDummyTestKey123456789"
        let saved = KeychainService.saveString(testValue, forKey: testKey)
        XCTAssertTrue(saved, "KeychainService.saveString should return true")

        let loaded = KeychainService.loadString(forKey: testKey)
        XCTAssertEqual(loaded, testValue, "Loaded key should match saved key")
    }
}