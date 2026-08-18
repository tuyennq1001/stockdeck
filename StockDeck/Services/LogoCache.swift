#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

/// Downloads and caches official company logos for Vietnamese-listed symbols.
///
/// FMP (used by `SymbolLogo` for the rest of the world) has no Vietnam
/// coverage, so a symbol like "MBB" resolves to the US iShares MBS ETF logo.
/// Vietnamese logos are instead resolved from TradingView's public symbol
/// pages (HOSE/HNX/UPCOM) and cached as PNG files under
/// `Application Support/StockDeck/Logos/`.
@MainActor
final class LogoCache {
    static let shared = LogoCache()

    private var cacheDir: URL?
    private var inflight: Set<String> = []

    private init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("StockDeck/Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDir = dir
    }

    /// Local PNG URL if a logo has already been cached for this symbol.
    func cachedURL(for symbol: String) -> URL? {
        guard let dir = cacheDir else { return nil }
        let file = dir.appendingPathComponent("\(symbol.uppercased()).png")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Ensures a real logo is cached for a Vietnamese symbol. Safe to call
    /// repeatedly — it short-circuits once the PNG exists and deduplicates
    /// concurrent requests for the same symbol.
    func ensureLogo(for symbol: String) async {
        let key = symbol.uppercased()
        guard StockService.isVietnameseStock(key) else { return }
        if cachedURL(for: key) != nil { return }
        guard let dir = cacheDir else { return }

        if inflight.contains(key) { return }
        inflight.insert(key)
        defer { inflight.remove(key) }

        let storedExchange = StorageService.shared.exchange(for: key).uppercased()
        let markets: [String] = ["HOSE", "HNX", "UPCOM"].contains(storedExchange)
            ? [storedExchange]
            : ["HOSE", "HNX", "UPCOM"]

        for market in markets {
            guard let svgURL = await resolveSVGURL(symbol: key, market: market),
                  let svg = await download(url: svgURL, referer: "https://www.tradingview.com/symbols/\(market)-\(key)/"),
                  let png = renderPNG(svgData: svg, size: 128) else { continue }
            let file = dir.appendingPathComponent("\(key).png")
            try? png.write(to: file)
            return
        }
    }

    /// Fetches the TradingView symbol page for (market, symbol) and extracts
    /// the first company-logo asset URL (`...--big.svg`), skipping generic
    /// `source/` and `country/` placeholders.
    private func resolveSVGURL(symbol: String, market: String) async -> URL? {
        guard let page = URL(string: "https://www.tradingview.com/symbols/\(market)-\(symbol)/"),
              let html = await downloadString(url: page) else { return nil }
        let pattern = #"s3-symbol-logo\.tradingview\.com/([^"]*--big\.svg)"#
        guard let range = html.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(html[range])
        let clean = match
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean) else { return nil }
        return url.absoluteString.hasPrefix("https://s3-symbol-logo.tradingview.com/") ? url : nil
    }

    private func downloadString(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func download(url: URL, referer: String) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return data
    }

    /// Renders an SVG logo into a square PNG bitmap.
    private func renderPNG(svgData: Data, size: CGFloat) -> Data? {
        #if os(macOS)
        guard let source = NSImage(data: svgData) else { return nil }
        let canvas = NSImage(size: NSSize(width: size, height: size))
        canvas.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: NSSize(width: size, height: size))
        source.draw(in: rect, from: NSRect(origin: .zero, size: source.size), operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
        #else
        guard let source = UIImage(data: svgData) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        }
        return img.pngData()
        #endif
    }

    private let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
}
