import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Wrap in basic styling for readability
        let wrapped = """
        <html><head>
        <meta charset="UTF-8">
        <meta name="color-scheme" content="light dark">
        <style>
          body { font-family: -apple-system, sans-serif; font-size: 14px;
                 margin: 16px; line-height: 1.5; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
          a { color: #007AFF; }
          pre, code { white-space: pre-wrap; }
        </style>
        </head><body>\(html)</body></html>
        """
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // Block external navigation — open links in browser instead
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
