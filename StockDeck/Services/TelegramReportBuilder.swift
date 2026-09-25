import Foundation

/// Compiles an aggregated, beautiful "All Portfolios" daily summary report
/// formatted in HTML for delivery via Telegram Bot.
@MainActor
enum TelegramReportBuilder {

    enum MarketCategory: String, CaseIterable {
        case us
        case vn
        case jp
        case crypto
        case other

        var order: Int {
            switch self {
            case .us: return 1
            case .vn: return 2
            case .jp: return 3
            case .crypto: return 4
            case .other: return 5
            }
        }

        func title(lang: String) -> String {
            switch (self, lang) {
            case (.us, "vi"): return "🇺🇸 Thị trường Mỹ"
            case (.us, "ja"): return "🇺🇸 米国市場"
            case (.us, _):    return "🇺🇸 US Markets"
            case (.vn, "vi"): return "🇻🇳 Thị trường Việt Nam"
            case (.vn, "ja"): return "🇻🇳 ベトナム市場"
            case (.vn, _):    return "🇻🇳 Vietnam"
            case (.jp, "vi"): return "🇯🇵 Thị trường Nhật Bản"
            case (.jp, "ja"): return "🇯🇵 日本市場"
            case (.jp, _):    return "🇯🇵 Japan"
            case (.crypto, "vi"): return "🪙 Tiền mã hóa / Crypto"
            case (.crypto, "ja"): return "🪙 暗号資産"
            case (.crypto, _):    return "🪙 Crypto"
            case (.other, "vi"): return "🌐 Toàn cầu & Khác"
            case (.other, "ja"): return "🌐 その他グローバル"
            case (.other, _):    return "🌐 Global & Others"
            }
        }
    }

    struct SymbolSummary {
        let symbol: String
        let displayName: String
        let category: MarketCategory
        let value: Double            // in preferred currency
        let cost: Double             // in preferred currency
        let hasCost: Bool
        let dayContribution: Double  // in preferred currency
        let changePercent: Double    // regular session or latest NAV change percent
        let currency: String
    }

    /// Finds the latest daily NAV change for a Japanese mutual fund from price history
    /// when the current intraday change percent is 0 (or unavailable during off-hours).
    static func latestJapaneseFundMove(symbol: String, stockService: StockService) -> (change: Double, changePercent: Double)? {
        let clean = symbol.replacingOccurrences(of: ".JP", with: "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let series = stockService.priceHistory[symbol]
            ?? stockService.priceHistoryMax[symbol]
            ?? stockService.priceHistory[clean]
            ?? stockService.priceHistoryMax[clean],
            series.count >= 2 else {
            return nil
        }
        for i in stride(from: series.count - 1, through: 1, by: -1) {
            let cur = series[i].close
            let prev = series[i - 1].close
            if cur.isFinite && prev.isFinite && prev > 0 && abs(cur - prev) > 0.0001 {
                let chg = cur - prev
                let pct = (chg / prev) * 100.0
                return (chg, pct)
            }
        }
        return nil
    }

    /// Detects market category for a given symbol.
    static func detectCategory(for symbol: String, exchange: String = "", stockService: StockService) -> MarketCategory {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if StockService.isVietnameseStock(upper, exchange: exchange) {
            return .vn
        }
        if StockService.isJapaneseStock(upper) || StockService.isJapaneseMutualFund(upper) {
            return .jp
        }
        if StorageService.isStandardCryptoSymbol(upper) || StorageService.isBinanceNativePair(upper) || upper.hasSuffix("-USD") {
            return .crypto
        }
        return .us
    }

    /// Helper for human-readable schedule descriptions across languages.
    static func scheduleDescription(_ sched: String, lang: String = "en") -> String {
        switch sched {
        case "07:30":
            switch lang {
            case "vi": return "Điểm tin sáng (Đóng cửa Mỹ & Crypto)"
            case "ja": return "朝のブリーフィング（米国・暗号資産引け）"
            default:   return "Morning Briefing (US & Crypto close)"
            }
        case "15:30":
            switch lang {
            case "vi": return "Tổng kết chiều (Đóng cửa VN & Nhật)"
            case "ja": return "午後のまとめ（日本・ベトナム引け）"
            default:   return "Afternoon Wrap (VN & Japan close)"
            }
        case "21:00":
            switch lang {
            case "vi": return "Điểm tin tối"
            case "ja": return "夜のプレビュー"
            default:   return "Evening Preview"
            }
        default:
            switch lang {
            case "vi": return "Báo cáo định kỳ"
            case "ja": return "定期レポート"
            default:   return "Daily summary"
            }
        }
    }

    /// Builds a consolidated HTML report across ALL portfolios with language localization.
    static func buildAllPortfoliosReport(
        storageService: StorageService,
        stockService: StockService,
        scheduleLabel: String? = nil,
        now: Date = Date()
    ) -> String {
        let lang = storageService.appLanguage.lowercased()
        let preferredCurrency = storageService.preferredCurrency
        let currSym = StorageService.currencySymbol(for: preferredCurrency)

        // 1. Single Source of Truth for Portfolio Valuation (Active Holdings)
        let valuationInputs = PortfolioValuation.resolveInputs(
            for: storageService.portfolios,
            stockService: stockService,
            storageService: storageService
        )
        let valuationTotals = PortfolioValuation.totals(valuationInputs)
        let totalVal = valuationTotals.value
        let totalCost = valuationTotals.cost
        let unrealizedPnl = valuationTotals.pnl
        let unrealizedPnlPercent = abs(totalCost) >= 0.01 ? (unrealizedPnl / abs(totalCost)) * 100.0 : 0.0

        // 2. Realized PnL from Closed Trades across all portfolios
        var rawClosed: [(trade: ClosedTrade, portfolioId: UUID, portfolioName: String)] = []
        for p in storageService.portfolios {
            for t in p.closedTrades {
                rawClosed.append((t, p.id, p.name))
            }
        }
        let consolidatedClosed = ConsolidatedClosedTrade.consolidate(tradesWithPortfolio: rawClosed)
        var totalRealized: Double = 0
        var totalClosedCost: Double = 0
        for ct in consolidatedClosed {
            let curr = stockService.detectedCurrency(for: ct.symbol)
            let rate = stockService.rate(from: curr)
            totalRealized += ct.realizedPnl * rate
            totalClosedCost += ct.costBasis * rate
        }
        let totalClosed = consolidatedClosed.count
        let totalProfit = unrealizedPnl + totalRealized
        let totalProfitBase = totalCost > 0 ? totalCost : totalClosedCost
        let totalProfitPercent = totalProfitBase > 0 ? (totalProfit / totalProfitBase) * 100.0 : 0.0

        // 3. Today's Performance (Regular session)
        var todayInputs: [TodayPerformance.Input] = []
        var bySymbol: [String: (summary: SymbolSummary, totalQty: Double)] = [:]

        for portfolio in storageService.portfolios {
            for holding in portfolio.holdings {
                let quote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()] ?? StockQuote(
                    symbol: holding.symbol,
                    name: holding.symbol,
                    price: .nan,
                    change: 0,
                    changePercent: 0,
                    currency: stockService.detectedCurrency(for: holding.symbol)
                )

                let price = quote.price
                let currency = stockService.detectedCurrency(for: holding.symbol)
                let rate = stockService.rate(from: currency)
                let costRate = stockService.rate(from: currency, for: holding.purchaseDate)
                let canon = StockService.canonicalSymbol(for: holding.symbol)
                let clean = canon.replacingOccurrences(of: ".JP", with: "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let isJpFund = quote.isJapaneseFund || stockService.isJapaneseMutualFund(holding.symbol) || holding.isJapaneseFund || StockService.codeToFundNameMap[clean] != nil
                let scale = isJpFund ? 10000.0 : 1.0
                let lev = holding.effectiveLeverage
                let qty = holding.quantity
                let hasCost = holding.hasKnownCostBasis

                let value = price.isFinite ? (price / scale) * qty * lev * rate : 0
                let cost = hasCost ? (holding.avgPrice / scale) * qty * lev * costRate : 0

                let isCrypto = storageService.type(for: holding.symbol) == "CRYPTOCURRENCY" || HomeAIInsightService.cryptoBaseAsset(for: holding.symbol) != nil
                let isMarketActive = MarketCategoryHelper.isTradingDay(symbol: holding.symbol, quote: quote, isCrypto: isCrypto)

                if quote.price.isFinite {
                    todayInputs.append(TodayPerformance.Input(
                        holding: holding,
                        regularPrice: quote.price,
                        previousClose: quote.previousClose,
                        rate: rate,
                        isMarketActiveToday: isMarketActive
                    ))
                }

                // Resolve readable display name (especially for Japanese Mutual Funds)
                let displayName: String
                if isJpFund {
                    if let mapName = StockService.codeToFundNameMap[clean], !mapName.isEmpty {
                        displayName = mapName
                    } else if !quote.name.isEmpty && quote.name != canon && quote.name != clean {
                        displayName = quote.name
                    } else if !quote.displayName.isEmpty && quote.displayName != canon {
                        displayName = quote.displayName
                    } else {
                        displayName = canon
                    }
                } else {
                    displayName = canon
                }

                // Resolve latest non-zero price change for Japanese funds if daily quote is 0%
                var effectiveChangePercent = isMarketActive ? quote.changePercent : 0.0
                var effectiveChange = isMarketActive ? quote.change : 0.0

                if isJpFund && abs(effectiveChangePercent) < 0.0001 {
                    if abs(quote.change) > 0.0001 && quote.previousClose > 0 {
                        effectiveChange = quote.change
                        effectiveChangePercent = (quote.change / quote.previousClose) * 100.0
                    } else if let move = latestJapaneseFundMove(symbol: holding.symbol, stockService: stockService) {
                        effectiveChange = move.change
                        effectiveChangePercent = move.changePercent
                    }
                }

                let contribution = (effectiveChange != 0)
                    ? ((qty * lev) * (effectiveChange / scale) * rate)
                    : 0.0

                let cat = detectCategory(for: canon, exchange: storageService.exchange(for: canon), stockService: stockService)

                if let existing = bySymbol[canon] {
                    let updatedSummary = SymbolSummary(
                        symbol: canon,
                        displayName: displayName,
                        category: cat,
                        value: existing.summary.value + value,
                        cost: existing.summary.cost + cost,
                        hasCost: existing.summary.hasCost || hasCost,
                        dayContribution: existing.summary.dayContribution + contribution,
                        changePercent: (effectiveChangePercent != 0) ? effectiveChangePercent : existing.summary.changePercent,
                        currency: currency
                    )
                    bySymbol[canon] = (updatedSummary, existing.totalQty + qty)
                } else {
                    let newSummary = SymbolSummary(
                        symbol: canon,
                        displayName: displayName,
                        category: cat,
                        value: value,
                        cost: cost,
                        hasCost: hasCost,
                        dayContribution: contribution,
                        changePercent: effectiveChangePercent,
                        currency: currency
                    )
                    bySymbol[canon] = (newSummary, qty)
                }
            }
        }

        let todayTotals = TodayPerformance.totals(todayInputs)
        let totalDayChange = todayTotals.gain
        let dayChangePercent = todayTotals.percent

        // Date & schedule header
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: lang)
        switch lang {
        case "vi":
            dateFormatter.dateFormat = "EEEE, dd/MM/yyyy"
        case "ja":
            dateFormatter.dateFormat = "yyyy/MM/dd (E)"
        default:
            dateFormatter.dateFormat = "EEEE, dd/MM/yyyy"
        }
        let dateString = dateFormatter.string(from: now)
        let scheduleHeader = (scheduleLabel?.isEmpty == false) ? " (\(scheduleLabel!))" : ""

        let titleText: String
        let netWorthLabel: String
        let todayLabel: String
        let profitLabel: String
        let unrealizedLabel: String
        let realizedLabel: String
        let emptyNotice: String
        let footerText: String

        switch lang {
        case "vi":
            titleText = "📊 <b>TỔNG HỢP TOÀN BỘ DANH MỤC\(scheduleHeader)</b>\n"
            netWorthLabel = "Tổng tài sản:"
            todayLabel = "Hôm nay:"
            profitLabel = "Tổng Lợi Nhuận:"
            unrealizedLabel = "Chưa chốt:"
            realizedLabel = "Đã chốt:"
            emptyNotice = "<i>Không có vị thế nào trong các danh mục.</i>\n"
            footerText = "💡 <i>Bản tin StockDeck macOS</i>"
        case "ja":
            titleText = "📊 <b>全ポートフォリオ概要\(scheduleHeader)</b>\n"
            netWorthLabel = "純資産:"
            todayLabel = "本日:"
            profitLabel = "通算損益:"
            unrealizedLabel = "含み損益:"
            realizedLabel = "確定損益:"
            emptyNotice = "<i>ポートフォリオに保有銘柄がありません。</i>\n"
            footerText = "💡 <i>StockDeck macOS ブリーフィング</i>"
        default:
            titleText = "📊 <b>ALL PORTFOLIOS SUMMARY\(scheduleHeader)</b>\n"
            netWorthLabel = "Net Worth:"
            todayLabel = "Today:"
            profitLabel = "Total Profit:"
            unrealizedLabel = "Unrealized:"
            realizedLabel = "Realized:"
            emptyNotice = "<i>No active holdings found in portfolios.</i>\n"
            footerText = "💡 <i>StockDeck macOS Briefing</i>"
        }

        var message = titleText
        message += "🗓 <i>\(dateString)</i>\n"
        message += "━━━━━━━━━━━━━━━━━━━━━\n"
        message += "💰 <b>\(netWorthLabel)</b> <code>\(StorageService.formatAmount(totalVal, symbol: currSym))</code>\n"

        let dayTrendIcon = totalDayChange >= 0 ? "📈" : "📉"
        let daySign = totalDayChange >= 0 ? "+" : ""
        let dayChangeFormatted = StorageService.formatAmount(totalDayChange, symbol: currSym, signed: true)
        message += "\(dayTrendIcon) <b>\(todayLabel)</b> <code>\(dayChangeFormatted) (\(daySign)\(String(format: "%.2f", dayChangePercent))%)</code>\n"

        if totalCost > 0 || totalClosed > 0 {
            let profitTrendIcon = totalProfit >= 0 ? "🏆" : "⚠️"
            let profitSign = totalProfit >= 0 ? "+" : ""
            let profitFormatted = StorageService.formatAmount(totalProfit, symbol: currSym, signed: true)

            let unrealizedSign = unrealizedPnl >= 0 ? "+" : ""
            let unrealizedFormatted = StorageService.formatAmount(unrealizedPnl, symbol: currSym, signed: true)

            let realizedFormatted = StorageService.formatAmount(totalRealized, symbol: currSym, signed: true)

            message += "\(profitTrendIcon) <b>\(profitLabel)</b> <code>\(profitFormatted) (\(profitSign)\(String(format: "%.2f", totalProfitPercent))%)</code>\n"
            message += "  • <i>\(unrealizedLabel)</i> <code>\(unrealizedFormatted) (\(unrealizedSign)\(String(format: "%.2f", unrealizedPnlPercent))%)</code>\n"
            message += "  • <i>\(realizedLabel)</i> <code>\(realizedFormatted)</code>\n"
        }
        message += "━━━━━━━━━━━━━━━━━━━━━\n"

        // Group by Market Category
        let allSummaries = bySymbol.values.map { $0.summary }
        let grouped = Dictionary(grouping: allSummaries, by: { $0.category })
        let sortedCategories = MarketCategory.allCases.sorted { $0.order < $1.order }

        var hasBreakdown = false
        for cat in sortedCategories {
            guard let items = grouped[cat], !items.isEmpty else { continue }
            hasBreakdown = true
            message += "\n<b>\(cat.title(lang: lang))</b>\n"

            // Sort items inside category by holding value descending (largest weight first)
            let sortedItems = items.sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return abs($0.dayContribution) > abs($1.dayContribution)
            }

            for item in sortedItems.prefix(8) {
                let bullet = item.changePercent > 0.0001 ? "🟢" : (item.changePercent < -0.0001 ? "🔴" : "⚪")
                let sign = item.changePercent >= 0 ? "+" : ""
                let pctStr = "\(sign)\(String(format: "%.2f", item.changePercent))%"
                let valStr = StorageService.formatAmount(item.value, symbol: currSym)
                let escapedTitle = TelegramService.escapeHTML(item.displayName)

                if abs(item.dayContribution) > 0.01 {
                    let contribStr = StorageService.formatAmount(item.dayContribution, symbol: currSym, signed: true)
                    message += "• \(bullet) <b>\(escapedTitle)</b>: \(pctStr) · \(valStr) (<code>\(contribStr)</code>)\n"
                } else {
                    message += "• \(bullet) <b>\(escapedTitle)</b>: \(pctStr) · \(valStr)\n"
                }
            }

            if sortedItems.count > 8 {
                let remaining = sortedItems.count - 8
                switch lang {
                case "vi":
                    message += "<i>  …và \(remaining) mã khác</i>\n"
                case "ja":
                    message += "<i>  …他 \(remaining) 銘柄</i>\n"
                default:
                    message += "<i>  …and \(remaining) more</i>\n"
                }
            }
        }

        if !hasBreakdown {
            message += emptyNotice
        }

        message += "━━━━━━━━━━━━━━━━━━━━━\n"
        message += footerText

        return message
    }
}

private enum MarketCategoryHelper {
    static func isTradingDay(symbol: String, quote: StockQuote, isCrypto: Bool) -> Bool {
        MarketCategory.isTradingDay(symbol: symbol, quote: quote, isCrypto: isCrypto)
    }
}
