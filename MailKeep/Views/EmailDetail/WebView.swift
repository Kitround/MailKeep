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
                // Completion runs on the main thread. Si la compilation échoue, on charge
                // une version dont les sources distantes sont neutralisées plutôt que le
                // HTML d'origine : sans règles, celui-ci allait chercher chaque pixel de
                // suivi — exactement ce que le blocage existe pour empêcher.
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

        /// Repli sans WebKit : réécrit `src="http…"` / `srcset` en `about:blank`, pour que
        /// rien ne parte sur le réseau si les règles de blocage n'ont pas pu être compilées.
        private static func neutralizingRemoteSources(in html: String) -> String {
            html.replacingOccurrences(
                of: #"(src|srcset)\s*=\s*["']\s*https?://[^"']*["']"#,
                with: "$1=\"about:blank\"",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Block external navigation — open clicked links in the browser; deny any
        // other remote navigation (e.g. <meta http-equiv="refresh"> redirects).
        /// Seuls ces schémas sont transmis au système sur clic. Un mail peut contenir
        /// n'importe quel lien : `file://`, `smb://` ou un schéma applicatif ouvriraient
        /// une ressource locale ou une autre app d'un simple clic.
        private static let openableSchemes: Set<String> = ["http", "https", "mailto"]

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if let scheme = url.scheme?.lowercased(), Self.openableSchemes.contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else if let scheme = action.request.url?.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
