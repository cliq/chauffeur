import SwiftUI
import ChauffeurCore

struct ProjectEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project?
    let completion: (UUID) -> Void
    @State private var name = ""
    @State private var setID: UUID?
    @State private var folders: [ProjectFolder] = []
    @State private var discoveryFolder: String?
    @State private var candidates: [ProjectFolder] = []
    @State private var selected = Set<UUID>()
    @State private var discoveryErrors: [ChauffeurError] = []
    @State private var discoveryTask: Task<RepositoryDiscovery.Result, Never>?
    @State private var discovering = false
    @State private var saving = false
    @State private var failure: String?
    @State private var version: String?
    init(project: Project? = nil, completion: @escaping (UUID) -> Void) { self.project = project; self.completion = completion }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project == nil ? "Create Project" : "Project Settings").font(.title2)
            Form {
                TextField("Project name", text: $name)
                Picker("Preset set", selection: $setID) {
                    Text("Choose a preset set").tag(UUID?.none)
                    ForEach(model.presetSets.filter { !$0.archived || $0.id == setID }) { set in Text(set.name).tag(Optional(set.id)) }
                }
            }
            Text("Folders").font(.headline)
            HStack {
                Button("Choose Parent Folder…") { chooseParent() }.disabled(discovering)
                Button("Add Folder…") { if let path = FilePanels.directory() { add(ProjectFolder(path: path)) } }
                if project == nil { Button("Start Empty") { folders = []; candidates = []; discoveryFolder = nil } }
            }
            if discovering {
                HStack { ProgressView().controlSize(.small); Text("Finding repositories…"); Spacer(); Button("Cancel Discovery") { discoveryTask?.cancel() } }
            }
            if !candidates.isEmpty {
                Text("Select repositories to register").font(.subheadline)
                List(candidates) { candidate in
                    Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } })) {
                        VStack(alignment: .leading) { Text(candidate.name); Text(candidate.selectedPath).font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(height: 140)
                Button("Add Selected Repositories") {
                    for candidate in candidates where selected.contains(candidate.id) { add(candidate) }
                    candidates = []; selected = []
                }.disabled(selected.isEmpty)
            }
            List {
                ForEach(folders.filter(\.registered)) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.name)
                            Text(folder.selectedPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if !FileManager.default.isReadableFile(atPath: folder.canonicalPath) { Text("Missing or inaccessible").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button("Relink…") {
                            if let path = FilePanels.directory(), let index = folders.firstIndex(where: { $0.id == folder.id }) {
                                folders[index].selectedPath = path; folders[index].canonicalPath = Paths.canonical(path); folders[index].availability = .available
                            }
                        }
                        Button("Remove", role: .destructive) { if let index = folders.firstIndex(where: { $0.id == folder.id }) { folders[index].registered = false } }
                    }.padding(.vertical, 3)
                }
            }.frame(minHeight: 100, maxHeight: 200)
            Text("Folder registration preserves repositories and worktrees on disk. Running sessions retain their launch paths and presets.").font(.caption).foregroundStyle(.secondary)
            if !discoveryErrors.isEmpty { Text(discoveryErrors.map { $0.errorDescription ?? $0.message }.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).lineLimit(4) }
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(saving ? "Saving…" : "Save Project") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || setID == nil || discovering) }
        }.padding(24).frame(width: 680)
            .onAppear { name = project?.name ?? ""; setID = project?.presetSetID ?? model.presetSets.first(where: { !$0.archived })?.id; folders = project?.folders ?? []; discoveryFolder = project?.discoveryFolder; version = model.snapshot.store.projects.first { $0.value.id == project?.id }?.version }
            .onDisappear { discoveryTask?.cancel() }
    }
    private func add(_ folder: ProjectFolder) {
        if let index = folders.firstIndex(where: { $0.canonicalPath == folder.canonicalPath }) { folders[index].registered = true }
        else { folders.append(folder) }
    }
    private func chooseParent() {
        guard let path = FilePanels.directory(title: "Choose a parent folder to find repositories") else { return }
        discoveryFolder = path; discovering = true; candidates = []; selected = []; discoveryErrors = []
        let scan = Task.detached { RepositoryDiscovery.scan(parent: path, isCancelled: { Task<Never, Never>.isCancelled }) }
        discoveryTask = scan
        Task { let result = await scan.value; discovering = false; discoveryTask = nil; candidates = result.folders; discoveryErrors = result.errors }
    }
    private func save() {
        guard let setID else { return }
        var value = project ?? Project(name: name, presetSetID: setID)
        value.name = name; value.presetSetID = setID; value.folders = folders; value.discoveryFolder = discoveryFolder; value.updatedAt = Date()
        saving = true; failure = nil
        Task {
            do { try await model.save("saveProject", value, version: version); completion(value.id); dismiss() }
            catch { failure = error.localizedDescription; saving = false }
        }
    }
}

struct GroupsEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var groups: [AgentGroup] = []
    @State private var newName = ""
    @State private var version: String?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Groups").font(.title2)
            Text("Each group has its own communication boundary. Sessions keep their group for their entire lifetime.").foregroundStyle(.secondary)
            List {
                ForEach($groups) { $group in
                    HStack {
                        TextField("Group name", text: $group.name)
                        if group.isDefault { Text("Default").foregroundStyle(.secondary) }
                        else { Button(group.archived ? "Reopen" : "Archive") { group.archived.toggle(); group.updatedAt = Date() } }
                    }
                }
            }.frame(height: 220)
            HStack { TextField("New group name", text: $newName); Button("Add Group") { groups.append(AgentGroup(name: newName)); newName = "" }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty) }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Groups") {
                    var value = project; value.groups = groups; value.updatedAt = Date()
                    Task { do { try await model.save("saveProject", value, version: version); dismiss() } catch { failure = error.localizedDescription } }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
            .onAppear { groups = project.groups; version = model.snapshot.store.projects.first { $0.value.id == project.id }?.version }
    }
}
