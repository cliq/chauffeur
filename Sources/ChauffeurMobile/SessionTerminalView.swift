import SwiftUI
import UIKit
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient
import ChauffeurTerminalInterface
import ChauffeurTerminalTesting

/// 03 / Terminal + session tabs, with 03b (connection lost) as a banner. Taking control is immediate:
/// the other side loses input but the session keeps running, so there is nothing worth confirming.
///
/// The key bar sits below the surface and the view does not ignore the keyboard safe area, so the
/// surface shrinks when the keyboard appears and the engine reports the new cell size itself.
struct SessionTerminalView: View {
    var model: MobileAppModel

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            Divider()

            if let sessionID = model.selectedTab {
                let adapter = model.adapter(for: sessionID)
                let controller = model.terminals[sessionID]

                banner(for: sessionID, controller: controller)

                TerminalSurface(adapter: adapter)
                    .id(sessionID)
                    .overlay(alignment: .topLeading) {
                        if let fake = adapter as? FakeTerminalEngineAdapter {
                            FakeTerminalScreen(text: fake.screenText)
                        }
                    }
                    .opacity(isInputEnabled(controller) ? 1 : 0.6)
                    .accessibilityIdentifier("terminal-surface")
                Divider()
                KeyAccessoryBar(adapter: adapter)
                    .disabled(!isInputEnabled(controller))
            } else {
                ContentUnavailableView {
                    Label("No open tabs", systemImage: "rectangle.on.rectangle.slash")
                } description: {
                    Text("Open a session from the list or start a new tab.")
                } actions: {
                    Button("New tab") { newTab() }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(projectName)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Take control here", systemImage: "hand.raised") {
                        takeControl()
                    }
                    .disabled(model.selectedTab == nil || !model.isConnected)
                    if let sessionID = model.selectedTab {
                        Button("Progress", systemImage: "chart.bar.xaxis") {
                            model.path.append(.progress(sessionID: sessionID))
                        }
                        .accessibilityIdentifier("terminal-progress")
                        Button("Close tab", systemImage: "xmark.rectangle") {
                            model.closeTab(sessionID)
                        }
                    }
                }
            }
        }
        .task(id: model.selectedTab) {
            await model.attachSelectedTerminalIfNeeded()
        }
    }

    private func takeControl() {
        guard let sessionID = model.selectedTab else { return }
        Task { await model.takeControl(of: sessionID) }
    }

    @ViewBuilder
    private func banner(for sessionID: UUID, controller: RemoteSessionController?) -> some View {
        if !model.isConnected {
            StatusBanner(
                title: "Disconnected · Last screen, not live",
                message: connectionMessage,
                actionTitle: model.isConnecting ? "Reconnecting…" : "Reconnect to same session",
                actionDisabled: model.isConnecting
            ) {
                Task { await model.retryTerminal(sessionID) }
            }
        } else if let controller {
            switch controller.state {
            case .controlLost(let message):
                StatusBanner(
                    title: "Terminal is in use on another device",
                    message: "\(message) Input is disabled here until you take control.",
                    actionTitle: "Take control"
                ) {
                    takeControl()
                }
            case .disconnected(let message):
                StatusBanner(
                    title: "Terminal detached",
                    message: "\(message) The session can continue on your Mac.",
                    actionTitle: "Reconnect"
                ) {
                    Task { await model.retryTerminal(sessionID) }
                }
            case .ended:
                StatusBanner(
                    title: "Session ended",
                    message: "The process exited on your Mac. Close this tab or launch a new session.",
                    actionTitle: "Close tab"
                ) {
                    model.closeTab(sessionID)
                }
            case .idle:
                StatusBanner(
                    title: "Not attached",
                    message: "This tab is not showing the live terminal yet.",
                    actionTitle: "Attach"
                ) {
                    Task { await model.retryTerminal(sessionID) }
                }
            case .attaching:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Attaching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            case .idle, .attached:
                EmptyView()
            }
        }
    }

    private var connectionMessage: String {
        if case .unavailable(let message) = model.connectionState {
            return "\(message) Input is disabled."
        }
        return "Mac unreachable. Input is disabled. The session can continue on your Mac. Check Wi-Fi and that the Mac is awake."
    }

    private func isInputEnabled(_ controller: RemoteSessionController?) -> Bool {
        guard model.isConnected, let controller else { return false }
        if case .attached = controller.state { return true }
        return false
    }

    private var projectName: String {
        guard let session = model.selectedSession, let inventory = model.inventory else { return "Terminal" }
        return inventory.project(session.projectID)?.name ?? "Terminal"
    }

    private var subtitle: String {
        guard let session = model.selectedSession else { return "No tab selected" }
        let control: String
        switch model.selectedTab.flatMap({ model.terminals[$0] })?.state {
        case .attached: control = "Controlled here"
        case .controlLost: control = "Controlled elsewhere"
        case .attaching: control = "Attaching"
        case .disconnected: control = "Detached"
        case .ended: control = "Ended"
        case .idle, .none: control = model.isConnected ? "Not attached" : "Disconnected"
        }
        let branch = session.branch ?? URL(fileURLWithPath: session.checkoutPath).lastPathComponent
        return "\(branch) · \(control)"
    }

    private func newTab() {
        if let session = model.selectedSession {
            model.path.append(.launch(model.location(of: session)))
        } else {
            model.path.append(.location(projectID: nil))
        }
    }
}

/// Open tabs for this device. `+` skips Location and opens Launch with the current checkout.
private struct TabStrip: View {
    var model: MobileAppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.openTabs, id: \.self) { sessionID in
                        let session = model.session(sessionID)
                        TabChip(
                            title: session?.title ?? "Session",
                            kind: session?.kind,
                            isSelected: model.selectedTab == sessionID,
                            onSelect: { model.selectTab(sessionID) },
                            onClose: { model.closeTab(sessionID) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)

            Button("New tab", systemImage: "plus") {
                if let session = model.selectedSession {
                    model.path.append(.launch(model.location(of: session)))
                } else {
                    model.path.append(.location(projectID: nil))
                }
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12)
            .disabled(!model.isConnected)
            .accessibilityIdentifier("terminal-new-tab")
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

private struct TabChip: View {
    let title: String
    let kind: RemoteSessionKind?
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if let kind {
                        Text(kind.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Button("Close tab", systemImage: "xmark") {
                onClose()
            }
            .labelStyle(.iconOnly)
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color(uiColor: .systemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.secondary.opacity(0.4) : Color.clear)
        }
    }
}

/// Hosts the engine's view without the app knowing which engine is behind it. The engine view
/// fills the container, so every bounds change (rotation, keyboard, key bar) reaches the engine.
struct TerminalSurface: UIViewRepresentable {
    let adapter: any TerminalEngineAdapter

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let engineView = adapter.makeView()
        engineView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(engineView)
        NSLayoutConstraint.activate([
            engineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            engineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            engineView.topAnchor.constraint(equalTo: container.topAnchor),
            engineView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 240)
    }
}

/// The fake engine renders nothing; show what it was fed so the flow is legible without SwiftTerm.
private struct FakeTerminalScreen: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? "Fake terminal engine — no output yet." : text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.green)
            .padding(12)
            .allowsHitTesting(false)
    }
}

/// Keys the software keyboard lacks. Encodings come from the adapter, never hard-coded here.
/// Ctrl is a one-shot modifier: tap it, then a letter from the row it reveals.
struct KeyAccessoryBar: View {
    static let controlLetters: [Character] = ["c", "d", "z", "l", "r", "a", "e", "u", "k"]

    let adapter: any TerminalEngineAdapter
    @State private var controlArmed = false
    @State private var keyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if controlArmed {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Text("Ctrl +")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        ForEach(Self.controlLetters, id: \.self) { letter in
                            key(String(letter).uppercased(), label: "Control \(letter)") {
                                adapter.sendKey(.control(letter))
                                controlArmed = false
                            }
                            .accessibilityIdentifier("key-ctrl-\(letter)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                Divider()
            }
            HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    key("Esc") { adapter.sendKey(.escape) }
                        .accessibilityIdentifier("key-esc")
                    key("Tab") { adapter.sendKey(.tab) }
                        .accessibilityIdentifier("key-tab")
                    Button {
                        controlArmed.toggle()
                    } label: {
                        Text("Ctrl")
                            .font(.system(.subheadline, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(controlArmed ? .accentColor : nil)
                    .accessibilityLabel(controlArmed ? "Control, armed" : "Control")
                    .accessibilityIdentifier("key-ctrl")
                    key("←", label: "Left") { adapter.sendKey(.left) }
                        .accessibilityIdentifier("key-left")
                    key("↑", label: "Up") { adapter.sendKey(.up) }
                        .accessibilityIdentifier("key-up")
                    key("↓", label: "Down") { adapter.sendKey(.down) }
                        .accessibilityIdentifier("key-down")
                    key("→", label: "Right") { adapter.sendKey(.right) }
                        .accessibilityIdentifier("key-right")
                    key("Paste") {
                        if let text = UIPasteboard.general.string {
                            adapter.paste(text)
                        }
                    }
                    .accessibilityIdentifier("key-paste")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            Divider().frame(height: 24)
            // Pinned outside the scrolling row so it is always reachable. Hiding the keyboard gives the
            // terminal the full screen; a tap on the terminal or this button brings it back.
            Button {
                if keyboardVisible {
                    adapter.makeView().endEditing(true)
                } else {
                    adapter.focus()
                }
            } label: {
                Image(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Show keyboard")
            .accessibilityIdentifier("key-keyboard")
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private func key(_ title: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label ?? title)
    }
}

private struct StatusBanner: View {
    let title: String
    let message: String
    let actionTitle: String
    var actionDisabled = false
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(actionDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.yellow.opacity(0.15))
        .accessibilityIdentifier("terminal-banner")
    }
}

#Preview("Connected") {
    NavigationStack {
        SessionTerminalView(model: .preview())
    }
}

#Preview("Disconnected") {
    NavigationStack {
        SessionTerminalView(model: .preview(connected: false))
    }
}
