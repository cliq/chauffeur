import SwiftUI
import ChauffeurCore

/// Settings that belong to one project folder, such as the script that
/// prepares each worktree Chauffeur creates for it.
struct RepositorySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let folderID: UUID
    @State private var script = ""
    @State private var saving = false
    @State private var failure: String?
    private var folder: ProjectFolder? { model.project(projectID)?.folders.first { $0.id == folderID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Repository Settings").font(.title2)
                if let folder {
                    Text(folder.canonicalPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Worktree Setup Script").font(.headline)
                Text("Runs in each new worktree, before its agent starts.").foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow { Text("$WORKTREE").font(.system(.body, design: .monospaced)); Text("The new worktree (working directory)").foregroundStyle(.secondary) }
                    GridRow { Text("$MAIN_REPO").font(.system(.body, design: .monospaced)); Text("The repository's main checkout").foregroundStyle(.secondary) }
                }.textSelection(.enabled)
                TextEditor(text: $script)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .overlay(alignment: .topLeading) {
                        if script.isEmpty {
                            Text("# e.g. copy keys Git does not track\ncp \"$MAIN_REPO/.env\" .env")
                                .font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("repository-settings.setup-script")
            }
            if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(saving || folder == nil)
                    .accessibilityIdentifier("repository-settings.save")
            }
        }
        .padding(24).frame(width: 560)
        .onAppear { script = folder?.worktreeSetupScript ?? "" }
    }
    private func save() {
        guard var project = model.project(projectID), let index = project.folders.firstIndex(where: { $0.id == folderID }) else { return }
        let version = model.projectVersion(projectID)
        project.folders[index].worktreeSetupScript = script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : script
        project.updatedAt = Date()
        saving = true; failure = nil
        Task {
            do { try await model.saveProject(project, version: version); dismiss() }
            catch { failure = error.localizedDescription; saving = false }
        }
    }
}
