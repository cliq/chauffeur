import SwiftUI
import WebKit
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

struct SessionProgressView: View {
    var model: MobileAppModel
    let sessionID: UUID
    @Environment(\.scenePhase) private var scenePhase
    @State private var panel: SessionProgressPanel?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if !model.isConnected {
                Label("Disconnected · Last known progress", systemImage: "wifi.slash")
                    .font(.caption).padding().frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.15))
            } else if let error, panel != nil {
                Text("Last known progress · \(error)").font(.caption).padding().foregroundStyle(.secondary)
            }
            if let panel {
                if panel.html != nil {
                    ProgressHTMLView(panel: panel)
                        .accessibilityIdentifier("progress-html")
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(panel.summary.title).font(.title2.bold())
                        Text(panel.summary.now)
                        if let percent = panel.summary.percentComplete {
                            ProgressView(value: Double(percent), total: 100) { Text("\(percent)% complete") }
                        }
                        Text(panel.htmlError ?? "No HTML panel registered.").foregroundStyle(.secondary)
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else if let error {
                ContentUnavailableView("Progress unavailable", systemImage: "chart.bar.xaxis", description: Text(error))
            } else if model.isConnected {
                ProgressView("Loading progress…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Not connected", systemImage: "wifi.slash", description: Text("Reconnect to your Mac to view this session’s progress."))
            }
        }
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(!model.isConnected)
            }
        }
        .task(id: model.isConnected && scenePhase == .active) {
            guard model.isConnected, scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func refresh() async {
        guard let host = model.session else { return }
        do {
            let received = try await host.sessionProgress(sessionID: sessionID)
            guard !Task.isCancelled else { return }
            panel = received; error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? RemoteClientError)?.userMessage ?? error.localizedDescription
        }
    }
}

/// A private origin serves only the registered HTML and synthesized companion data.
/// The web content never receives host paths, device credentials, or filesystem access.
struct ProgressHTMLView: UIViewRepresentable {
    let panel: SessionProgressPanel

    func makeCoordinator() -> Coordinator { Coordinator(panel: panel) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "chauffeur-progress")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let changed = context.coordinator.panel.html != panel.html
        context.coordinator.panel = panel
        if view.url == nil || changed { view.load(URLRequest(url: Coordinator.url)) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        static let url = URL(string: "chauffeur-progress://panel/index.html")!
        var panel: SessionProgressPanel
        init(panel: SessionProgressPanel) { self.panel = panel }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, url.host == "panel" else {
                urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
            }
            let content: String
            let mime: String
            switch url.path {
            case "/index.html": content = panel.html ?? ""; mime = "text/html"
            case "/progress.json": content = panel.json; mime = "application/json"
            case "/progress.js": content = "window.IMPLEMENTATION_PROGRESS = \(panel.json);"; mime = "application/javascript"
            default: urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            let data = Data(content.utf8)
            let policy = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; font-src data:; base-uri 'none'; form-action 'none'; frame-src 'none'"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "\(mime); charset=utf-8", "Cache-Control": "no-store", "Content-Security-Policy": policy
            ])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == Self.url ? .allow : .cancel)
        }
    }
}
