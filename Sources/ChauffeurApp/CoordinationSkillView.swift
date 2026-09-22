import SwiftUI
import AppKit
import ChauffeurCore

struct CoordinationSkillView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let preset: AgentPreset
    @State private var installations: [SkillInstallation] = []
    @State private var documents: [String: String] = [:]
    @State private var busy = false
    @State private var failure: String?
    @State private var expanded = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chauffeur Skills").font(.title2)
            Text(preset.name).font(.headline)
            Text("Coordination and orchestration skills are linked automatically and update with Chauffeur.")
            Text("Codex uses the shared ~/.agents/skills directory. Claude uses each team’s configured home. Skills are also available to sessions started outside Chauffeur.")
                .font(.callout).foregroundStyle(.secondary)

            if installations.isEmpty {
                Text("Checking installations…").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(installations) { installation in skillRow(installation) }
                    }
                }.frame(maxHeight: 480)
            }

            Text("CLI settings and managed policies can disable skills. Restart the CLI if its skills list does not refresh. Existing conversations may retain guidance they already loaded.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Refresh") { Task { await refresh() } }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }
        .padding(24).frame(width: 680)
        .task { await refresh() }
    }

    @ViewBuilder private func skillRow(_ installation: SkillInstallation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(installation.displayName).font(.headline)
                    Text(installation.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(installation.state == .installed ? "Linked" : "Needs attention").font(.caption)
            }
            Text(installation.message).accessibilityIdentifier("skill-installation-status-\(installation.name)")
            Text("Bundled: \(installation.bundledVersion)" + (installation.installedVersion.map { " · Installed: \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if !installation.dependencies.isEmpty {
                Text("Includes dependency: \(installation.dependencies.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(installation.path).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Show in Finder") { reveal(installation.path) }.controlSize(.small)
            }
            DisclosureGroup("Review bundled guidance", isExpanded: Binding(
                get: { expanded.contains(installation.name) },
                set: { value in
                    if value { expanded.insert(installation.name); Task { await loadDocument(installation.name) } }
                    else { expanded.remove(installation.name) }
                }
            )) {
                ScrollView {
                    Text(documents[installation.name] ?? "Loading…")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 160).background(.quaternary.opacity(0.3))
            }
        }.padding(12).background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refresh() async {
        busy = true; failure = nil; defer { busy = false }
        do {
            installations = try await model.call("skillStatuses", baseParams).decode([SkillInstallation].self)
        } catch { failure = error.localizedDescription }
    }

    private func loadDocument(_ name: String) async {
        guard documents[name] == nil else { return }
        do {
            documents[name] = try await model.call("skillDocument", .object(["skillName": .string(name)])).string ?? ""
        } catch { failure = error.localizedDescription }
    }

    private var baseParams: JSONValue { .object(baseParamsValues) }
    private var baseParamsValues: [String: JSONValue] {
        ["teamID": .string(preset.setID.uuidString), "presetID": .string(preset.id.uuidString)]
    }

    private func reveal(_ path: String) {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
