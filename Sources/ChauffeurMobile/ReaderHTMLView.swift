import SwiftUI
import WebKit

/// Renders markdown with the bundled reader page. A private origin serves the page assets and the
/// current markdown; the web content never receives host paths, credentials, or filesystem access.
struct ReaderHTMLView: UIViewRepresentable {
    let markdown: String
    var onOpenLink: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(markdown: markdown, onOpenLink: onOpenLink) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "chauffeur-reader")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpenLink = onOpenLink
        if view.url == nil {
            coordinator.markdown = markdown
            view.load(URLRequest(url: Coordinator.url))
        } else if coordinator.markdown != markdown {
            coordinator.markdown = markdown
            if coordinator.isLoaded {
                view.evaluateJavaScript("chauffeurReader.rerender()")
            }
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        static let url = URL(string: "chauffeur-reader://doc/index.html")!
        var markdown: String
        var onOpenLink: (String) -> Void
        private(set) var isLoaded = false
        init(markdown: String, onOpenLink: @escaping (String) -> Void) {
            self.markdown = markdown; self.onOpenLink = onOpenLink
        }

        private static let assets: [String: (resource: String, ext: String, mime: String)] = [
            "/index.html": ("reader", "html", "text/html"),
            "/reader.js": ("reader", "js", "application/javascript"),
            "/reader.css": ("reader", "css", "text/css"),
            "/markdown-it.min.js": ("markdown-it.min", "js", "application/javascript")
        ]

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, url.host == "doc" else {
                urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
            }
            let data: Data
            let mime: String
            if url.path == "/document.md" {
                data = Data(markdown.utf8); mime = "text/plain"
            } else if let asset = Self.assets[url.path],
                      let fileURL = Bundle.main.url(forResource: asset.resource, withExtension: asset.ext),
                      let bytes = try? Data(contentsOf: fileURL) {
                data = bytes; mime = asset.mime
            } else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            let policy = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-src 'none'"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "\(mime); charset=utf-8", "Cache-Control": "no-store", "Content-Security-Policy": policy
            ])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoaded = true }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.scheme == Self.url.scheme, url.host == "link" {
                let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "to" }?.value
                if let target { onOpenLink(target) }
                decisionHandler(.cancel); return
            }
            var stripped = URLComponents(url: url, resolvingAgainstBaseURL: false)
            stripped?.fragment = nil
            decisionHandler(stripped?.url == Self.url ? .allow : .cancel)
        }
    }
}
