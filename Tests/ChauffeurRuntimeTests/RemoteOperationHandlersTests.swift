import Foundation
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

struct RemoteOperationHandlersTests {
    @Test func inventoryMapsProjectsFoldersCheckoutsAndSessions() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        // An archived preset in the same set, and an archived set with a live preset, are both hidden.
        var archived = AgentPreset(setID: fixture.set.id, name: "Retired", kind: .codex, executable: "/bin/false", configurationDirectory: fixture.root.path)
        archived.archived = true
        try await fixture.runtime.store.save(archived)
        var otherSet = PresetSet(name: "Archived team"); otherSet.archived = true
        try await fixture.runtime.store.save(otherSet)
        try await fixture.runtime.store.save(AgentPreset(setID: otherSet.id, name: "Elsewhere", kind: .claude, executable: "/bin/false", configurationDirectory: fixture.root.path))
        // An unregistered folder is history only and never offered to the phone.
        let stored = try #require(await fixture.runtime.store.current().projects.first)
        var project = stored.value
        let extra = fixture.root.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        var folder = ProjectFolder(path: extra.path); folder.registered = false
        project.folders.append(folder)
        try await fixture.runtime.store.save(project, expectedVersion: stored.version)
        try await fixture.runtime.start()
        let worktree = try await fixture.runtime.createWorktree(fixture.creation).value
        // A shell session recorded in that worktree; the runtime learns about it on start.
        let session = fixture.shellSession(worktreeID: worktree.id, path: worktree.path, title: "Shell · task/fixture")
        try await fixture.runtime.store.save(session)
        let reopened = try fixture.reopen(); try await reopened.start()
        await reopened.reconcileWorktrees()
        let attachedID = session.id
        let handlers = RemoteOperationHandlers(runtime: reopened, root: fixture.root, hostName: "Test Mac", isAttached: { $0 == attachedID })
        let inventory = try await handlers.inventory()
        #expect(inventory.hostName == "Test Mac")
        #expect(inventory.revision == 1)
        let summary = try #require(inventory.projects.first)
        #expect(inventory.projects.count == 1 && summary.id == project.id && summary.name == project.name && !summary.archived)
        #expect(summary.groups.map(\.name) == ["Default"] && summary.groups[0].isDefault)
        #expect(summary.presets == [PresetSummary(id: fixture.preset.id, name: fixture.preset.name, kind: .claude)])
        let folderSummary = try #require(summary.folders.first)
        #expect(summary.folders.count == 1 && folderSummary.id == fixture.folder.id && folderSummary.path == fixture.folder.canonicalPath)
        #expect(folderSummary.isRepository && folderSummary.inventoryReady && folderSummary.availability == .available)
        #expect(folderSummary.checkouts == [
            CheckoutSummary(kind: .main, worktreeID: nil, branch: "main", path: fixture.folder.canonicalPath, availability: .available, managed: false),
            CheckoutSummary(kind: .worktree, worktreeID: worktree.id, branch: "task/fixture", path: worktree.path, availability: .available, managed: true)
        ])
        let remote = try #require(inventory.sessions.first)
        #expect(inventory.sessions.count == 1 && remote.id == session.id && remote.kind == .shell)
        #expect(remote.worktreeID == worktree.id && remote.branch == "task/fixture" && remote.checkoutPath == worktree.path)
        #expect(remote.attached && remote.title == "Shell · task/fixture")
        // No terminal survived the restart, so the runtime marks the recorded session interrupted.
        #expect(remote.state == .interrupted && !remote.state.isLive)
        #expect(inventory.sessions.first { $0.id == session.id }?.projectID == project.id)
    }

    @Test func mainCheckoutSessionsReportTheMainBranchAndUnattachedState() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let session = fixture.shellSession(worktreeID: nil, path: fixture.folder.canonicalPath, title: "Shell · main")
        try await fixture.runtime.store.save(session)
        try await fixture.runtime.start()
        await fixture.runtime.reconcileWorktrees()
        let handlers = fixture.handlers()
        let inventory = try await handlers.inventory()
        let remote = try #require(inventory.sessions.first)
        #expect(remote.worktreeID == nil && remote.branch == "main" && !remote.attached)
    }

    @Test func digestIsStableAndRevisionBumpsOnlyWhenContentChanges() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        try await fixture.runtime.start()
        await fixture.runtime.reconcileWorktrees()
        let snapshot = try await fixture.runtime.snapshot()
        let first = try RemoteInventoryBuilder.build(snapshot: snapshot, hostName: "Mac", revision: 1, isAttached: { _ in false })
        let second = try RemoteInventoryBuilder.build(snapshot: snapshot, hostName: "Mac", revision: 7, isAttached: { _ in false })
        #expect(first.revision == 1 && second.revision == 7)
        #expect(RemoteInventoryBuilder.digest(first) == RemoteInventoryBuilder.digest(second))
        var attached = first; attached.sessions = []; attached.hostName = "Other"
        #expect(RemoteInventoryBuilder.digest(first) != RemoteInventoryBuilder.digest(attached))

        let handlers = fixture.handlers()
        #expect(await handlers.currentRevision() == 0)
        #expect(try await handlers.inventory().revision == 1)
        #expect(try await handlers.inventory().revision == 1)
        #expect(await handlers.currentRevision() == 1)
        _ = try await fixture.runtime.createWorktree(fixture.creation)
        await fixture.runtime.reconcileWorktrees()
        let changed = try await handlers.inventory()
        #expect(changed.revision == 2)
        #expect(changed.projects[0].folders[0].checkouts.count == 2)
        #expect(try await handlers.inventory().revision == 2)
    }

    @Test func previewReturnsTheWorktreeDestination() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        try await fixture.runtime.start()
        let handlers = fixture.handlers()
        let result = await handlers.handle(.previewWorktreeDestination(PreviewWorktreeRequest(projectID: fixture.project.id, folderID: fixture.folder.id, branch: "task/preview")), deviceID: UUID())
        guard case .success(.worktreeDestination(let preview)) = result else { Issue.record("Unexpected result \(result)"); return }
        #expect(preview.path.hasPrefix(Paths.canonical(fixture.root.appendingPathComponent("worktrees").path)))
        #expect(preview.path.hasSuffix("task-preview"))
        let invalid = await handlers.handle(.previewWorktreeDestination(PreviewWorktreeRequest(projectID: fixture.project.id, folderID: fixture.folder.id, branch: "bad branch")), deviceID: UUID())
        guard case .failure(let error) = invalid else { Issue.record("Invalid branch was accepted"); return }
        #expect(!error.code.isEmpty && !error.retryable)
        let unknownFolder = await handlers.handle(.previewWorktreeDestination(PreviewWorktreeRequest(projectID: fixture.project.id, folderID: UUID(), branch: "ok")), deviceID: UUID())
        guard case .failure(let folderError) = unknownFolder else { Issue.record("Unknown folder was accepted"); return }
        #expect(folderError.code == "missing_folder")
    }

    @Test func mismatchedFingerprintIsRefusedWithoutTouchingTheRuntime() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        try await fixture.runtime.start()
        let handlers = fixture.handlers()
        let key = UUID()
        // The original attempt names a preset that does not exist, so it fails before any worktree work.
        let original = LaunchSpec(projectID: fixture.project.id, folderID: fixture.folder.id, agentPresetID: UUID())
        let first = await handlers.launch(fixture.request(key: key, newWorktree: WorktreeCreationSpec(branch: "task/conflict", baseRef: "HEAD"), launch: original), deviceID: UUID())
        #expect(first.phase == .failed && first.error?.code == "unknown_preset")
        // The retry changes the request: it must be refused, and no worktree may appear.
        let changed = LaunchSpec(projectID: fixture.project.id, folderID: fixture.folder.id)
        let second = await handlers.launch(fixture.request(key: key, newWorktree: WorktreeCreationSpec(branch: "task/conflict", baseRef: "HEAD"), launch: changed), deviceID: UUID())
        #expect(second.phase == .failed && second.error?.code == "operation_conflict" && second.error?.retryable == false)
        #expect(await fixture.runtime.store.reload().worktrees.isEmpty)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 1)
        // The journal still holds the original outcome.
        #expect(await handlers.operationStatus(key: key)?.error?.code == "unknown_preset")
        let status = await handlers.handle(.getOperationStatus(OperationStatusRequest(operationKey: key)), deviceID: UUID())
        guard case .success(.operation(let recorded)) = status else { Issue.record("Missing operation status"); return }
        #expect(recorded.operationKey == key && recorded.phase == .failed)
        let unknown = await handlers.handle(.getOperationStatus(OperationStatusRequest(operationKey: UUID())), deviceID: UUID())
        guard case .failure(let error) = unknown else { Issue.record("Unknown operation returned a status"); return }
        #expect(error.code == "unknown_operation")
    }

    @Test func unknownIdentifiersFailWithSpecificCodes() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        try await fixture.runtime.start()
        let handlers = fixture.handlers()
        let device = UUID()
        let cases: [(String, LaunchSpec)] = [
            ("unknown_project", LaunchSpec(projectID: UUID(), folderID: fixture.folder.id)),
            ("unknown_folder", LaunchSpec(projectID: fixture.project.id, folderID: UUID())),
            ("unknown_group", LaunchSpec(projectID: fixture.project.id, folderID: fixture.folder.id, groupID: UUID())),
            ("unknown_preset", LaunchSpec(projectID: fixture.project.id, folderID: fixture.folder.id, agentPresetID: UUID()))
        ]
        for (code, spec) in cases {
            let status = await handlers.launch(fixture.request(key: UUID(), newWorktree: nil, launch: spec), deviceID: device)
            #expect(status.phase == .failed && status.error?.code == code && status.error?.retryable == false, "\(code)")
        }
        #expect(await fixture.runtime.store.reload().worktrees.isEmpty)
        #expect(try await fixture.runtime.snapshot()["sessions"].array.isEmpty)
    }

    @Test func connectionLevelOperationsAreNotHandledHere() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        try await fixture.runtime.start()
        let handlers = fixture.handlers()
        let operations: [RemoteOperation] = [
            .hello(HelloRequest(deviceID: UUID(), deviceToken: "t", clientName: "c", clientVersion: "1", protocolVersion: 1)),
            .pair(PairRequest(deviceName: "iPhone", protocolVersion: 1)),
            .attachTerminal(AttachTerminalRequest(sessionID: UUID(), cols: 80, rows: 24)),
            .terminalResize(TerminalResizeRequest(generation: 1, cols: 80, rows: 24)),
            .detachTerminal(DetachTerminalRequest(generation: 1))
        ]
        for operation in operations {
            guard case .failure(let error) = await handlers.handle(operation, deviceID: UUID()) else { Issue.record("\(operation.kind) was handled"); continue }
            #expect(error.code == "unsupported_operation")
        }
        guard case .success(.inventory(let inventory)) = await handlers.handle(.listInventory(ListInventoryRequest(sinceRevision: 5)), deviceID: UUID()) else { Issue.record("Inventory failed"); return }
        #expect(inventory.projects.count == 1)
    }

    @Test func journalPersistsAndRestartReconciliationResolvesStaleLaunches() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        try await fixture.runtime.start()
        let device = UUID()
        let completedKey = UUID(), interruptedKey = UUID(), worktreeOnlyKey = UUID()
        #expect(RemoteOperationKeys.worktreeKey(for: completedKey) == RemoteOperationKeys.worktreeKey(for: completedKey))
        #expect(RemoteOperationKeys.worktreeKey(for: completedKey) != completedKey)
        #expect(RemoteOperationKeys.worktreeKey(for: completedKey) != RemoteOperationKeys.worktreeKey(for: interruptedKey))
        // The session for the first launch made it into the store before the process died.
        var session = fixture.shellSession(worktreeID: nil, path: fixture.folder.canonicalPath, title: "Shell · main")
        session.id = RemoteOperationKeys.sessionKey(for: completedKey)
        try await fixture.runtime.store.save(session)
        // The third launch created its worktree but never reached the session.
        var creation = fixture.creation; creation.retryKey = RemoteOperationKeys.worktreeKey(for: worktreeOnlyKey)
        let worktree = try await fixture.runtime.createWorktree(creation).value
        let journal = RemoteOperationJournal(root: fixture.root)
        for (key, phase) in [(completedKey, OperationPhase.launching), (interruptedKey, .launching), (worktreeOnlyKey, .creatingWorktree)] {
            let status = OperationStatus(operationKey: key, phase: phase, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try await journal.upsert(RemoteOperationRecord(key: key, fingerprint: "fp-\(key)", deviceID: device, status: status, worktreeKey: RemoteOperationKeys.worktreeKey(for: key), sessionKey: RemoteOperationKeys.sessionKey(for: key)))
        }
        let url = fixture.root.appendingPathComponent("runtime/remote-operations.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let reloaded = RemoteOperationJournal(root: fixture.root)
        try await reloaded.load()
        #expect(await reloaded.all().count == 3)
        #expect(await reloaded.record(for: interruptedKey)?.fingerprint == "fp-\(interruptedKey)")

        let handlers = fixture.handlers()
        await handlers.reconcileAfterRestart()
        let completed = try #require(await handlers.operationStatus(key: completedKey))
        #expect(completed.phase == .completed && completed.sessionID == session.id && completed.error == nil)
        let interrupted = try #require(await handlers.operationStatus(key: interruptedKey))
        #expect(interrupted.phase == .failed && interrupted.error?.code == "interrupted" && interrupted.error?.retryable == true)
        let ready = try #require(await handlers.operationStatus(key: worktreeOnlyKey))
        #expect(ready.phase == .worktreeReady && ready.worktreeID == worktree.id)
        // A fresh handler sees the reconciled outcome from disk.
        let later = fixture.handlers()
        #expect(await later.operationStatus(key: completedKey)?.phase == .completed)
        #expect(await later.operationStatus(key: interruptedKey)?.phase == .failed)
        // A retry with the original fingerprint of the completed launch returns the same session without relaunching.
        let retry = LaunchOperationRequest(operationKey: completedKey, fingerprint: "fp-\(completedKey)", launch: LaunchSpec(projectID: fixture.project.id, folderID: fixture.folder.id))
        let status = await later.launch(retry, deviceID: device)
        #expect(status.phase == .completed && status.sessionID == session.id)
    }

    @Test func launchingAShellInANewWorktreeIsIdempotent() async throws {
        let fixture = try await Fixture.make(realTerminal: true); defer { fixture.cleanup() }
        try await fixture.runtime.start()
        let handlers = fixture.handlers()
        let key = UUID(), device = UUID()
        let request = fixture.request(key: key, newWorktree: WorktreeCreationSpec(branch: "task/remote", baseRef: "HEAD"), launch: LaunchSpec(projectID: fixture.project.id, folderID: fixture.folder.id))
        let first = await handlers.launch(request, deviceID: device)
        #expect(first.phase == .completed, "\(first)")
        #expect(first.sessionID == key && first.worktreeID == RemoteOperationKeys.worktreeKey(for: key))
        let sessions = try await fixture.runtime.snapshot()["sessions"].decode([Session].self)
        let session = try #require(sessions.first { $0.id == key })
        #expect(session.title == "Shell · task/remote" && session.launch.preset.kind == .shell && session.state.isLive)
        #expect(session.worktreeID == first.worktreeID)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 2)
        // The same request again resolves to the same session and worktree.
        let second = await handlers.launch(request, deviceID: device)
        #expect(second == first)
        #expect(try await fixture.runtime.snapshot()["sessions"].decode([Session].self).count == 1)
        #expect(await fixture.runtime.store.reload().worktrees.count == 1)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 2)
        // Through the dispatcher the launch reports the same recorded outcome.
        guard case .success(.operation(let dispatched)) = await handlers.handle(.launch(request), deviceID: device) else { Issue.record("Dispatch failed"); return }
        #expect(dispatched.sessionID == key)
        await fixture.runtime.reconcileWorktrees()
        let inventory = try await handlers.inventory()
        #expect(inventory.sessions.map(\.id) == [key] && inventory.sessions[0].branch == "task/remote" && inventory.sessions[0].state.isLive)
        #expect(inventory.projects[0].folders[0].checkouts.contains { $0.worktreeID == first.worktreeID && $0.branch == "task/remote" })
        _ = try await fixture.runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(key.uuidString), "force": .bool(true)])))
    }
}

private struct Fixture: Sendable {
    let root: URL
    let runtime: RuntimeCoordinator
    let project: Project
    let set: PresetSet
    let preset: AgentPreset
    let tmux: String?
    var repo: URL { root.appendingPathComponent("repo") }
    var folder: ProjectFolder { project.folders[0] }
    var creation: WorktreeCreationRequest { WorktreeCreationRequest(projectID: project.id, folderID: folder.id, branch: "task/fixture", baseRef: "HEAD") }
    static let environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]

    /// The runtime is not started so tests can add records the runtime must learn about on start.
    static func make(realTerminal: Bool = false) async throws -> Self {
        // Keep the Unix-domain tmux socket below macOS's path-length limit.
        let root = URL(fileURLWithPath: "/tmp/chauffeur-remote-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "core.hooksPath", "/dev/null"], ["config", "commit.gpgsign", "false"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"]] {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + args)
            guard result.status == 0 else { throw ChauffeurError("fixture_git", result.error) }
        }
        var environment = environment; environment["HOME"] = root.path
        var ctlPath = "/bin/false"
        var tmux: String?
        if realTerminal {
            // The exec helper only needs to hand the shell its payload; agents are never launched here.
            let helper = root.appendingPathComponent("ctl.py")
            try Data(#"""
            #!/usr/bin/python3
            import json, os, sys
            from pathlib import Path
            if len(sys.argv) > 1 and sys.argv[1] == 'internal-exec':
                path = Path(sys.argv[2]); payload = json.loads(path.read_text()); path.unlink()
                os.chdir(payload['directory'])
                os.execve(payload['executable'], [payload['executable'], *payload['arguments']], payload['environment'])
            sys.exit(1)
            """#.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            ctlPath = helper.path
            tmux = try Paths.executable("tmux", environment: environment)
        }
        let runtime = try RuntimeCoordinator(root: root, ctlPath: ctlPath, environment: environment)
        let set = PresetSet(name: "Remote fixture")
        let preset = AgentPreset(setID: set.id, name: "Unavailable agent", kind: .claude, executable: root.appendingPathComponent("missing-cli").path, configurationDirectory: root.path)
        var project = Project(name: "Remote fixture", presetSetID: set.id)
        project.addFolder(ProjectFolder(path: repo.path))
        try await runtime.store.save(set); try await runtime.store.save(preset); try await runtime.store.save(project)
        return Self(root: root, runtime: runtime, project: project, set: set, preset: preset, tmux: tmux)
    }
    func reopen() throws -> RuntimeCoordinator {
        var environment = Self.environment; environment["HOME"] = root.path
        return try RuntimeCoordinator(root: root, ctlPath: "/bin/false", environment: environment)
    }
    func handlers(isAttached: @escaping @Sendable (UUID) async -> Bool = { _ in false }) -> RemoteOperationHandlers {
        RemoteOperationHandlers(runtime: runtime, root: root, hostName: "Test Mac", isAttached: isAttached)
    }
    func request(key: UUID, newWorktree: WorktreeCreationSpec?, launch: LaunchSpec) -> LaunchOperationRequest {
        LaunchOperationRequest(operationKey: key, fingerprint: LaunchOperationRequest.computeFingerprint(newWorktree: newWorktree, launch: launch), newWorktree: newWorktree, launch: launch)
    }
    /// A recorded shell session, as the runtime would have persisted it.
    func shellSession(worktreeID: UUID?, path: String, title: String) -> Session {
        let shellSet = PresetSet(name: "Shell")
        var shell = AgentPreset(setID: shellSet.id, name: "Shell", kind: .shell, executable: "/bin/zsh", configurationDirectory: path)
        shell.arguments = ["-l"]; shell.integration = .unavailable
        let launch = LaunchSnapshot(preset: shell, set: shellSet, executablePath: "/bin/zsh", executableVersion: "shell", workingDirectory: path, additionalPaths: [])
        var session = Session(projectID: project.id, groupID: project.groups[0].id, title: title, launch: launch, folderID: folder.id)
        session.worktreeID = worktreeID; session.state = .running
        return session
    }
    func cleanup() {
        if let tmux {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["-S", root.appendingPathComponent("runtime/tmux.sock").path, "kill-server"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try? process.run(); process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }
}
