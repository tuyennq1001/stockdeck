import Foundation

/// Builds a compact, truthful snapshot of the user's portfolio that is sent to
/// the AI provider as system context. All numbers come from the app's existing
/// single source of truth (`PortfolioValuation.resolveInputs`, today
/// performance, and the session-cached performance matrix) — no fabricated or
/// heuristic figures. The output is deliberately capped (top positions +
/// aggregates) so token cost stays flat no matter how large the portfolio is.
@MainActor
enum AIPortfolioContext {
    /// Per-position row used in the prompt.
    struct PositionRow {
        let symbol: String
        let name: String
        let quantity: Double
        let avgPrice: Double
        let currentPrice: Double
        let value: Double         // preferred currency
        let cost: Double          // preferred currency
        let pnl: Double
        let pnlPercent: Double
        let weightPercent: Double // share of total absolute value
        let type: String
        let isShort: Bool
        let leverage: Double
    }

    struct Output {
        /// Human + model readable context text (used as system prompt body).
        let contextText: String
        /// Live total value in the preferred currency.
        let totalValue: Double
        let totalCost: Double
        let totalPnl: Double
        let totalPnlPercent: Double
        let dayChange: Double
        let dayChangePercent: Double
        /// Positions in prompt, top-weighted, capped.
        let topPositions: [PositionRow]
    }

    /// Renders the context used for every provider call. `scope` targets the
    /// combined portfolio, one portfolio, or a watchlist; performance periods
    /// reuse the session cache when a `PortfolioViewModel` is available.
    /// Durable notes from the workspace folder (`ai-context.md`) are appended so
    /// the assistant remembers them across sessions.
    static func build(storageService: StorageService,
                      stockService: StockService,
                      scope: AIReviewScope,
                      viewModel: PortfolioViewModel?) -> Output {
        switch scope {
        case .allPortfolios:
            return buildPortfolio(storageService: storageService, stockService: stockService,
                                  portfolios: storageService.portfolios, viewModel: viewModel, label: nil)
        case .portfolio(let id):
            let p = storageService.portfolios.filter { $0.id == id }
            return buildPortfolio(storageService: storageService, stockService: stockService,
                                  portfolios: p, viewModel: viewModel, label: p.first?.name)
        case .watchlist(let id):
            return buildWatchlist(storageService: storageService, stockService: stockService,
                                  watchlistID: id)
        }
    }

    private static func buildPortfolio(storageService: StorageService,
                                       stockService: StockService,
                                       portfolios: [Portfolio],
                                       viewModel: PortfolioViewModel?,
                                       label: String?) -> Output {

        let inputs = PortfolioValuation.resolveInputs(for: portfolios, stockService: stockService, storageService: storageService)
        let totals = PortfolioValuation.totals(inputs)

        // Per-position rows using the exact same math as the overview.
        var rows: [PositionRow] = []
        var bySymbol: [String: (value: Double, cost: Double)] = [:]
        for input in inputs {
            let holding = input.holding
            let quote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()]
            let price = input.price
            let isJpFund = input.isJapaneseFund
            let scale = isJpFund ? 10000.0 : 1.0
            let lev = holding.effectiveLeverage
            let qty = holding.quantity
            let value = price.isFinite ? (price / scale) * qty * lev * input.rate : 0
            let cost = holding.hasKnownCostBasis ? (holding.avgPrice / scale) * qty * lev * input.costRate : 0
            let pnl = (holding.hasKnownCostBasis && price.isFinite) ? (value - cost) : 0

            let q = quote ?? StockQuote(
                symbol: holding.symbol, name: holding.symbol,
                price: .nan, change: 0, changePercent: 0,
                currency: stockService.detectedCurrency(for: holding.symbol)
            )

            // Aggregated-value weight (short baskets produce negative values;
            // weight is a share of absolute value).
            bySymbol[holding.symbol, default: (0, 0)].value += value
            bySymbol[holding.symbol, default: (0, 0)].cost += cost

            rows.append(PositionRow(
                symbol: holding.symbol,
                name: q.isJapaneseFund ? q.displayName : (q.name.isEmpty ? holding.symbol : q.name),
                quantity: qty,
                avgPrice: holding.avgPrice / scale,
                currentPrice: price / scale,
                value: value,
                cost: cost,
                pnl: pnl,
                pnlPercent: abs(cost) >= 0.01 ? (pnl / abs(cost)) * 100 : 0,
                weightPercent: 0, // filled below after total known
                type: storageService.type(for: holding.symbol),
                isShort: holding.isShort,
                leverage: lev
            ))
        }

        let totalAbsValue = rows.reduce(0) { $0 + abs($1.value) }
        for i in rows.indices {
            rows[i] = PositionRow(
                symbol: rows[i].symbol, name: rows[i].name, quantity: rows[i].quantity,
                avgPrice: rows[i].avgPrice, currentPrice: rows[i].currentPrice,
                value: rows[i].value, cost: rows[i].cost, pnl: rows[i].pnl,
                pnlPercent: rows[i].pnlPercent,
                weightPercent: totalAbsValue > 1e-9 ? (abs(rows[i].value) / totalAbsValue) * 100 : 0,
                type: rows[i].type, isShort: rows[i].isShort, leverage: rows[i].leverage
            )
        }
        // Cap the positions sent to the model so token cost doesn't scale with
        // portfolio size; the tail is folded into the aggregate line.
        let top = rows.sorted { abs($0.value) > abs($1.value) }
        let topPositions = Array(top.prefix(10))

        // Today change (regular session only, per project rules).
        let todayInputs = storageService.portfolios.flatMap(\.holdings).compactMap { holding -> TodayPerformance.Input? in
            guard let liveQuote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()] else { return nil }
            return TodayPerformance.Input(
                holding: holding,
                regularPrice: liveQuote.price,
                previousClose: liveQuote.previousClose,
                rate: stockService.rate(from: stockService.detectedCurrency(for: holding.symbol))
            )
        }
        let today = TodayPerformance.totals(todayInputs)

        // Performance matrix: reuse the session cache when a view model exists,
        // otherwise compute once via the same cached path.
        var perfPct: [(period: String, portfolio: Double?, spx: Double?)] = []
        if let vm = viewModel, let cached = vm.cachedPerformance {
            for period in PortfolioOverview.PerformancePeriod.allCases {
                perfPct.append((period.rawValue, cached.portfolio[period] ?? nil, cached.spx[period] ?? nil))
            }
        } else if !portfolios.isEmpty {
            let hs = portfolios.flatMap { $0.holdings }
            let inception = hs.compactMap(\.purchaseDate).min()
            for period in PortfolioOverview.PerformancePeriod.allCases {
                perfPct.append((period.rawValue,
                                PortfolioViewModel.portfolioPerformance(for: period, holdings: hs, stockService: stockService, inception: inception),
                                PortfolioViewModel.spxPerformance(for: period, stockService: stockService)))
            }
        }

        let pnlPct = abs(totals.cost) >= 0.01 ? (totals.pnl / abs(totals.cost)) * 100 : 0
        let ret = Output(
            contextText: self.renderText(portfolios: portfolios, totals: totals, pnlPct: pnlPct,
                                         today: today, topPositions: topPositions, perfPct: perfPct,
                                         currency: storageService.preferredCurrency,
                                         storage: storageService, stockService: stockService),
            totalValue: totals.value,
            totalCost: totals.cost,
            totalPnl: totals.pnl,
            totalPnlPercent: pnlPct,
            dayChange: today.gain,
            dayChangePercent: today.percent,
            topPositions: topPositions
        )
        return ret
    }

    private static func buildWatchlist(storageService: StorageService,
                                       stockService: StockService,
                                       watchlistID: UUID) -> Output {
        let wl = storageService.watchlists.first { $0.id == watchlistID }
        let symbols = wl?.symbols ?? []
        let sym = StorageService.currencySymbol(for: storageService.preferredCurrency)
        let fmtValue = { (v: Double) -> String in StorageService.formatNumber(v, decimals: storageService.amountDecimals) }
        let fmtPct = { (v: Double) -> String in String(format: "%+.\(storageService.percentDecimals)f%%", v) }

        var lines: [String] = []
        lines.append("You are reviewing a StockDeck watchlist. Current UI language: \(storageService.appLanguage).")
        lines.append("Preferred currency: \(storageService.preferredCurrency) (\(sym)).")
        lines.append("")
        lines.append("WATCHLIST: \(wl?.name ?? "Untitled")")
        if symbols.isEmpty {
            lines.append("This watchlist is empty.")
        } else {
            lines.append("Symbols (quotes from the regular session only):")
            for symbol in symbols {
                guard let q = stockService.quotes[symbol] ?? stockService.quotes[symbol.uppercased()] else {
                    lines.append(" - \(symbol): no quote available yet")
                    continue
                }
                let rate = stockService.rate(from: stockService.detectedCurrency(for: symbol))
                let converted = q.price.isFinite ? q.price * rate : .nan
                lines.append(" - \(symbol) (\(q.name.isEmpty ? symbol : q.name)): price=\(sym)\(fmtValue(converted)) today=\(fmtPct(q.changePercent))")
            }
        }
        lines.append("")

        // SPX reference for context (only when data exists; never guess).
        let spx = PortfolioViewModel.spxPerformance(for: .m1, stockService: stockService)
        if spx != nil {
            lines.append("S&P 500 1M: \(fmtPct(spx ?? 0))")
        }
        lines.append("")

        lines.append("INSTRUCTIONS")
        lines.append("Answer about the watchlist using ONLY this context and the user's questions. Be honest: if a quote is missing, say it's unavailable rather than inventing one. Do not recommend specific trades with certainty — this is not regulated financial advice.")
        if let notes = storageService.aiWorkspaceContextText() {
            lines.append("")
            lines.append("WORKSPACE NOTES (durable user memory — always present, never ask for them again):")
            lines.append(notes)
        }
        lines.append("")
        lines.append("SAVING TO WORKSPACE: If the user asks you to save, remember, or take note of something, you CAN persist it. Reply with the normal text, then append exactly one block on its own lines:")
        lines.append("[SAVE_TO_WORKSPACE]")
        lines.append("the durable note, written so it reads well standalone")
        lines.append("[/SAVE_TO_WORKSPACE]")
        lines.append("The app stores that block's content in the workspace ai-context.md and it will be visible to you in all future conversations. Never wrap the marker in code fences and never put anything else between the marker lines.")
        return Output(
            contextText: lines.joined(separator: "\n"),
            totalValue: 0, totalCost: 0, totalPnl: 0, totalPnlPercent: 0,
            dayChange: 0, dayChangePercent: 0,
            topPositions: []
        )
    }

    private static func renderText(portfolios: [Portfolio],
                                   totals: (value: Double, cost: Double, pnl: Double),
                                   pnlPct: Double,
                                   today: (gain: Double, percent: Double),
                                   topPositions: [PositionRow],
                                   perfPct: [(period: String, portfolio: Double?, spx: Double?)],
                                   currency: String,
                                   storage: StorageService,
                                   stockService: StockService) -> String {
        let sym = StorageService.currencySymbol(for: currency)
        let fmtValue = { (v: Double) -> String in StorageService.formatNumber(v, decimals: storage.amountDecimals) }
        let fmtPct = { (v: Double) -> String in String(format: "%+.\(storage.percentDecimals)f%%", v) }

        var lines: [String] = []
        lines.append("You are reviewing a StockDeck user portfolio. Current UI language: \(storage.appLanguage).")
        lines.append("Preferred currency: \(currency) (\(sym)).")
        lines.append("")
        lines.append("PORTFOLIO SUMMARY")
        if portfolios.isEmpty {
            lines.append("The user has no portfolios yet.")
        } else {
            let names = portfolios.map(\.name).joined(separator: ", ")
            lines.append("Portfolios: \(names)")
            lines.append("Total value: \(sym)\(fmtValue(totals.value))")
            lines.append("Total cost basis: \(sym)\(fmtValue(totals.cost))")
            lines.append("Total P&L: \(sym)\(fmtValue(totals.pnl)) (\(fmtPct(pnlPct)))")
            lines.append("Today (regular session): \(sym)\(fmtValue(today.gain)) (\(fmtPct(today.percent)))")
        }
        lines.append("")

        if !topPositions.isEmpty {
            lines.append("TOP POSITIONS (by market value; 'value/cost/pnl' in \(currency)):")
            for p in topPositions {
                var item = "\(p.symbol) (\(p.name)): qty=\(String(format: "%.4g", p.quantity)) avg=\(fmtValue(p.avgPrice)) price=\(fmtValue(p.currentPrice))"
                item += " value=\(sym)\(fmtValue(p.value)) cost=\(sym)\(fmtValue(p.cost)) pnl=\(sym)\(fmtValue(p.pnl)) (\(fmtPct(p.pnlPercent))) weight=\(String(format: "%.1f%%", p.weightPercent))"
                if p.isShort { item += " [SHORT]" }
                if p.leverage > 1 { item += " [\(Int(p.leverage))x]"}
                item += " type=\(p.type)"
                lines.append(" - \(item)")
            }
        }
        lines.append("")

        if !perfPct.isEmpty {
            let hasAny = perfPct.contains { $0.portfolio != nil || $0.spx != nil }
            if hasAny {
                lines.append("PERFORMANCE (portfolio vs S&P 500; '-' means insufficient history — never guess):")
                for p in perfPct {
                    let pf = p.portfolio.map { fmtPct($0) } ?? "-"
                    let sp = p.spx.map { fmtPct($0) } ?? "-"
                    lines.append(" \(p.period): portfolio=\(pf)  spx=\(sp)")
                }
            }
        }
        lines.append("")

        if let profile = storage.investorProfile {
            lines.append(profile.promptContextText(preferredCurrency: currency))
            lines.append("")
        }

        lines.append("INSTRUCTIONS")
        lines.append("Answer about the user's portfolio using ONLY this context and the user's questions. Be honest: if a figure is '-', say the history is insufficient rather than inventing one. Do not recommend specific trades with certainty — this is not regulated financial advice. When asked to review health, structure the reply with clear short sections and a concise 'Next steps' list.")
        if storage.investorProfile != nil {
            lines.append("When evaluating portfolio health, asset allocation, and risk, always tailor your analysis and actionable suggestions to the user's age, risk tolerance, and financial goals from their profile.")
        }
        if let notes = storage.aiWorkspaceContextText() {
            lines.append("")
            lines.append("WORKSPACE NOTES (durable user memory — always present, never ask for them again):")
            lines.append(notes)
        }
        lines.append("")
        lines.append("SAVING TO WORKSPACE: If the user asks you to save, remember, or take note of something (a preference, a plan, a fact, a summary), you CAN persist it. Reply with the normal text, then append exactly one block on its own lines:")
        lines.append("[SAVE_TO_WORKSPACE]")
        lines.append("the durable note, written so it reads well standalone")
        lines.append("[/SAVE_TO_WORKSPACE]")
        lines.append("The app stores that block's content in the workspace ai-context.md and it will be visible to you in all future conversations. Never wrap the marker in code fences and never put anything else between the marker lines.")
        return lines.joined(separator: "\n")
    }
}