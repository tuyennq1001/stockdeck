import Foundation
import WebKit

/// Headless WebKit fetcher that renders JavaScript-heavy or WAF-protected pages (CloudFront, Cloudflare, AWS WAF, etc.)
/// on macOS's native WebKit engine to extract hydrated HTML for Reader Mode.
@MainActor
public final class HeadlessWebKitFetcher {
    public static let shared = HeadlessWebKitFetcher()

    private init() {}

    public struct Result: Sendable {
        public let html: String
        public let finalURL: String?

        public init(html: String, finalURL: String?) {
            self.html = html
            self.finalURL = finalURL
        }
    }

    /// Loads the web page in an offscreen `WKWebView`, allows JavaScript, WAF challenges, and redirects to run,
    /// and extracts the hydrated DOM outerHTML as soon as substantive article paragraphs are present in the DOM.
    public func fetchHTML(url: URL, timeout: TimeInterval = 12.0) async -> Result? {
        let session = SingleFetchSession()
        return await session.fetch(url: url, timeout: timeout)
    }
}

@MainActor
private final class SingleFetchSession: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<HeadlessWebKitFetcher.Result?, Never>?
    private var webView: WKWebView?
    private var pollWorkItem: DispatchWorkItem?
    private var timeoutWorkItem: DispatchWorkItem?
    private var initialURL: URL?
    private var didFinishCurrentNavigation = false
    private var isCompleted = false

    func fetch(url: URL, timeout: TimeInterval) async -> HeadlessWebKitFetcher.Result? {
        self.initialURL = url
        return await withCheckedContinuation { cont in
            self.continuation = cont

            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let preferences = WKPreferences()
            preferences.javaScriptCanOpenWindowsAutomatically = false
            config.preferences = preferences

            // 1280x900 viewport ensures responsive desktop layout is rendered rather than throttled 0x0
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
            wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
            self.webView = wv
            wv.navigationDelegate = self

            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            wv.load(request)

            // Begin polling DOM readiness so we can extract as soon as article text arrives,
            // without waiting 10+ seconds for 400+ third-party ad iframes to finish onload.
            scheduleNextPoll(delay: 0.4)

            // Safety timeout guard: extract whatever DOM is available before closing
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.handleTimeout()
            }
            self.timeoutWorkItem = timeoutItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        }
    }

    private func scheduleNextPoll(delay: TimeInterval) {
        guard !isCompleted else { return }
        pollWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pollDOMReadiness()
        }
        pollWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func pollDOMReadiness() {
        guard !isCompleted, let wv = webView else { return }

        // If still on Google News redirect/interstitial, keep waiting for redirect
        if let host = wv.url?.host, host.contains("news.google.com") {
            scheduleNextPoll(delay: 0.35)
            return
        }

        let currentURL = wv.url?.absoluteString
        let isAboutScheme = initialURL?.scheme == "about"

        wv.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") { [weak self] result, _ in
            guard let self, !self.isCompleted else { return }

            if let html = result as? String, !html.isEmpty {
                if isAboutScheme {
                    self.finish(with: HeadlessWebKitFetcher.Result(html: html, finalURL: currentURL))
                    return
                }

                let source = currentURL ?? self.initialURL?.absoluteString ?? ""
                let parsed = ArticleCrawlerService.parseHTML(
                    html,
                    sourceURL: source,
                    finalURL: currentURL
                )

                // Complete immediately once at least 2 substantive article paragraphs are extracted
                // (or 1 paragraph if main navigation has already finished)
                if parsed.paragraphs.count >= 2 || (parsed.paragraphs.count == 1 && self.didFinishCurrentNavigation) {
                    self.finish(with: HeadlessWebKitFetcher.Result(html: html, finalURL: currentURL))
                    return
                }
            }

            self.scheduleNextPoll(delay: 0.35)
        }
    }

    private func handleTimeout() {
        guard !isCompleted else { return }
        guard let wv = webView else {
            finish(with: nil)
            return
        }
        let currentURL = wv.url?.absoluteString
        wv.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") { [weak self] result, _ in
            guard let self, !self.isCompleted else { return }
            if let html = result as? String, !html.isEmpty {
                self.finish(with: HeadlessWebKitFetcher.Result(html: html, finalURL: currentURL))
            } else {
                self.finish(with: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        didFinishCurrentNavigation = false
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Trigger a poll shortly after main document commits to DOM
        scheduleNextPoll(delay: 0.25)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let host = webView.url?.host, host.contains("news.google.com") {
            return
        }
        didFinishCurrentNavigation = true
        scheduleNextPoll(delay: 0.2)
    }

    private func finish(with result: HeadlessWebKitFetcher.Result?) {
        guard !isCompleted else { return }
        isCompleted = true
        pollWorkItem?.cancel()
        pollWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: result)
        }
    }
}
