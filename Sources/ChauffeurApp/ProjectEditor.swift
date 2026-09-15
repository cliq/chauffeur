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
                if project == nil {
                    Button("Start Empty") { folders = []; candidates = []; selected = []; discoveryFolder = nil; discoveryErrors = [] }
                        .disabled(discovering)
                }
            }
            if discovering {
                HStack { ProgressView().controlSize(.small); Text("Finding repositories…"); Spacer(); Button("Cancel Discovery") { discoveryTask?.cancel() } }
            }
            folderList
            if !candidates.isEmpty {
                HStack {
                    Text("\(selected.count) of \(candidates.count) selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Selected Repositories") {
                        for candidate in candidates where selected.contains(candidate.id) { add(candidate) }
                        candidates = []; selected = []
                    }.disabled(selected.isEmpty)
                }
            }
            Text("Folder registration preserves repositories and worktrees on disk. Running sessions retain their launch paths and presets.").font(.caption).foregroundStyle(.secondary)
            if !discoveryErrors.isEmpty { Text(discoveryErrors.map { $0.errorDescription ?? $0.message }.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).lineLimit(4) }
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(saving ? "Saving…" : "Save Project") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || setID == nil || discovering) }
        }.padding(24).frame(width: 720)
            .onAppear { name = project?.name ?? ""; setID = project?.presetSetID ?? model.presetSets.first(where: { !$0.archived })?.id; folders = project?.folders ?? []; discoveryFolder = project?.discoveryFolder; version = model.snapshot.store.projects.first { $0.value.id == project?.id }?.version }
            .onDisappear { discoveryTask?.cancel() }
    }
    private var registeredFolders: [ProjectFolder] { folders.filter(\.registered) }
    private var folderListHeight: CGFloat {
        let sections = (candidates.isEmpty ? 0 : 1) + (registeredFolders.isEmpty ? 0 : 1)
        return min(300, max(120, CGFloat(candidates.count + registeredFolders.count) * 62 + CGFloat(sections) * 32))
    }
    private var folderList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if candidates.isEmpty && registeredFolders.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                        Text("No folders added").fontWeight(.medium)
                        Text("Choose a parent folder to find repositories, add a folder, or save an empty project.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(20)
                }
                if !candidates.isEmpty {
                    folderHeading("Repositories found", count: candidates.count)
                    ForEach(candidates) { candidate in
                        Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } })) {
                            folderLabel(candidate)
                        }.toggleStyle(.checkbox).padding(10)
                        Divider().padding(.leading, 10)
                    }
                }
                if !registeredFolders.isEmpty {
                    folderHeading("Project folders", count: registeredFolders.count)
                    ForEach(registeredFolders) { folder in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                folderLabel(folder).textSelection(.enabled)
                                if !FileManager.default.isReadableFile(atPath: folder.canonicalPath) { Text("Missing or inaccessible").font(.caption).foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Relink…") {
                                if let path = FilePanels.directory(), let index = folders.firstIndex(where: { $0.id == folder.id }) {
                                    folders[index].selectedPath = path; folders[index].canonicalPath = Paths.canonical(path); folders[index].availability = .available
                                }
                            }
                            Button("Remove", role: .destructive) { if let index = folders.firstIndex(where: { $0.id == folder.id }) { folders[index].registered = false } }
                        }.padding(10)
                        Divider().padding(.leading, 10)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
                .background(PersistentScrollbars())
        }.scrollIndicators(.visible)
            .frame(height: folderListHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
    private func folderHeading(_ title: String, count: Int) -> some View {
        HStack { Text(title).fontWeight(.medium); Spacer(); Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
            .font(.caption).padding(.horizontal, 10).padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
    }
    private func folderLabel(_ folder: ProjectFolder) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(folder.name).lineLimit(1)
            Text(folder.selectedPath).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(folder.selectedPath)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
