import SwiftUI
import UIKit
import ChauffeurTerminalInterface
import ChauffeurTerminalTesting

/// 03 / Terminal + session tabs, with 03a (control handoff) as a sheet and 03b (connection lost) as a banner.
struct SessionTerminalView: View {
    var model: MobileAppModel
    @State private var showHandoff = false

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            Divider()

            if !model.connectionState.isConnected {
                StatusBanner(
                    title: "Disconnected · Last screen, not live",
                    message: "Mac unreachable. Input is disabled. The session can continue on your Mac. Check Wi-Fi and that the Mac is awake.",
                    actionTitle: "Reconnect to same session"
                ) {
                    model.reconnect()
                }
            } else if case .controlledElsewhere(let device) = model.controlState {
                StatusBanner(
                    title: "Terminal is attached on \(device)",
                    message: "Input is disabled here until you take control.",
                    actionTitle: "Take control"
                ) {
                    showHandoff = true
                }
            }

            if let sessionID = model.selectedTab {
                let adapter = model.terminalAdapter(for: sessionID)
                TerminalSurface(adapter: adapter)
                    .id(sessionID)
                    .overlay(alignment: .topLeading) {
                        if let fake = adapter as? FakeTerminalEngineAdapter {
                            FakeTerminalScreen(text: fake.screenText)
                        }
                    }
                    .opacity(model.isTerminalInputEnabled ? 1 : 0.6)
                Divider()
                KeyAccessoryBar(adapter: adapter)
                    .disabled(!model.isTerminalInputEnabled)
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
                    Button("Handoff to Mac…", systemImage: "arrow.left.arrow.right") {
                        showHandoff = true
                    }
                    Button("Simulate control lost", systemImage: "hand.raised") {
                        model.controlState = .controlledElsewhere(device: "your Mac")
                    }
                    Button("Simulate disconnect", systemImage: "wifi.slash") {
                        model.disconnect()
                    }
                }
            }
        }
        .sheet(isPresented: $showHandoff) {
            HandoffSheet(sessionTitle: model.selectedSession?.title ?? "this session") {
                model.takeControl()
            }
        }
    }

    private var projectName: String {
        guard let session = model.selectedSession, let inventory = model.inventory else { return "Terminal" }
        return inventory.project(session.projectID)?.name ?? "Terminal"
    }

    private var subtitle: String {
        guard let session = model.selectedSession else { return "No tab selected" }
        let control: String
        switch model.controlState {
        case .controlledHere: control = "Controlled here"
        case .controlledElsewhere(let device): control = "Controlled on \(device)"
        }
        return "\(session.branch) · \(control)"
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
                        if let session = model.session(sessionID) {
                            TabChip(
                                title: session.title,
                                kind: session.kind,
                                isSelected: model.selectedTab == sessionID,
                                onSelect: { model.selectedTab = sessionID },
                                onClose: { model.closeTab(sessionID) }
                            )
                        }
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
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

private struct TabChip: View {
    let title: String
    let kind: SessionKind
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Text(kind.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
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

/// Hosts the engine's view without the app knowing which engine is behind it.
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
}

/// The fake engine renders nothing; show what it was fed so the flow is legible in the scaffold.
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
struct KeyAccessoryBar: View {
    let adapter: any TerminalEngineAdapter

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                key("Esc") { adapter.sendKey(.escape) }
                key("Tab") { adapter.sendKey(.tab) }
                // TODO: Ctrl as a sticky modifier applied to the next typed letter.
                key("^C") { adapter.sendKey(.control("c")) }
                key("←", label: "Left") { adapter.sendKey(.left) }
                key("↑", label: "Up") { adapter.sendKey(.up) }
                key("↓", label: "Down") { adapter.sendKey(.down) }
                key("→", label: "Right") { adapter.sendKey(.right) }
                key("Paste") {
                    if let text = UIPasteboard.general.string {
                        adapter.paste(text)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .secondarySystemBackground))
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.yellow.opacity(0.15))
    }
}

/// 03a / Terminal control sheet.
struct HandoffSheet: View {
    let sessionTitle: String
    var onTakeControl: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Terminal is attached on another device. Take control here?")
                    .font(.title3.weight(.semibold))
                Text("“\(sessionTitle)” is open on your Mac. Its terminal input will pause there while you control it from your phone. The session keeps running.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onTakeControl()
                    dismiss()
                } label: {
                    Text("Take control")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { dismiss() }
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("Control handoff")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

#Preview("Controlled here") {
    NavigationStack {
        SessionTerminalView(model: .preview())
    }
}

#Preview("Control lost") {
    let model = MobileAppModel.preview()
    model.controlState = .controlledElsewhere(device: "your Mac")
    return NavigationStack {
        SessionTerminalView(model: model)
    }
}

#Preview("Disconnected") {
    let model = MobileAppModel.preview()
    model.disconnect()
    return NavigationStack {
        SessionTerminalView(model: model)
    }
}
