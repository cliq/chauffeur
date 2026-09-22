import SwiftUI
import WebKit
import ChauffeurCore

struct SessionSidebarView: View {
    let session: Session
    let project: Project
    @State private var showingProgress = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Session panel", selection: $showingProgress) {
                Text("Session Details").tag(false)
                Text("Progress").tag(true)
            }
            .pickerStyle(.segmented).padding(12)
            Divider()
            if showingProgress {
                SessionProgressView(registration: session.progress).id(session.id)
            } else {
                SessionDetailsView(session: session, project: project)
            }
        }
        .background(.background)
        .onChange(of: session.progress, initial: true) { previous, current in
            if previous != current, current != nil { showingProgress = true }
        }
    }
}

private struct LoadedProgress: Sendable {
    let progress: ImplementationProgress
    let htmlURL: URL?
    let htmlModified: Date?
    let warning: String?

    init(_ registration: ProgressRegistration) throws {
        progress = try ProgressFiles.read(jsonPath: registration.jsonPath)
        if let path = registration.htmlPath {
            do {
                let url = try ProgressFiles.htmlURL(path)
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                htmlURL = url
                htmlModified = modified
                warning = nil
            } catch {
                htmlURL = nil; htmlModified = nil
                warning = "The HTML panel is unavailable. Showing its JSON progress."
            }
        } else { htmlURL = nil; htmlModified = nil; warning = nil }
    }
}

struct SessionProgressView: View {
    let registration: ProgressRegistration?
    @State private var loaded: LoadedProgress?
    @State private var failure: String?
    @State private var webFailure: String?

    var body: some View {
        VStack(spacing: 0) {
            if let registration {
                if let loaded {
                    if let message = failure ?? loaded.warning ?? webFailure {
                        Text(message).font(.caption).foregroundStyle(.orange).padding(12)
                    }
                    if webFailure != nil { Button("Retry HTML") { webFailure = nil }.padding(.bottom, 8) }
                    if let url = loaded.htmlURL, failure == nil, webFailure == nil {
                        ProgressWebView(url: url, modified: loaded.htmlModified, failure: $webFailure)
                    } else {
                        nativeProgress(loaded.progress)
                    }
                    HStack {
                        Button("Open in Browser") {
                            if let path = registration.htmlPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        }.disabled(loaded.htmlURL == nil)
                        Spacer()
                        Button("Reveal JSON") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: registration.jsonPath)])
                        }
                    }.font(.caption).padding(12)
                } else if let failure {
                    ContentUnavailableView("Progress unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView("Loading progress…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("No progress panel", systemImage: "list.bullet.rectangle", description: Text("Ask the agent to create an implementation progress panel and register it with Chauffeur."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: registration) {
            loaded = nil; failure = nil; webFailure = nil
            guard let registration else { return }
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { Result { try LoadedProgress(registration) } }.value
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let value):
                    if value.htmlURL != loaded?.htmlURL || value.htmlModified != loaded?.htmlModified { webFailure = nil }
                    loaded = value; failure = nil
                case .failure: failure = "Cannot read the registered progress JSON. Retrying automatically."
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func nativeProgress(_ progress: ImplementationProgress) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(progress.title).font(.headline)
                if !progress.subtitle.isEmpty { Text(progress.subtitle).font(.caption).foregroundStyle(.secondary) }
                Text(progress.now)
                ProgressView(value: Double(progress.percentComplete), total: 100) { Text("\(progress.percentComplete)%") }
                ForEach(Array(progress.phases.enumerated()), id: \.offset) { _, phase in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(phase.title, systemImage: symbol(phase.state))
                        if !phase.detail.isEmpty { Text(phase.detail).font(.caption).foregroundStyle(.secondary) }
                        if phase.state != .pending {
                            ForEach(Array(phase.steps.enumerated()), id: \.offset) { _, step in
                                Label(step.title, systemImage: symbol(step.state)).font(.caption).padding(.leading, 12)
                            }
                        }
                    }
                }
                Text("Updated \(progress.updated.formatted())").font(.caption).foregroundStyle(.secondary)
                if Date().timeIntervalSince(progress.updated) > 20 * 60 {
                    Text("No progress update in over 20 minutes").font(.caption).foregroundStyle(.orange)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(_ state: ImplementationProgress.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .active: "circle.inset.filled"
        case .pending: "circle"
        case .blocked: "exclamationmark.circle.fill"
        }
    }
}

private struct ProgressWebView: NSViewRepresentable {
    let url: URL
    let modified: Date?
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.failure = $failure
        guard coordinator.url != url || coordinator.modified != modified else { return }
        coordinator.url = url; coordinator.modified = modified
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var url: URL?
        var modified: Date?
        var failure: Binding<String?>?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let target = navigationAction.request.url
            decisionHandler(target?.isFileURL == true && target?.standardizedFileURL.path == url?.standardizedFileURL.path ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            failure?.wrappedValue = "The HTML panel could not load. Showing its JSON progress."
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            failure?.wrappedValue = "The HTML panel could not load. Showing its JSON progress."
        }
    }
}
