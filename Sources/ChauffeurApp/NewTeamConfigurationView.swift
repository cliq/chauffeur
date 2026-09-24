import SwiftUI
import ChauffeurCore

/// All choices stay in the form until Add Team is pressed. Preview is read-only.
struct NewTeamConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var pair: SetupAgentPair
    @Binding var directory: String
    @Binding var busy: Bool
    @Binding var failure: String?
    let teamName: String
    @State private var preview: CopyPreview?
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Create a new \(pair.kind.displayName) config \(pair.kind == .opencode ? "layer" : "folder")", isOn: Binding(
                get: { pair.choice == .create },
                set: { creating in
                    pair.choice = creating ? .create : .existing
                    if creating && directory.isEmpty {
                        directory = "\(home)/\(pair.kind.defaultHomeFolder)-\(Paths.slug(teamName.isEmpty ? "team" : teamName))"
                    }
                    pair.destinationPath = (directory as NSString).expandingTildeInPath
                    invalidate()
                }
            )).toggleStyle(.checkbox).accessibilityIdentifier("team.create-\(pair.kind.rawValue)")
            if pair.choice == .create {
                GroupBox {
                    ConfigurationCopyOptions(pair: $pair, home: home, preview: preview,
                        invalidate: invalidate, requestPreview: requestPreview)
                }
                Text(CopyCategory.supported(for: pair.kind).isEmpty
                     ? "The folder is created when you add the team."
                     : "Settings are copied when you add the team. Source folders stay unchanged; credentials aren't copied. Sign in to new configurations when you first launch an agent.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: directory) { _, value in
            pair.destinationPath = (value as NSString).expandingTildeInPath
            invalidate()
        }
    }

    private func invalidate() { preview = nil; pair.previewID = nil }

    private func requestPreview() {
        guard !busy else { return }
        busy = true; failure = nil
        pair.destinationPath = (directory as NSString).expandingTildeInPath
        if let source = pair.sourcePath { pair.sourcePath = (source as NSString).expandingTildeInPath }
        Task {
            defer { busy = false }
            do {
                let result = try await model.call("previewTeamConfiguration", .object(["pair": try .from(pair)]))
                    .decode(CopyPreview.self)
                preview = result; pair.previewID = result.id
            } catch { invalidate(); failure = error.localizedDescription }
        }
    }
}
