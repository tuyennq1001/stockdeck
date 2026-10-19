import Foundation
import Combine

/// Represents a cached full-text translation of a news article for Reader Mode.
struct TranslatedArticle: Codable, Sendable {
    let title: String
    let paragraphs: [String]
    let translatedAt: Date
}

/// Service that handles AI translation and local caching for financial news headlines
/// and Reader Mode articles.
///
/// Features:
/// - Batch translation of multiple headlines in a single AI request (fast, quota-efficient).
/// - In-memory and on-disk persistent cache (0ms lookup on repeat opens).
/// - Automatic language detection (skips articles already in the target language).
/// - Non-blocking background execution with `@MainActor` reactive published state.
@MainActor
final class NewsTranslationService: ObservableObject {
    static let shared = NewsTranslationService()

    /// Translated headlines keyed by article ID or normalized title key.
    @Published private(set) var headlineTranslations: [String: String] = [:]

    /// Full article translations keyed by canonical/article link.
    @Published private(set) var articleTranslations: [String: TranslatedArticle] = [:]

    /// Headline batch translation in progress indicator.
    @Published private(set) var isTranslatingHeadlines = false

    /// Set of article URLs currently being translated.
    @Published private(set) var translatingArticleLinks: Set<String> = []

    /// Flag indicating whether the AI translation provider hit a quota or rate limit (HTTP 429).
    @Published private(set) var isQuotaExhausted = false

    /// Latest error description from translation provider, if any.
    @Published private(set) var lastTranslationError: String? = nil

    private static let cacheFileName = "newsTranslationCache.json"
    private var cacheFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("\(AppEnvironment.appSupportFolderName)/\(Self.cacheFileName)")
    }

    private struct DiskCache: Codable {
        var headlines: [String: String]
        var articles: [String: TranslatedArticle]
    }

    private var saveTask: Task<Void, Never>?
    private var isBatchTranslating = false

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    /// Returns the translated title for an article if available in cache.
    func translatedTitle(for article: NewsArticle) -> String? {
        if let direct = headlineTranslations[article.id], !direct.isEmpty {
            return direct
        }
        let key = GoogleNewsRSSParser.normalizedTitleKey(article.title)
        if !key.isEmpty, let byKey = headlineTranslations[key], !byKey.isEmpty {
            return byKey
        }
        return nil
    }

    private var pendingQueue: [NewsArticle] = []
    private var isProcessingQueue = false

    /// Automatically translates a batch of article headlines in the background.
    /// Batches pending headlines into single AI requests (up to 12 per batch) to minimize latency and token usage.
    func translateHeadlinesIfNeeded(articles: [NewsArticle], storageService: StorageService) {
        guard storageService.autoTranslateNews, storageService.hasAIConfiguration else { return }
        let targetLang = storageService.appLanguage.lowercased()
        guard targetLang != "en" else { return }

        // Collect articles needing translation
        var newPending: [NewsArticle] = []
        for article in articles {
            let key = GoogleNewsRSSParser.normalizedTitleKey(article.title)
            let hasById = headlineTranslations[article.id] != nil
            let hasByKey = !key.isEmpty && headlineTranslations[key] != nil
            if hasById || hasByKey {
                continue
            }
            if isAlreadyInTargetLanguage(text: article.title, targetLang: targetLang) {
                headlineTranslations[article.id] = article.title
                if !key.isEmpty { headlineTranslations[key] = article.title }
                continue
            }
            if !pendingQueue.contains(where: { $0.id == article.id }) {
                newPending.append(article)
            }
        }

        guard !newPending.isEmpty else { return }
        pendingQueue.append(contentsOf: newPending)

        guard !isProcessingQueue else { return }

        Task {
            await self.processQueue(targetLang: targetLang, storageService: storageService)
        }
    }

    private func processQueue(targetLang: String, storageService: StorageService) async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        isTranslatingHeadlines = true
        defer {
            isProcessingQueue = false
            isTranslatingHeadlines = false
        }

        while !pendingQueue.isEmpty {
            let batchSize = 15
            let batch = Array(pendingQueue.prefix(batchSize))
            pendingQueue.removeFirst(min(batchSize, pendingQueue.count))
            await executeBatchHeadlineTranslation(articles: batch, targetLang: targetLang, storageService: storageService)
        }
    }

    /// Translates an article's full body for Reader Mode.
    func translateArticleIfNeeded(
        link: String,
        fallbackTitle: String,
        paragraphs: [String],
        storageService: StorageService
    ) async -> TranslatedArticle? {
        if let cached = articleTranslations[link] {
            return cached
        }

        guard storageService.autoTranslateNews, storageService.hasAIConfiguration else { return nil }
        let targetLang = storageService.appLanguage.lowercased()
        guard targetLang != "en" else { return nil }

        if paragraphs.isEmpty { return nil }

        // If content already matches target language, cache directly
        let combined = paragraphs.prefix(3).joined(separator: " ")
        if isAlreadyInTargetLanguage(text: combined, targetLang: targetLang) {
            let result = TranslatedArticle(title: fallbackTitle, paragraphs: paragraphs, translatedAt: Date())
            articleTranslations[link] = result
            scheduleSave()
            return result
        }

        guard !translatingArticleLinks.contains(link) else { return nil }
        translatingArticleLinks.insert(link)
        defer { translatingArticleLinks.remove(link) }

        return await executeArticleTranslation(
            link: link,
            fallbackTitle: fallbackTitle,
            paragraphs: paragraphs,
            targetLang: targetLang,
            storageService: storageService
        )
    }

    // MARK: - Internal Translation Execution

    private func executeBatchHeadlineTranslation(
        articles: [NewsArticle],
        targetLang: String,
        storageService: StorageService
    ) async {
        guard !articles.isEmpty else { return }
        let targetLangName = Self.targetLanguageName(for: targetLang)

        var itemsDict: [String: String] = [:]
        for (idx, art) in articles.enumerated() {
            itemsDict["\(idx)"] = art.title
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: itemsDict, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let systemPrompt = """
        You are a professional financial news translator. Translate the provided headlines into \(targetLangName).
        Rules:
        1. Keep stock tickers (e.g. NVDA, AAPL, 1489, VOO, S&P 500), company names, numbers, and currencies accurate and natural.
        2. Return ONLY a valid JSON object mapping each numeric string key to its translated headline.
        Example: {"0": "...", "1": "..."}
        No extra explanations, no markdown formatting outside of the json block.
        """

        let request = AIReviewService.Request(
            baseURL: storageService.aiBaseURL,
            apiKey: storageService.aiApiKey,
            model: storageService.aiModel,
            systemContext: systemPrompt,
            messages: [AIChatSection.APIMessage(role: "user", content: jsonString)],
            thinking: storageService.aiProvider == "deepseek" ? storageService.aiDeepseekThinking : nil,
            maxTokens: 1500,
            enableSearchGrounding: false,
            provider: storageService.aiProvider
        )

        do {
            let reply = try await AIReviewService.shared.send(request: request)
            if let parsed = Self.parseJSONDictionary(from: reply) {
                for (idxStr, translated) in parsed {
                    guard let idx = Int(idxStr), idx >= 0, idx < articles.count else { continue }
                    let art = articles[idx]
                    let clean = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        self.headlineTranslations[art.id] = clean
                        let key = GoogleNewsRSSParser.normalizedTitleKey(art.title)
                        if !key.isEmpty {
                            self.headlineTranslations[key] = clean
                        }
                    }
                }
                self.recordSuccess()
                self.scheduleSave()
            }
        } catch {
            self.checkAndRecordError(error)
            NSLog("[NewsTranslationService] Batch headline translation error: \(error.localizedDescription)")
        }
    }

    private func executeArticleTranslation(
        link: String,
        fallbackTitle: String,
        paragraphs: [String],
        targetLang: String,
        storageService: StorageService
    ) async -> TranslatedArticle? {
        let targetLangName = Self.targetLanguageName(for: targetLang)

        // Clean paragraphs and limit to first 12 paragraphs to preserve quality and speed
        let inputParas = paragraphs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(12)
        guard !inputParas.isEmpty else { return nil }

        let payload: [String: Any] = [
            "title": fallbackTitle,
            "paragraphs": Array(inputParas)
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        let systemPrompt = """
        You are a financial news translator. Translate this article into \(targetLangName).
        Rules:
        1. Keep company names, tickers, numbers, and financial metrics accurate and natural in \(targetLangName).
        2. Return ONLY a valid JSON object with the exact keys "title" and "paragraphs":
        {
          "title": "Translated headline",
          "paragraphs": ["Translated para 1", "Translated para 2"]
        }
        No markdown formatting outside the JSON block.
        """

        let request = AIReviewService.Request(
            baseURL: storageService.aiBaseURL,
            apiKey: storageService.aiApiKey,
            model: storageService.aiModel,
            systemContext: systemPrompt,
            messages: [AIChatSection.APIMessage(role: "user", content: jsonString)],
            thinking: storageService.aiProvider == "deepseek" ? storageService.aiDeepseekThinking : nil,
            maxTokens: 3000,
            enableSearchGrounding: false,
            provider: storageService.aiProvider
        )

        do {
            let reply = try await AIReviewService.shared.send(request: request)
            if let decoded = Self.parseArticleJSON(from: reply) {
                let result = TranslatedArticle(title: decoded.title, paragraphs: decoded.paragraphs, translatedAt: Date())
                self.articleTranslations[link] = result
                self.recordSuccess()
                self.scheduleSave()
                return result
            }
        } catch {
            self.checkAndRecordError(error)
            NSLog("[NewsTranslationService] Article translation error: \(error.localizedDescription)")
        }
        return nil
    }

    func resetQuotaState() {
        isQuotaExhausted = false
        lastTranslationError = nil
    }

    private func checkAndRecordError(_ error: Error) {
        let errStr = error.localizedDescription
        lastTranslationError = errStr
        let lower = errStr.lowercased()
        if lower.contains("429") ||
            lower.contains("resource_exhausted") ||
            lower.contains("quota") ||
            lower.contains("rate limit") ||
            lower.contains("ratelimit") ||
            lower.contains("exhausted") {
            isQuotaExhausted = true
        }
    }

    private func recordSuccess() {
        if isQuotaExhausted {
            isQuotaExhausted = false
        }
        lastTranslationError = nil
    }

    // MARK: - Language & Parsing Helpers

    nonisolated static func targetLanguageName(for code: String) -> String {
        switch code.lowercased() {
        case "vi": return "Vietnamese"
        case "ja": return "Japanese"
        case "zh": return "Simplified Chinese"
        case "de": return "German"
        case "fr": return "French"
        case "es": return "Spanish"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        default: return "English"
        }
    }

    nonisolated static func isVietnameseText(_ text: String) -> Bool {
        let vnChars = "àáảãạăắằẳẵặâấầẩẫậèéẻẽẹêếềểễệìíỉĩịòóỏõọôốồổỗộơớờởỡợùúủũụưứừửữựỳýỷỹỵđÀÁẢÃẠĂẮẰẲẴẶÂẤẦẨẪẬÈÉẺẼẸÊẾỀỂỄỆÌÍỈĨỊÒÓỎÕỌÔỐỒỔỖỘƠỚỜỞỠỢÙÚỦŨỤƯỨỪỬỮỰỲÝỶỸỴĐ"
        return text.contains { vnChars.contains($0) }
    }

    private func isAlreadyInTargetLanguage(text: String, targetLang: String) -> Bool {
        if targetLang == "vi" {
            return Self.isVietnameseText(text)
        }
        if targetLang == "ja" {
            // Check for Hiragana or Katakana unicode ranges
            return text.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value) }
        }
        return false
    }

    nonisolated static func parseJSONDictionary(from text: String) -> [String: String]? {
        let cleaned = extractJSONBlock(from: text)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        if let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }
        if let intDict = try? JSONDecoder().decode([Int: String].self, from: data) {
            var result: [String: String] = [:]
            for (k, v) in intDict {
                result["\(k)"] = v
            }
            return result
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var result: [String: String] = [:]
            for (k, v) in json {
                if let s = v as? String {
                    result[k] = s
                }
            }
            if !result.isEmpty { return result }
        }
        return nil
    }

    nonisolated static func parseArticleJSON(from text: String) -> (title: String, paragraphs: [String])? {
        struct ArticlePayload: Decodable {
            let title: String
            let paragraphs: [String]
        }
        let cleaned = extractJSONBlock(from: text)
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ArticlePayload.self, from: data) else {
            return nil
        }
        return (decoded.title, decoded.paragraphs)
    }

    nonisolated private static func extractJSONBlock(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonStart = trimmed.range(of: "```json") {
            let afterStart = trimmed[jsonStart.upperBound...]
            if let fenceEnd = afterStart.range(of: "```") {
                return String(afterStart[..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let codeStart = trimmed.range(of: "```") {
            let afterStart = trimmed[codeStart.upperBound...]
            if let fenceEnd = afterStart.range(of: "```") {
                return String(afterStart[..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace < lastBrace {
            return String(trimmed[firstBrace...lastBrace])
        }
        return trimmed
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheFileURL)
            let decoded = try JSONDecoder().decode(DiskCache.self, from: data)
            self.headlineTranslations = decoded.headlines
            self.articleTranslations = decoded.articles
        } catch {
            NSLog("[NewsTranslationService] Failed to load translation cache: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let cache = DiskCache(headlines: headlineTranslations, articles: articleTranslations)
        let url = cacheFileURL
        saveTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(cache)
                let parentDir = url.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[NewsTranslationService] Failed to save translation cache: \(error.localizedDescription)")
            }
        }
    }

    func saveImmediately() {
        saveTask?.cancel()
        let cache = DiskCache(headlines: headlineTranslations, articles: articleTranslations)
        let url = cacheFileURL
        do {
            let data = try JSONEncoder().encode(cache)
            let parentDir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[NewsTranslationService] Failed to save translation cache immediately: \(error.localizedDescription)")
        }
    }
}
