import SwiftUI
import ChauffeurCore

struct ProjectEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project?
    let initialFolderPath: String?
    let initialTeamID: UUID?
    let completion: (UUID) -> Void
    @State private var name = ""
    @State private var setID: UUID?
    @State private var folders: [ProjectFolder] = []
    @State private var discoveryFolder: String?
    @State private var candidates: [ProjectFolder] = []
    @State private var candidateTree: [RepositoryDiscovery.Node] = []
    @State private var selected = Set<UUID>()
    @State private var expanded = Set<UUID>()
    @State private var discoveryErrors: [ChauffeurError] = []
    @State private var discoveryTask: Task<RepositoryDiscovery.Result, Never>?
    @State private var discovering = false
    @State private var saving = false
    @State private var failure: String?
    @State private var version: String?
    init(project: Project? = nil, initialFolderPath: String? = nil, initialTeamID: UUID? = nil, completion: @escaping (UUID) -> Void) { self.project = project; self.initialFolderPath = initialFolderPath; self.initialTeamID = initialTeamID; self.completion = completion }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project == nil ? "Create Project" : "Project Settings").font(.title2)
            Form {
                TextField("Project name", text: $name).accessibilityIdentifier("project.name")
                Picker("Team", selection: $setID) {
                    Text("Choose a team").tag(UUID?.none)
                    ForEach(model.presetSets.filter { !$0.archived || $0.id == setID }) { set in Text(set.name).tag(Optional(set.id)) }
                }.accessibilityIdentifier("project.preset-set")
            }
            Text("Folders").font(.headline)
            HStack {
                Button("Choose Parent Folder…") { chooseParent() }.disabled(discovering)
                Button("Add Folder…") { if let path = FilePanels.directory() { add(ProjectFolder(path: path)) } }
                if project == nil {
                    Button("Start Empty") { folders = []; setCandidates([]); discoveryFolder = nil; discoveryErrors = [] }
                        .disabled(discovering)
                }
            }
            if discovering {
                HStack { ProgressView().controlSize(.small); Text("Finding repositories…"); Spacer(); Button("Cancel Discovery") { discoveryTask?.cancel() } }
            }
            folderList
            if !candidates.isEmpty {
                HStack {
                    Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Selected Repositories") {
                        for candidate in candidates where selected.contains(candidate.id) { add(candidate) }
                        setCandidates([])
                    }.disabled(selected.isEmpty)
                }
            }
            Text("Folder registration preserves repositories and worktrees on disk. Running sessions retain their launch paths and agent presets.").font(.caption).foregroundStyle(.secondary)
            if !discoveryErrors.isEmpty { Text(discoveryErrors.map { $0.errorDescription ?? $0.message }.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).lineLimit(4) }
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(saving ? "Saving…" : "Save Project") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || setID == nil || discovering) }
        }.padding(24).frame(width: 720)
            .onAppear { name = project?.name ?? initialFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""; setID = project?.presetSetID ?? initialTeamID.flatMap { id in model.presetSets.contains { $0.id == id } ? id : nil } ?? model.snapshot.store.defaultPresetSet?.id; folders = project?.folders ?? initialFolderPath.map { [ProjectFolder(path: $0)] } ?? []; discoveryFolder = project?.discoveryFolder; version = model.snapshot.store.projects.first { $0.value.id == project?.id }?.version }
            .onDisappear { discoveryTask?.cancel() }
    }
    private var registeredFolders: [ProjectFolder] { folders.filter(\.registered) }
    private var folderListHeight: CGFloat {
        let sections = (candidates.isEmpty ? 0 : 1) + (registeredFolders.isEmpty ? 0 : 1)
        return min(300, max(120, CGFloat(visibleCandidates.count + registeredFolders.count) * 62 + CGFloat(sections) * 32))
    }
    /// Top-level repositories, plus the nested repositories of expanded rows.
    private var visibleCandidates: [(node: RepositoryDiscovery.Node, depth: Int)] {
        func rows(_ nodes: [RepositoryDiscovery.Node], depth: Int) -> [(node: RepositoryDiscovery.Node, depth: Int)] {
            nodes.flatMap { node in [(node, depth)] + (expanded.contains(node.id) ? rows(node.children, depth: depth + 1) : []) }
        }
        return rows(candidateTree, depth: 0)
    }
    private var candidateHeading: String {
        let nested = candidates.count - candidateTree.count
        return nested == 0 ? "Repositories found" : "Repositories found (\(nested) nested)"
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
                    folderHeading(candidateHeading, count: candidateTree.count)
                    ForEach(visibleCandidates, id: \.node.id) { row in
                        candidateRow(row.node, depth: row.depth)
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
                            }.accessibilityIdentifier("project.relink-\(folder.id.uuidString)")
                            Button("Remove", role: .destructive) { if let index = folders.firstIndex(where: { $0.id == folder.id }) { folders[index].registered = false } }.accessibilityIdentifier("project.remove-\(folder.id.uuidString)")
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
    private func candidateRow(_ node: RepositoryDiscovery.Node, depth: Int) -> some View {
        let candidate = node.folder
        return HStack(spacing: 4) {
            if node.children.isEmpty { Color.clear.frame(width: 16, height: 16) }
            else {
                Button {
                    if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
                } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(node.id) ? 90 : 0))
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(expanded.contains(node.id) ? "Hide nested repositories" : "Show \(node.descendantCount) nested repositories")
                    .accessibilityLabel(expanded.contains(node.id) ? "Collapse \(candidate.name)" : "Expand \(candidate.name)")
                    .accessibilityIdentifier("project.candidate-disclosure-\(candidate.name)")
            }
            Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } })) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.name).lineLimit(1)
                        if !node.children.isEmpty && !expanded.contains(node.id) {
                            Text("\(node.descendantCount) nested").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(node.relativePath ?? candidate.selectedPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(candidate.selectedPath)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.checkbox).accessibilityIdentifier("project.candidate-\(candidate.name)")
        }.padding(10).padding(.leading, CGFloat(depth) * 20)
    }
    private func setCandidates(_ folders: [ProjectFolder]) {
        candidates = folders; candidateTree = RepositoryDiscovery.tree(folders); selected = []; expanded = []
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
        discoveryFolder = path; discovering = true; setCandidates([]); discoveryErrors = []
        let scan = Task.detached { RepositoryDiscovery.scan(parent: path, isCancelled: { Task<Never, Never>.isCancelled }) }
        discoveryTask = scan
        Task { let result = await scan.value; discovering = false; discoveryTask = nil; setCandidates(result.folders); discoveryErrors = result.errors }
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
    var onSave: ([AgentGroup]) -> Void = { _ in }
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
                        TextField("Group name", text: $group.name).accessibilityIdentifier("group.name-\(group.id.uuidString)")
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
                    Task { do { try await model.save("saveProject", value, version: version); onSave(groups); dismiss() } catch { failure = error.localizedDescription } }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
            .onAppear { groups = project.groups; version = model.snapshot.store.projects.first { $0.value.id == project.id }?.version }
    }
}
