import SwiftUI
import WebKit
import AppKit

/// An article link to be opened in the in-app browser window.
struct InAppWebLink: Identifiable {
    let id = UUID()
    let url: URL
}

/// WKWebView wrapped for SwiftUI. Talks to its coordinator to surface page
/// title and back/forward state to the surrounding popup.
struct InAppWebView: NSViewRepresentable {
    let startURL: URL

    @Binding var title: String
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    /// Weak-ish reference to the WKWebView so header bar buttons can drive it.
    @Binding var controller: WKWebView?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        DispatchQueue.main.async { controller = nsView }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: InAppWebView

        init(_ parent: InAppWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.title = webView.title ?? ""
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.title = webView.title ?? ""
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

/// In-app article browser: a WKWebView popup with a navigation bar (back,
/// forward, reload, open in external browser, close) shown as a native sheet.
struct InAppWebViewPopup: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var pageTitle = ""
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var webController: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.hairline)
            InAppWebView(startURL: url,
                         title: $pageTitle,
                         canGoBack: $canGoBack,
                         canGoForward: $canGoForward,
                         isLoading: $isLoading,
                         controller: $webController)
        }
        .background(DS.ground)
        .frame(width: 800, height: 620)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", enabled: canGoBack) { webController?.goBack() }
                .help("Back")
            navButton("chevron.right", enabled: canGoForward) { webController?.goForward() }
                .help("Forward")
            navButton("arrow.clockwise") { webController?.reload() }
                .help("Reload")

            Text(pageTitle.isEmpty ? url.host ?? url.absoluteString : pageTitle)
                .font(DS.body).foregroundStyle(DS.inkSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)

            if isLoading { DSSpinner(size: 11) }

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "safari").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.inkSecondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open in external browser")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.inkSecondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(DS.card)
    }

    private func navButton(_ icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? DS.inkSecondary : DS.hairline)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(!enabled)
    }
}