import SwiftUI
import AppKit
import ChauffeurCore

struct RefPicker: View {
    @EnvironmentObject private var model: AppModel
    let projectID: UUID
    let folderID: UUID
    @Binding var selection: String
    @State private var presented = false

    private var label: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where selection.hasPrefix(prefix) {
            return String(selection.dropFirst(prefix.count))
        }
        return selection
    }

    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
            }
        }
        .frame(maxWidth: 230)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Base ref")
        .accessibilityValue(label)
        .accessibilityIdentifier("session.base-ref")
        .help("Choose a branch, tag, or commit to use as the base")
        .popover(isPresented: $presented, arrowEdge: .top) {
            RefPickerPopover(model: model, projectID: projectID, folderID: folderID, selection: selection) {
                selection = $0
                presented = false
            } close: { presented = false }
        }
        .onChange(of: folderID) { _, _ in presented = false }
    }
}

private struct RefPickerPopover: View {
    let model: AppModel
    let projectID: UUID
    let folderID: UUID
    let selection: String
    let pick: (String) -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var scope = Scope.all
    @State private var snapshot: GitRefSnapshot?
    @State private var failure: String?
    @State private var lookupFailure: String?
    @State private var commit: GitRef?
    @State private var selectedCommit: GitRef?
    @State private var resolving = false
    @State private var attempt = 0
    @State private var expanded: Set<String> = []
    @State private var highlight: String?
    @State private var showAllTags = false
    @FocusState private var filterFocused: Bool

    private enum Scope: String, CaseIterable {
        case all = "All", local = "Local", remote = "Remote", tags = "Tags"
        var kind: GitRef.Kind? {
            switch self { case .all: nil; case .local: .local; case .remote: .remote; case .tags: .tag }
        }
    }
    private struct Row: Identifiable {
        var id: String
        var name: String
        var ref: GitRef?
        var depth = 0
        var count: Int?
        var subtitle: String?
        var isMore = false
    }
    private struct Section: Identifiable {
        var id: String
        var title: String
        var count: Int
        var rows: [Row]
        var nodes: [GitRefNode] = []
    }
    private struct Lookup: Equatable { var query: String; var attempt: Int; var loaded: Bool }
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var lookup: Lookup { Lookup(query: search, attempt: attempt, loaded: snapshot != nil) }
    private var refs: [GitRef] { snapshot?.refs ?? [] }
    private var filtered: [GitRef] { search.isEmpty ? refs : GitRef.filtered(refs, query: search) }
    private var expansionKey: String { "refPicker.expanded." + (snapshot?.repositoryKey ?? folderID.uuidString) }
    private var maxListHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 0) >= 800 ? 440 : 360 }
    private var params: [String: JSONValue] { ["projectID": .string(projectID.uuidString), "folderID": .string(folderID.uuidString)] }

    private func count(_ scope: Scope) -> Int {
        filtered.filter { scope.kind == nil || $0.kind == scope.kind }.count + (scope == .all && commit != nil ? 1 : 0)
    }
    private func flatten(_ nodes: [GitRefNode], depth: Int = 0) -> [Row] {
        nodes.flatMap { node -> [Row] in
            let row = Row(id: node.id, name: node.name, ref: node.ref, depth: depth, count: node.children == nil ? nil : node.count)
            return [row] + (expanded.contains(node.id) ? flatten(node.children ?? [], depth: depth + 1) : [])
        }
    }
    private var sections: [Section] {
        var result: [Section] = []
        if search.isEmpty, scope == .all, let snapshot {
            var suggested: [Row] = []
            if let head = snapshot.head {
                let branch = refs.first(where: \.isHEAD)?.name
                suggested.append(Row(id: "suggested:HEAD", name: "HEAD", ref: head, subtitle: [branch, head.shortSHA].compactMap { $0 }.joined(separator: " · ")))
            }
            if let selectedCommit {
                suggested.append(Row(id: "suggested:" + selectedCommit.id, name: selectedCommit.shortSHA, ref: selectedCommit, subtitle: selectedCommit.subject))
            }
            if let base = refs.first(where: { $0.fullName == snapshot.defaultBranch }) {
                suggested.append(Row(id: "suggested:" + base.id, name: base.name, ref: base, subtitle: "default branch"))
                if let upstream = refs.first(where: { $0.fullName == base.upstream }) {
                    suggested.append(Row(id: "suggested:" + upstream.id, name: upstream.name, ref: upstream, subtitle: fetchStatus))
                }
            }
            if !suggested.isEmpty { result.append(Section(id: "suggested", title: "Suggested", count: suggested.count, rows: suggested)) }
        } else if !search.isEmpty, scope == .all, let commit {
            result.append(Section(id: "commit", title: "Commit", count: 1, rows: [Row(id: commit.id, name: commit.shortSHA, ref: commit, subtitle: commit.subject)]))
        }
        for (kind, id, title) in [(GitRef.Kind.local, "local", "Local branches"), (.remote, "remote", "Remote branches"), (.tag, "tags", "Tags")] {
            guard scope.kind == nil || scope.kind == kind else { continue }
            var matches = filtered.filter { $0.kind == kind }
            guard !matches.isEmpty else { continue }
            let count = matches.count
            if search.isEmpty && kind == .tag {
                matches.sort {
                    if $0.creatorDate != $1.creatorDate { return ($0.creatorDate ?? .distantPast) > ($1.creatorDate ?? .distantPast) }
                    return $0.name < $1.name
                }
                if scope == .all && !showAllTags { matches = Array(matches.prefix(6)) }
            }
            let nodes = search.isEmpty && kind != .tag ? GitRefNode.tree(matches, namespace: id) : []
            var rows = nodes.isEmpty ? matches.map { Row(id: $0.id, name: $0.name, ref: $0) } : flatten(nodes)
            if matches.count < count { rows.append(Row(id: "more-tags", name: "Show \(count - matches.count) more tags", isMore: true)) }
            result.append(Section(id: id, title: title, count: count, rows: rows, nodes: nodes))
        }
        return result
    }
    private var visibleRows: [Row] {
        sections.filter { !search.isEmpty || expanded.contains("section:" + $0.id) }.flatMap(\.rows)
    }
    private var fetchStatus: String {
        guard let date = snapshot?.fetchedAt else { return "Not fetched yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Fetched " + formatter.localizedString(for: date, relativeTo: Date())
    }
    private var status: String {
        if snapshot == nil && failure == nil { return "Loading refs…" }
        if resolving { return "Looking up commit…" }
        if !search.isEmpty { let count = count(scope); return "\(count) \(count == 1 ? "match" : "matches")" }
        return snapshot == nil ? "" : fetchStatus
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter branches and tags, or paste a commit", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($filterFocused)
                        .accessibilityIdentifier("ref-picker.filter")
                    if !query.isEmpty {
                        Button { query = ""; filterFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear filter")
                    }
                }
                .padding(.horizontal, 7).frame(height: 26)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(filterFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: filterFocused ? 2 : 1))
                RefPickerScopeControl(
                    selection: Binding(get: { Scope.allCases.firstIndex(of: scope) ?? 0 }, set: { scope = Scope.allCases[$0] }),
                    labels: Scope.allCases.map { "\($0.rawValue) \(count($0))" },
                    enabled: Scope.allCases.map { value in value == .all || refs.contains { $0.kind == value.kind } }
                ).frame(height: 24)
            }.padding(10)
            Divider()
            list
            Divider()
            HStack(spacing: 8) {
                Text("↑↓ Move  →← Expand  ⏎ Use as base  esc Close")
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text(status).lineLimit(1)
            }.font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 440)
        .background(RefPickerKeyHandler(handle: handleKey))
        .onAppear { filterFocused = true }
        .task(id: attempt) { await load() }
        .task(id: lookup) { await resolveCommit() }
        .onChange(of: search) { _, _ in
            commit = nil; lookupFailure = nil
            highlightFirst()
        }
        .onChange(of: scope) { _, _ in highlightFirst(); announceResults() }
        .onChange(of: expanded) { _, value in
            guard snapshot != nil else { return }
            UserDefaults.standard.set(value.sorted(), forKey: expansionKey)
        }
    }

    @ViewBuilder private var list: some View {
        if let error = failure ?? lookupFailure {
            VStack(spacing: 10) {
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                Button("Retry") { attempt += 1 }.accessibilityIdentifier("ref-picker.retry")
            }.padding(20).frame(maxWidth: .infinity, minHeight: 150)
        } else if snapshot == nil {
            VStack(spacing: 12) {
                ForEach(0..<6) { index in
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: CGFloat(180 + index % 3 * 70), height: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(16).accessibilityLabel("Loading refs")
        } else if sections.isEmpty {
            VStack(spacing: 8) {
                if resolving { ProgressView().controlSize(.small) }
                Text(search.isEmpty ? "No branches or tags yet" : GitRef.isCommitQuery(search) ? "No commit starting with “\(search)”" : "No branches or tags match “\(search)”")
                    .font(.system(size: 13, weight: .semibold))
                Text("Check the spelling, switch to All, or paste a full commit SHA.").font(.system(size: 12)).foregroundStyle(.tertiary)
            }.multilineTextAlignment(.center).padding(20).frame(maxWidth: .infinity, minHeight: 140)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sections) { section in
                            sectionHeader(section)
                            if !search.isEmpty || expanded.contains("section:" + section.id) {
                                ForEach(section.rows) { row in
                                    RefPickerRow(name: row.name, ref: row.ref, depth: row.depth, count: row.count,
                                        subtitle: row.subtitle, query: search, selected: highlight == row.id,
                                        expanded: expanded.contains(row.id), isMore: row.isMore) { activate(row) }
                                        .id(row.id)
                                        .onHover { inside in if inside { highlight = row.id } }
                                }
                            }
                        }
                    }.padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(height: min(maxListHeight, CGFloat(visibleRows.count * 24 + sections.count * 30 + 6)))
                .onChange(of: highlight) { _, id in if let id { proxy.scrollTo(id) } }
                .onAppear { if let highlight { proxy.scrollTo(highlight) } }
                .accessibilityLabel("Branches and tags")
                .accessibilityRepresentation { accessibleList }
            }
        }
    }

    /// Expose the same refs as a native outline to VoiceOver. The visual list is
    /// flattened so keyboard movement and persisted folder expansion share one order.
    private var accessibleList: some View {
        List {
            ForEach(sections) { section in
                SwiftUI.Section(section.title) {
                    if !section.nodes.isEmpty {
                        OutlineGroup(section.nodes, children: \.children) { node in
                            RefPickerRow(name: node.name, ref: node.ref, depth: 0, count: node.children == nil ? nil : node.count,
                                subtitle: nil, query: search, selected: highlight == node.id,
                                expanded: expanded.contains(node.id), isMore: false) {
                                    if let ref = node.ref { pick(ref.fullName) } else { toggle(node.id) }
                                }
                        }
                    } else {
                        ForEach(section.rows) { row in
                            RefPickerRow(name: row.name, ref: row.ref, depth: row.depth, count: row.count,
                                subtitle: row.subtitle, query: search, selected: highlight == row.id,
                                expanded: expanded.contains(row.id), isMore: row.isMore) { activate(row) }
                        }
                    }
                }
            }
        }.accessibilityLabel("Branches and tags")
    }

    private func sectionHeader(_ section: Section) -> some View {
        Button {
            guard search.isEmpty else { return }
            toggle("section:" + section.id)
        } label: {
            HStack(spacing: 6) {
                if search.isEmpty { Image(systemName: expanded.contains("section:" + section.id) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 10) }
                Text(section.title).fontWeight(.semibold)
                Spacer()
                Text("\(section.count)")
            }.font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 8).frame(height: 30)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(section.title), \(section.count) refs")
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        if let highlight, !visibleRows.contains(where: { $0.id == highlight }) { highlightFirst() }
    }
    private func activate(_ row: Row) {
        if row.isMore { showAllTags = true; highlight = sections.last?.rows.dropFirst(6).first?.id }
        else if let ref = row.ref { pick(ref.fullName) }
        else { toggle(row.id) }
    }
    private func highlightFirst() { highlight = visibleRows.first?.id }
    private func move(_ offset: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == highlight } ?? (offset > 0 ? -1 : rows.count)
        highlight = rows[max(0, min(rows.count - 1, current + offset))].id
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { close(); return true }
        if event.keyCode == 51 && event.modifierFlags.contains(.command) { query = ""; return true }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 125: move(1); return true
        case 126: move(-1); return true
        case 36, 76:
            if let row = visibleRows.first(where: { $0.id == highlight }) { activate(row) }
            return true // Never let Return launch the underlying sheet.
        case 123, 124:
            guard search.isEmpty, let row = visibleRows.first(where: { $0.id == highlight }), row.count != nil else { return false }
            if (event.keyCode == 124) != expanded.contains(row.id) { toggle(row.id) }
            return true
        default: return false
        }
    }
    private func load() async {
        failure = nil; lookupFailure = nil; snapshot = nil; commit = nil
        do {
            let result = try await model.call("listGitRefs", .object(params)).decode(GitRefSnapshot.self)
            guard !Task.isCancelled else { return }
            if GitRef.isCommitQuery(selection) {
                var arguments = params; arguments["query"] = .string(selection)
                selectedCommit = try await model.call("resolveGitCommit", .object(arguments)).decode(GitRef?.self)
                guard !Task.isCancelled else { return }
            }
            snapshot = result
            expanded = Set(UserDefaults.standard.stringArray(forKey: expansionKey) ?? ["section:suggested", "section:local", "section:remote", "section:tags", "local:feature", "remote:origin"])
            if selection == "HEAD" || selectedCommit != nil { expanded.insert("section:suggested") }
            if let selected = refs.first(where: { $0.fullName == selection || $0.name == selection }) {
                let namespace = selected.kind == .local ? "local" : selected.kind == .remote ? "remote" : "tags"
                expanded.insert("section:" + namespace)
                let segments = selected.name.split(separator: "/")
                if segments.count > 1 {
                    for depth in 1..<segments.count { expanded.insert(namespace + ":" + segments.prefix(depth).joined(separator: "/")) }
                }
                if selected.kind == .tag { showAllTags = true }
            }
            highlight = visibleRows.first { $0.ref?.fullName == selection || $0.ref?.name == selection }?.id ?? visibleRows.first?.id
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
    private func resolveCommit() async {
        let request = lookup
        commit = nil; resolving = false; lookupFailure = nil
        guard request.loaded else { return }
        guard GitRef.isCommitQuery(request.query) else { announceResults(); return }
        resolving = true
        do {
            try await Task.sleep(for: .milliseconds(150))
            var arguments = params; arguments["query"] = .string(request.query)
            let result = try await model.call("resolveGitCommit", .object(arguments)).decode(GitRef?.self)
            guard !Task.isCancelled, request == lookup else { return }
            commit = result; resolving = false; highlightFirst(); announceResults()
        } catch {
            guard !Task.isCancelled, request == lookup else { return }
            lookupFailure = error.localizedDescription; resolving = false
        }
    }
    private func announceResults() {
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
            userInfo: [.announcement: "\(count(scope)) results", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// AppKit's equal-fill distribution keeps all scopes usable across the full width.
private struct RefPickerScopeControl: NSViewRepresentable {
    @Binding var selection: Int
    let labels: [String]
    let enabled: [Bool]
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let view = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.select(_:)))
        view.segmentDistribution = .fillEqually
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setAccessibilityLabel("Scope")
        view.setAccessibilityIdentifier("ref-picker.scope")
        return view
    }
    func updateNSView(_ view: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        view.selectedSegment = selection
        for index in labels.indices {
            view.setLabel(labels[index], forSegment: index)
            view.setEnabled(enabled[index], forSegment: index)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 420, height: 24)
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func select(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0 else { return }
            selection.wrappedValue = sender.selectedSegment
        }
    }
}

/// Intercept navigation before the field editor or the parent sheet's shortcuts.
private struct RefPickerKeyHandler: NSViewRepresentable {
    var handle: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyView { let view = KeyView(); view.handle = handle; return view }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }
    final class KeyView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isVisible,
                      // Non-key popovers receive their field-editor events through the parent sheet.
                      event.window === window || event.window === window.parent else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
