import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let html: String
    var allowRemoteContent: Bool = false

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
        context.coordinator.render(html: wrapped, allowRemote: allowRemoteContent, in: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // Compiled once for the whole app: blocks every http(s) subresource
        // (tracking pixels, remote images) unless the user opts in.
        private static var cachedBlockList: WKContentRuleList?
        private static let blockRulesJSON = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """

        func render(html: String, allowRemote: Bool, in webView: WKWebView) {
            if allowRemote {
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.loadHTMLString(html, baseURL: nil)
                return
            }
            if let list = Self.cachedBlockList {
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(list)
                webView.loadHTMLString(html, baseURL: nil)
                return
            }
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "mailkeep-block-remote",
                encodedContentRuleList: Self.blockRulesJSON
            ) { list, _ in
                // Completion runs on the main thread. If compilation fails, load a version
                // with its remote sources neutralised rather than the original HTML: with no
                // rules, that one fetched every tracking pixel — exactly what the blocking
                // exists to prevent.
                if let list {
                    Self.cachedBlockList = list
                    webView.configuration.userContentController.removeAllContentRuleLists()
                    webView.configuration.userContentController.add(list)
                    webView.loadHTMLString(html, baseURL: nil)
                } else {
                    webView.loadHTMLString(Self.neutralizingRemoteSources(in: html), baseURL: nil)
                }
            }
        }

        /// WebKit-free fallback: rewrites `src="http…"` / `srcset` to `about:blank`, so
        /// nothing reaches the network when the blocking rules could not be compiled.
        private static func neutralizingRemoteSources(in html: String) -> String {
            html.replacingOccurrences(
                of: #"(src|srcset)\s*=\s*["']\s*https?://[^"']*["']"#,
                with: "$1=\"about:blank\"",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Block external navigation — open clicked links in the browser; deny any
        // other remote navigation (e.g. <meta http-equiv="refresh"> redirects).
        /// Only these schemes are handed to the system on a click. A message can carry any
        /// link at all: `file://`, `smb://` or an app scheme would open a local resource or
        /// another app from a single click.
        private static let openableSchemes: Set<String> = ["http", "https", "mailto"]

        /// The only schemes a navigation may actually load. `loadHTMLString(_:baseURL: nil)`
        /// lands on `about:blank`, and inline `data:` URIs come from our own cid: inlining —
        /// nothing else has any business navigating here. It used to be the reverse, a deny
        /// list holding only http(s): a `<meta http-equiv="refresh">` or a redirect pointing
        /// at `file://`, `smb://` or an app's own scheme fell through to `.allow`.
        private static let loadableSchemes: Set<String> = ["about", "data"]

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased()
            if action.navigationType == .linkActivated, let url = action.request.url {
                if let scheme, Self.openableSchemes.contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else if let scheme, !Self.loadableSchemes.contains(scheme) {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
