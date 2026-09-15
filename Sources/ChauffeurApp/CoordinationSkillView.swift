import SwiftUI
import AppKit
import ChauffeurCore

struct CoordinationSkillView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let preset: AgentPreset
    @State private var installation: SkillInstallation?
    @State private var document = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var confirmRemoval = false
    @State private var showGuidance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chauffeur Coordination Skill").font(.title2)
            Text(preset.name).font(.headline)
            Text("Optional guidance for discovering peers, checking messages, delegating work, and reporting results. Sessions get their current project and group from Chauffeur.")
            Text("Installation applies to every session and preset using this configuration directory, including sessions started outside Chauffeur.")
                .font(.callout).foregroundStyle(.secondary)
            if let installation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(installation.message).accessibilityIdentifier("skill-installation-status")
                    Text("Bundled version: \(installation.bundledVersion)" + (installation.installedVersion.map { " · Installed: \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(installation.path).font(.caption).textSelection(.enabled)
                    Button("Show in Finder") { reveal(installation.path) }
                }
            } else { Text("Checking installation…").foregroundStyle(.secondary) }
            DisclosureGroup("Review bundled guidance", isExpanded: $showGuidance) {
                ScrollView { Text(document).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    .frame(height: 200).background(.quaternary.opacity(0.3))
            }
            Text("CLI settings and managed policies can disable skills. Restart the CLI if its skills list does not refresh. Guidance already loaded in a conversation remains in that conversation after removal.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Refresh") { Task { await refresh() } }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if let installation {
                    switch installation.state {
                    case .notInstalled:
                        Button("Install Skill") { change("installSkill") }.disabled(busy).accessibilityIdentifier("install-coordination-skill")
                    case .installed, .updateAvailable:
                        Button("Remove Skill…", role: .destructive) { confirmRemoval = true }.disabled(busy).accessibilityIdentifier("remove-coordination-skill")
                        if installation.state == .updateAvailable { Button("Update Skill") { change("installSkill") }.disabled(busy) }
                    case .conflict, .unavailable: EmptyView()
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }.padding(24).frame(width: 640)
            .task { await refresh() }
            .alert("Remove the Chauffeur skill?", isPresented: $confirmRemoval) {
                Button("Cancel", role: .cancel) {}
                Button("Remove Skill", role: .destructive) { change("removeSkill") }
            } message: { Text("Remove the unchanged Chauffeur guidance from \(installation?.path ?? preset.configurationDirectory). This affects every preset using this directory.") }
    }

    private func refresh() async {
        busy = true; failure = nil; defer { busy = false }
        do {
            installation = try await model.call("skillStatus", .object(["presetID": .string(preset.id.uuidString)])).decode(SkillInstallation.self)
            document = try await model.call("skillDocument").string ?? ""
        } catch { failure = error.localizedDescription }
    }
    private func change(_ method: String) {
        guard let installation, !busy else { return }
        busy = true; failure = nil
        Task {
            defer { busy = false }
            do {
                self.installation = try await model.call(method, .object(["presetID": .string(preset.id.uuidString), "revision": .string(installation.revision)])).decode(SkillInstallation.self)
            } catch {
                failure = error.localizedDescription
                self.installation = try? await model.call("skillStatus", .object(["presetID": .string(preset.id.uuidString)])).decode(SkillInstallation.self)
            }
        }
    }
    private func reveal(_ path: String) {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
