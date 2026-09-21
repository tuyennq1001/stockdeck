import SwiftUI
import WebKit

/// Maps StockDeck symbols (Yahoo / Binance style) onto TradingView's widget
/// format so the embedded Advanced Chart can resolve them. Returns `nil` when
/// no reliable mapping exists — e.g. Japanese mutual funds (投資信託), which
/// TradingView does not list at all — and the caller falls back to the native
/// chart. Everything here is best-effort data, never fabricated: unknown tickers
/// map to `nil` rather than a guess.
enum TradingViewSymbol {
    static func map(_ symbol: String, exchange: String) -> String? {
        let s = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = s.uppercased()

        // Japanese assets (mutual funds, stocks, ETFs, indices):
        // TradingView's embedded widget displays "This symbol is only available on TradingView"
        // for all TSE/Japanese symbols due to exchange licensing restrictions.
        // Therefore, return nil so the UI cleanly hides TradingView and uses Native Line Chart.
        if StockService.isJapaneseMutualFund(s) ||
           StockService.isJapaneseStock(s) ||
           upper.hasSuffix(".T") ||
           upper.hasSuffix(".JP") ||
           ["TSE", "TYO", "JPX", "TOKYO"].contains(exchange.uppercased()) ||
           ["^N225", "N225", "NIKKEI", "NIKKEI225", "^TOPX", "TOPX", "TOPIX"].contains(upper) {
            return nil
        }

        // Vietnamese assets (stocks, indices):
        // TradingView's embedded widget displays "This symbol is only available on TradingView"
        // for all HOSE/HNX/UPCOM symbols due to exchange licensing restrictions.
        // Therefore, return nil so the UI cleanly hides TradingView and uses Native Line Chart.
        if StockService.isVietnameseStock(s, exchange: exchange) ||
           upper.hasSuffix(".VN") ||
           upper.hasSuffix(".HM") ||
           upper.hasSuffix(".HN") ||
           ["HOSE", "HNX", "UPCOM"].contains(exchange.uppercased()) ||
           ["^VNINDEX.VN", "^VNINDEX", "VNINDEX", "VNINDEX.VN", "VN-INDEX", "^VN30", "VN30", "^HNX", "^HNXINDEX", "HNX", "HNXINDEX", "^UPCOM"].contains(upper) {
            return nil
        }

        // Market indices with '^' prefix (e.g. ^GSPC, ^DJI, ^IXIC).
        if s.hasPrefix("^") {
            let indices: [String: String] = [
                "^GSPC": "INDEX:SPX",
                "^DJI": "INDEX:DJI",
                "^IXIC": "INDEX:IXIC",
                "^KS11": "INDEX:KOSPI",
                "^KOSDAQ": "INDEX:KOSDAQ",
                "^HSI": "INDEX:HSI",
                "^STI": "INDEX:STI",
                "^AXJO": "INDEX:AS51",
                "^NSEI": "INDEX:NIFTY",
                "^BSESN": "INDEX:SENSEX",
                "^FTSE": "INDEX:UKX",
                "^GDAXI": "INDEX:GDAXI",
                "^FCHI": "INDEX:FCHI",
                "^TWII": "INDEX:TWII",
                "^VIX": "CBOE:VIX",
            ]
            return indices[upper]
        }

        // Common index aliases without '^' prefix (e.g. SPX, DJI).
        let indexAliases: [String: String] = [
            "SPX": "INDEX:SPX",
            "GSPC": "INDEX:SPX",
            "DJI": "INDEX:DJI",
            "IXIC": "INDEX:IXIC",
            "KS11": "INDEX:KOSPI",
            "KOSPI": "INDEX:KOSPI",
            "KOSDAQ": "INDEX:KOSDAQ",
            "HSI": "INDEX:HSI",
        ]
        if let mapped = indexAliases[upper] {
            return mapped
        }

        // FX pairs: "USDJPY=X" → "FX:USDJPY".
        if upper.hasSuffix("=X") {
            let base = String(upper.dropLast(2))
            return base.count == 6 && base.allSatisfy({ $0.isLetter }) ? "FX:\(base)" : nil
        }

        // Futures & commodities: "GC=F" → "TVC:GOLD", index futures → continuous contracts.
        if upper.hasSuffix("=F") {
            let futures: [String: String] = [
                "ES": "CME:ES1!",
                "MES": "CME:MES1!",
                "NQ": "CME:NQ1!",
                "MNQ": "CME:MNQ1!",
                "YM": "CBOT:YM1!",
                "MYM": "CBOT:MYM1!",
                "RTY": "CME:RTY1!",
                "M2K": "CME:M2K1!",
                "CL": "TVC:CL",
                "BZ": "TVC:BRENT",
                "GC": "TVC:GOLD",
                "SI": "TVC:SILVER",
                "HG": "TVC:COPPER",
                "NG": "TVC:NG",
            ]
            return futures[String(upper.dropLast(2))]
        }

        // Crypto: Binance native pairs resolve straight to BINANCE; Yahoo-style
        // "BTC-USD" resolves to Coinbase's CRYPTO feed.
        if StorageService.isBinanceNativePair(upper) {
            return "BINANCE:\(upper)"
        }
        if upper.hasSuffix("-USD") {
            let base = String(upper.dropLast(4))
            if StorageService.isStandardCryptoSymbol(base) || BinanceStablecoin.isUSDPegged(base) {
                return "CRYPTO:\(base)USD"
            }
        }

        // Hong Kong: "0700.HK" → "HKEX:0700".
        if upper.hasSuffix(".HK") {
            return "HKEX:\(String(upper.dropLast(3)))"
        }

        // London: "RR.L" → "LSE:RR".
        if upper.hasSuffix(".L") {
            return "LSE:\(String(upper.dropLast(2)))"
        }

        // Germany: "VWCE.DE" → "XETR:VWCE".
        if upper.hasSuffix(".DE") {
            return "XETR:\(String(upper.dropLast(3)))"
        }

        // US equities & ETFs. Use the resolved exchange when known, otherwise pass
        // the bare ticker and let TradingView resolve the primary listing.
        let cleanUS = upper.hasSuffix(".US") ? String(upper.dropLast(3)) : upper
        let exch = exchange.uppercased()
        if ["NASDAQ", "NYSE", "NYSEARCA", "AMEX", "ARCA", "BATS", "PCX"].contains(exch) {
            return "\(exch):\(cleanUS)"
        }
        return cleanUS
    }
}

struct TradingViewChartView: NSViewRepresentable {
    let tvSymbol: String
    /// "dark" | "light".
    let theme: String
    /// TradingView resolution: "D", "W", or "M". Reloads the widget when it changes.
    var interval: String = "D"

    final class Coordinator {
        var symbol: String = ""
        var theme: String = ""
        var interval: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = makeWebView()
        context.coordinator.symbol = tvSymbol
        context.coordinator.theme = theme
        context.coordinator.interval = interval
        loadChart(into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // WKWebView is opaque by default; keep the card background showing through.
        nsView.setValue(false, forKey: "drawsBackground")
        if context.coordinator.symbol != tvSymbol || context.coordinator.theme != theme || context.coordinator.interval != interval {
            context.coordinator.symbol = tvSymbol
            context.coordinator.theme = theme
            context.coordinator.interval = interval
            loadChart(into: nsView)
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Inject favorite intervals into localStorage before TradingView boots
        config.userContentController.addUserScript(favoriteIntervalsScript)
        config.userContentController.addUserScript(intervalHideScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.hasHorizontalScroller = false
        return webView
    }

    /// Injects default favorite intervals (1D, 1W, 1M) directly into TradingView's
    /// localStorage at document start, overriding any old/intraday defaults.
    private var favoriteIntervalsScript: WKUserScript {
        let source = #"""
        (function() {
            try {
                const favs = JSON.stringify(["1D", "1W", "1M"]);
                const keys = [
                    "IntervalWidget.quicks",
                    "tradingview.IntervalWidget.quicks",
                    "IntervalWidget.favorite",
                    "tradingview.IntervalWidget.favorite",
                    "IntervalWidget.favorites",
                    "tradingview.IntervalWidget.favorites",
                    "tradingview.chart.favorite.intervals",
                    "tradingview.favorite.intervals",
                    "tradingview.favoriteIntervals",
                    "chart.favorite.intervals",
                    "tv.favoriteIntervals",
                    "Intervals.favorites"
                ];
                for (let i = 0; i < keys.length; i++) {
                    localStorage.setItem(keys[i], favs);
                }
            } catch(e) {}
        })();
        """#
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// CSS that hides unwanted intraday timeframe buttons (1m, 30m, 60m) and removes
    /// opaque/grey background boxes behind the chart legend (OHLC, indicators, volume).
    private var intervalHideScript: WKUserScript {
        let css = #"""
        button[data-value="1"],
        button[data-value="30"],
        button[data-value="60"] { display: none !important; }
        [class*="legend"], [class*="legend"] *,
        [class*="sources-"], [class*="sources-"] *,
        [class*="values-"], [class*="values-"] * {
            background-color: transparent !important;
            background: transparent !important;
        }
        """#
        let source = #"const s = document.createElement('style'); s.id = 'stockdeck-interval-hide'; s.textContent = `"# + css + #"`; document.head.appendChild(s);"#
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    private func loadChart(into webView: WKWebView) {
        let config = Self.configJSON(symbol: tvSymbol, theme: theme, interval: interval)
        // Build the URL by hand: URLComponents would re-encode the already
        // percent-encoded fragment and turn "%7B" into "%257B".
        let fragment = config.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? config
        let urlString = "https://s.tradingview.com/embed-widget/advanced-chart/?locale=en#" + fragment
        guard let url = URL(string: urlString) else { return }
        webView.load(URLRequest(url: url))
    }

    /// JSON configuration embedded in the URL fragment (`#…`) — the exact format
    /// TradingView's own "get widget" iframe embed produces. `autosize: true`
    /// makes the chart fill whatever size the web view ends up at.
    ///
    /// The widget has no persistence of its own: every load starts fresh, so the
    /// studies below are the default set that always comes back on a reload.
    /// Tweak this list to preselect which indicators appear by default (each
    /// entry is a TradingView basic-study id, e.g. "RSI@tv-basicstudies").
    ///
    /// Note the id suffix is `@tv-basicstudies` (no `-1`); the `-1` variant
    /// silently loads nothing. Community scripts (e.g. "6 Moving Averages &
    /// Ichimoku & Bollinger Band by Theo Park") canNOT be attached through the
    /// embed widget — only built-in studies are allowed. Volume is not listed
    /// because TradingView draws a volume pane by default.
    static let defaultStudies: [String] = [
        "MAExp@tv-basicstudies",
        "RSI@tv-basicstudies",
    ]

    private static func configJSON(symbol: String, theme: String, interval: String) -> String {
        let studies = defaultStudies.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "autosize": true,
          "symbol": "\(symbol)",
          "interval": "\(interval)",
          "timezone": "Etc/UTC",
          "theme": "\(theme)",
          "style": "1",
          "locale": "en",
          "backgroundColor": "rgba(0, 0, 0, 0)",
          "gridColor": "rgba(0, 0, 0, 0)",
          "allow_symbol_change": false,
          "calendar": false,
          "hide_top_toolbar": false,
          "hide_side_toolbar": true,
          "hide_legend": false,
          "withdateranges": false,
          "studies": [\(studies)],
          "support_host": "https://www.tradingview.com",
          "favorites": {
            "intervals": ["1D", "1W", "1M"]
          },
          "overrides": {
            "paneProperties.legendProperties.showBackground": false,
            "paneProperties.legendProperties.backgroundTransparency": 100
          }
        }
        """
    }
}