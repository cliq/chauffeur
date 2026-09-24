import SwiftUI
import ChauffeurCore

struct CopySettingsStep: View {
    @ObservedObject var setup: OnboardingModel
    var body: some View {
        Text("Copy settings").font(.headline)
        Text("Your source folders stay unchanged. Each new configuration signs in separately; credentials aren't copied.").foregroundStyle(.secondary)
        ForEach($setup.draft.teams) { $team in
            ForEach($team.agents) { $pair in
                if pair.choice == .create && pair.operationID == nil {
                    GroupBox("\(team.name) · \(pair.kind.displayName)") {
                        ConfigurationCopyOptions(pair: $pair, home: setup.home,
                            preview: setup.previews[pair.id],
                            invalidate: { setup.previews[pair.id] = nil },
                            requestPreview: { Task { await setup.preview(pair.id) } })
                    }
                }
            }
        }
        if !setup.pairs.contains(where: { $0.choice == .create && $0.operationID == nil }) { Text("No new folders needed. Continue to check sign-in.") }
    }
}

/// Shared copy controls for onboarding and the focused Add Team form.
struct ConfigurationCopyOptions: View {
    @Binding var pair: SetupAgentPair
    let home: String
    let preview: CopyPreview?
    let invalidate: () -> Void
    let requestPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if CopyCategory.supported(for: pair.kind).isEmpty {
                Text("OpenCode loads this folder as an extra configuration layer on top of your global OpenCode configuration, so nothing is copied into it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Start fresh", isOn: Binding(get: { pair.sourcePath == nil }, set: {
                    pair.sourcePath = $0 ? nil : "\(home)/\(pair.kind.defaultHomeFolder)"
                    invalidate()
                }))
                if pair.sourcePath != nil {
                    HStack {
                        TextField("Source folder", text: Binding(get: { pair.sourcePath ?? "" }, set: { pair.sourcePath = $0; invalidate() }))
                        Button("Choose source…") { if let path = FilePanels.directory(title: "Copy settings from", showsHiddenFiles: true) { pair.sourcePath = path; invalidate() } }
                    }
                    ForEach(CopyCategory.allCases.filter { CopyCategory.supported(for: pair.kind).contains($0) }, id: \.self) { category in
                        Toggle(category.setupTitle, isOn: Binding(get: { pair.categories.contains(category) }, set: {
                            if $0 { pair.categories.insert(category) } else { pair.categories.remove(category) }
                            invalidate()
                        })).toggleStyle(.checkbox)
                    }
                    if pair.categories.contains(.history) {
                        Text("Preview to list project folders. Select only the projects to copy.").font(.caption).foregroundStyle(.secondary)
                        if let preview {
                            let projects = preview.availableProjects
                            ForEach(projects, id: \.self) { project in
                                Toggle(URL(fileURLWithPath: project).lastPathComponent, isOn: Binding(get: { pair.projectPaths.contains(project) }, set: {
                                    if $0 { pair.projectPaths.insert(project) } else { pair.projectPaths.remove(project) }
                                    pair.previewID = nil
                                })).toggleStyle(.checkbox).font(.caption)
                            }
                        }
                    }
                }
            }
            Text("New folder: \(pair.destinationPath)").font(.caption).textSelection(.enabled)
            Button("Preview settings") { requestPreview() }.accessibilityIdentifier("onboarding.preview.\(pair.kind.rawValue)")
            if let preview {
                Text("\(preview.entries.count) items · \(ByteCountFormatter.string(fromByteCount: preview.entries.reduce(0) { $0 + $1.size }, countStyle: .file))").font(.caption)
                ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Files to copy") {
                    ForEach(preview.entries, id: \.destinationRelativePath) { entry in Text(entry.destinationRelativePath).font(.caption.monospaced()) }
                }
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
