# Team Onboarding Wizard Implementation Plan

Implementation was executed with Agent Team and implementation-progress, without
the Superpowers execution workflow, per the user's subsequent instruction. See
[validation results](../../onboarding-validation.md) for the implemented outcome
and checks that remain unavailable in this environment. The checklist below is
the original planning artifact, not the live progress tracker.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people configure teams, copy selected agent settings, and sign in to isolated Codex/Claude configurations without preparing folders manually.

**Architecture:** SwiftUI edits a persisted setup draft through a runtime-owned coordinator. Per-agent migration and authentication adapters adapt the proven claudewho/codexwho behavior; existing team records remain the source of launch configuration. Login uses a dedicated setup terminal and never creates a project session.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, Foundation, existing CChauffeur PTY support, Swift Testing, XCTest UI tests, Swift Package Manager, XcodeGen.

**Spec:** [Approved design](../specs/2026-09-19-onboarding-wizard-design.md).

## Global Constraints

- Work on `feat/onboarding-wizard`; preserve unrelated changes.
- Default the editable source to `~/.claude` or `~/.codex`, and the destination to `~/.claude-<team>` or `~/.codex-<team>`.
- Teams may share an agent configuration, including mixed setups where only one agent has separate accounts.
- Source files remain untouched.
- Credentials and login sessions: excluded, not selectable.
- Keep the new classes in dedicated physical `Onboarding` directories that appear as folders/groups in Xcode.
- Preserve current target ownership and the Swift package boundary.
- Generate the Xcode project through the existing XcodeGen setup rather than hand-editing generated project files.
- Setup state stays local to the Mac; adding remote onboarding APIs is outside scope.
- Connected requires affirmative evidence from a supported agent authentication-status interface in the target context.
- No automatic CLI installation, account purchase, shell-wrapper installation, or global shell changes.
- Use temporary profiles and fake CLIs for tests. Real browser login acceptance requires designated test accounts and human interaction; never use personal credentials implicitly.

## Review Focus

1. A user changes the source after preview: the old selection must not copy unreviewed content (Tasks 2–4).
2. An inherited API key or alternate credential directory selects another account: setup verification and later launch must agree (Task 5).
3. The app/runtime stops after publishing a folder: resume must recover without overwriting the folder or creating a duplicate team (Tasks 4 and 6).
4. Two team names collapse to one slug on a case-insensitive volume: catch the collision before writes and let the user edit the path (Tasks 2 and 7).
5. A second window edits or cancels the active login: stale clients must not mutate the current draft or write into a replacement terminal (Tasks 1, 6, and 7).

## Reference behavior and verified interfaces

Read these local sources before implementing migration; they are the primary behavioral reference requested by the user:

- `/Users/leolobato/Documents/Projetos/opensource/claudewho/bin/claudewho` at `7497574`: `create_wrapper`, `select_and_copy_projects`, `rewrite_plugin_paths`, `migrate_default_config`, `add_account`.
- `/Users/leolobato/Documents/Projetos/opensource/codexwho/bin/codexwho` at `9e69e0e`: `create_wrapper`, `migrate_default_config`, `add_account`.

Preserve independent profile directories, source preservation, selective project copying for Claude, and plugin path repair. Adapt selection to checkboxes and use the requested folder names. Do not invoke the scripts directly: their wrappers, registration files, default names, and hard-coded sources are outside the approved scope. Preserve MIT attribution if source is ported verbatim.

Installed help inspected during planning: Codex `0.155.0` supports `login`, `login status`, and `login --device-auth`; Claude Code `2.1.278` supports `auth login` and `auth status --json`. Help establishes command availability, not successful account isolation. Add fixtures for these contracts, inspect clean-profile outputs during Task 5, and report unsupported output as Unable to verify.

[Codex authentication](https://learn.chatgpt.com/docs/auth) documents `CODEX_HOME` file storage and selectable credential backends. [Claude authentication](https://code.claude.com/docs/en/authentication) documents directory-scoped Keychain entries. [Claude CLI reference](https://code.claude.com/docs/en/cli-reference) documents JSON status and exit codes. Keep identity optional and never read raw tokens to populate identity labels.

## File and interface map

All names below are new unless explicitly marked existing. Keep a single responsibility per file.

| Location | Responsibility |
| --- | --- |
| `Sources/ChauffeurCore/Onboarding/SetupDraft.swift` | Versioned draft, team, pair, and progress records |
| `Sources/ChauffeurCore/Onboarding/SetupContracts.swift` | Inventory, copy preview/receipt, login status, operation request types |
| `Sources/ChauffeurCore/Onboarding/SetupEnvironment.swift` | Shared sanitized agent environment without session grants |
| `Sources/ChauffeurCore/Onboarding/FileStore+Onboarding.swift` | Actor-isolated draft and journal persistence |
| `Sources/ChauffeurRuntimeKit/Onboarding/ConfigurationDiscovery.swift` | Bounded directory discovery and destination validation |
| `Sources/ChauffeurRuntimeKit/Onboarding/ConfigurationMigration.swift` | Adapter protocol and immutable migration preview |
| `Sources/ChauffeurRuntimeKit/Onboarding/ClaudeConfigurationMigration.swift` | Claude categories, JSON filtering, path repair, project groups |
| `Sources/ChauffeurRuntimeKit/Onboarding/CodexConfigurationMigration.swift` | Codex categories and TOML filtering |
| `Sources/ChauffeurRuntimeKit/Onboarding/ConfigurationPublisher.swift` | Staging, no-replace publication, receipts, recovery |
| `Sources/ChauffeurRuntimeKit/Onboarding/AgentAuthentication.swift` | Authentication protocol and version capabilities |
| `Sources/ChauffeurRuntimeKit/Onboarding/CodexAuthentication.swift` | Codex login/status commands and parser |
| `Sources/ChauffeurRuntimeKit/Onboarding/ClaudeAuthentication.swift` | Claude login/status commands and parser |
| `Sources/ChauffeurRuntimeKit/Onboarding/SetupLoginHost.swift` | Dedicated PTY lifetime, input/resize/output and cancellation |
| `Sources/ChauffeurRuntimeKit/Onboarding/OnboardingCoordinator.swift` | Operations, per-target serialization, recovery and team publication |
| `Sources/ChauffeurRuntimeKit/Onboarding/OnboardingDispatch.swift` | Local IPC method routing |
| `Sources/ChauffeurApp/Onboarding/OnboardingModel.swift` | Main-actor draft editing and IPC client |
| `Sources/ChauffeurApp/Onboarding/OnboardingWizard.swift` | Step navigation and save/resume |
| `Sources/ChauffeurApp/Onboarding/AgentSetupStep.swift` | Agent selection and per-agent account questions |
| `Sources/ChauffeurApp/Onboarding/TeamSetupStep.swift` | Team names and per-team agent choices |
| `Sources/ChauffeurApp/Onboarding/ConfigurationSetupStep.swift` | Existing/new/shared profile choices |
| `Sources/ChauffeurApp/Onboarding/CopySettingsStep.swift` | Source, destination, category and project selection |
| `Sources/ChauffeurApp/Onboarding/LoginSetupStep.swift` | Login progress, identity, retry and embedded terminal |
| `Sources/ChauffeurApp/Onboarding/SetupTerminalController.swift` | SwiftTerm adapter to setup-specific IPC |
| `Sources/ChauffeurApp/Onboarding/SetupSummaryStep.swift` | Default team and first-project handoff |

Mirror grouping under `Tests/ChauffeurCoreTests/Onboarding`, `Tests/ChauffeurRuntimeTests/Onboarding`, and `Tests/ChauffeurAppUITests/Onboarding`. Put reusable isolated fixtures under the corresponding test folder, not production code.

## Task 1: Persist resumable setup records

**Files:** Create the four Core/Onboarding files above except `SetupEnvironment.swift` (Task 5). Modify existing `Sources/ChauffeurCore/FileStore.swift` only for directory initialization/shared internal persistence helpers. Create `Tests/ChauffeurCoreTests/Onboarding/SetupDraftTests.swift` and `SetupStoreTests.swift`.

**Interfaces:** Define these public Codable/Sendable values with public initializers; IDs are stable before any side effect:

```swift
enum SetupStep: String, Codable, Sendable {
    case agents, teams, configurations, copy, login, summary
}
enum AccountCount: String, Codable, Sendable { case single, multiple, unsure }
enum ConfigurationChoice: String, Codable, Sendable { case current, existing, create }
enum CopyCategory: String, Codable, CaseIterable, Sendable {
    case preferences, instructions, reusable, plugins, connections, hooks, history
}
enum SetupAuthPhase: String, Codable, Sendable {
    case notChecked, signingIn, verifying, connected, signInRequired, unableToVerify, failed
}
struct SetupAuthStatus: Codable, Sendable {
    var phase: SetupAuthPhase
    var email: String?
    var organization: String?
    var method: String?
    var checkedAt: Date?
    var message: String?
}
```

`SetupAgentPair` fields: `id: UUID`, `kind: CLIKind`, `executable: String`, `choice: ConfigurationChoice`, `sourcePath: String?`, `destinationPath: String`, `categories: Set<CopyCategory>`, `projectPaths: Set<String>`, `previewID: UUID?`, `operationID: UUID?`, `auth: SetupAuthStatus`. `SetupTeam` fields: `id: UUID`, `name: String`, `agents: [SetupAgentPair]`, `savedVersion: String?`. `SetupDraft` fields: `id: UUID`, `schemaVersion: Int` initially 1, `step: SetupStep`, `accountCounts: [String: AccountCount]`, `teams: [SetupTeam]`, `defaultTeamID: UUID?`, `dismissed: Bool`, `completed: Bool`. Conform draft to existing `Record`; use `Stored<SetupDraft>` hashes as optimistic-concurrency versions. Initializers supply empty collections and notChecked authentication.

`SetupOperation` fields: `id: UUID`, `draftID: UUID`, `pairID: UUID`, `destinationPath: String`, `stagingPath: String?`, `previewID: UUID?`, `phase: SetupOperationPhase` (prepared, staged, published, teamSaved, failed), `files: [String: String]` (relative path → digest), `presetIDs: [String: UUID]` (base preset ID → stable custom copy ID), `message: String?`. Use `Record` and existing JSON coding. Existing-folder selection also gets a journal operation before team publication so retry never allocates fresh preset IDs.

- [ ] Write serialization and stale-write tests, including rejecting future schema versions and duplicate pair IDs. Representative assertion:

```swift
@Test func draftRoundTripKeepsStableTeamIDs() throws {
    var draft = SetupDraft()
    draft.teams = [SetupTeam(name: "Work")]
    let restored = try JSONCoding.decode(SetupDraft.self, from: JSONCoding.encode(draft))
    #expect(restored.teams.map(\.id) == draft.teams.map(\.id))
    #expect(restored.completed == false)
}
```

- [ ] Run `swift test --filter SetupDraftTests` and `swift test --filter SetupStoreTests`; confirm tests fail for missing functionality.
- [ ] Add `FileStore.setupDraft() throws -> Stored<SetupDraft>?`, `saveSetupDraft(_:expectedVersion:) throws -> Stored<SetupDraft>`, `setupOperations() throws -> [Stored<SetupOperation>]`, and `saveSetupOperation(_:expectedVersion:) throws -> Stored<SetupOperation>`. Store under a private `onboarding/` directory. Use atomic writes and expected-version checking consistent with existing FileStore; keep helper exposure internal, not public.
- [ ] Validate kind is an agent, supplied paths are absolute, defaultTeamID references a draft team, and active operation IDs cannot be silently replaced by stale UI saves. Persist redacted summaries only.
- [ ] Re-run the two suites and commit the tested records/persistence change.

## Task 2: Discover configurations and validate destinations

**Files:** Create `ConfigurationDiscovery.swift`; add inventory types in `SetupContracts.swift`; create `Tests/ChauffeurRuntimeTests/Onboarding/ConfigurationDiscoveryTests.swift`.

**Interfaces:** `DiscoveredConfiguration` contains `kind: CLIKind`, `path: String`, `displayName: String`, `isCurrent: Bool`, `available: Bool`. `SetupInventory` contains `configurations: [DiscoveredConfiguration]`, `executables: [String: String]`, `missingAgents: [CLIKind]`. `ConfigurationDiscovery` is initialized with explicit `home: URL`, `environment: [String: String]`, `configuredPaths: [String: [String]]`; produces `inventory() throws -> SetupInventory` and `validateDestination(source: String?, destination: String, reserved: [String]) throws -> String` (canonical destination).

- [ ] Test immediate-home discovery, unavailable imported paths, custom executable paths, and effective default environment overrides using temporary home directories. Test case/diacritic slug collisions, paths with spaces/quotes, parent symlinks, source equals destination, source nested inside destination, and destination nested inside source.

```swift
@Test func nestedDestinationIsRejected() throws {
    let discovery = ConfigurationDiscovery(home: URL(fileURLWithPath: "/tmp"),
        environment: [:], configuredPaths: [:])
    #expect(throws: ChauffeurError.self) {
        try discovery.validateDestination(source: "/tmp/source",
            destination: "/tmp/source/work", reserved: [])
    }
}
```

- [ ] Run `swift test --filter ConfigurationDiscoveryTests` to establish the failing tests.
- [ ] Implement bounded enumeration, `Paths.executable` resolution, canonical-path deduplication and readable suggestions. Use `Paths.slug` for proposed names; reject collisions on the actual target filesystem and in the draft's reserved destinations. Keep display names separate from slugs. Existing destinations may be selected, never merged implicitly.
- [ ] Re-run tests and commit.

## Task 3: Port selective migration behavior with previews

**Files:** Create the three migration files above, `Sources/ChauffeurRuntimeKit/Onboarding/ConfigurationDocument.swift` for typed JSON/TOML handling, and `Tests/ChauffeurRuntimeTests/Onboarding/ConfigurationMigrationTests.swift`. Extend `SetupContracts.swift` with copy values. Add TOMLKit only to ChauffeurRuntimeKit and pin it in existing `Package.swift` and `Package.resolved`; include its MIT and bundled toml++ notices.

**Interfaces:** `CopyEntry` has `sourceRelativePath: String`, `destinationRelativePath: String`, `category: CopyCategory`, `sourceDigest: String`, `size: Int64`. `CopyPreview` has `id: UUID`, `pairID: UUID`, `sourcePath: String?`, `destinationPath: String`, `entries: [CopyEntry]`, `warnings: [String]`, `selectionDigest: String`. `ConfigurationMigration` protocol exposes `preview(pair: SetupAgentPair) throws -> CopyPreview` and `write(preview: CopyPreview, pair: SetupAgentPair, staging: URL) throws`. Neither serializes source contents into drafts or IPC.

- [ ] Create synthetic reference fixtures for claudewho/codexwho file lists. Test source/destination byte comparisons and omitted credentials. Include a mixed settings document with preferences, hooks and secret-bearing environment entries:

```swift
@Test func preferenceCopyExcludesHooksAndCredentials() throws {
    let input = Data(#"{"model":"sonnet","hooks":{"Stop":[]},"env":{"ANTHROPIC_API_KEY":"fixture-secret"}}"#.utf8)
    let output = try ConfigurationDocument.claudeJSON(input, categories: [.preferences])
    let text = String(decoding: output, as: UTF8.self)
    #expect(text.contains("sonnet"))
    #expect(!text.contains("hooks"))
    #expect(!text.contains("fixture-secret"))
}
```

- [ ] Run `swift test --filter ConfigurationMigrationTests` and confirm failure.
- [ ] Port the reference category mapping: Claude `CLAUDE.md`, settings JSON, skills, plugins and selected projects; Codex `AGENTS.md`, `config.toml`, prompts/rules/skills/plugins. Treat Claude todos/tasks as history and leave unselected. Offer reusable agent definitions when present. Codex conversation-history copying is not offered because its reference implementation excludes it; explain unsupported categories in the preview.
- [ ] Implement JSON field filtering. Define `ConfigurationDocument.claudeJSON(_:categories:) throws -> Data` and `codexTOML(_:categories:) throws -> Data`. For TOML, use [TOMLKit](https://github.com/LebJe/TOMLKit) with an exact `0.6.0` package pin (tag resolved during planning to `ec6198d37d495efc6acd4dffbd262cdca7ff9b3f`). Its parsed tables support filtering and serialization; do not use regex deletion of secrets. Add the package and target product as follows, and build the runtime target to verify Swift 6 compatibility before using it in the adapter:

```swift
// Package.dependencies:
.package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0")
// ChauffeurRuntimeKit.dependencies:
.product(name: "TOMLKit", package: "TOMLKit")
// ConfigurationDocument parses first, then emits only selected supported fields:
let table = try TOMLTable(string: String(decoding: input, as: UTF8.self))
// Walk the parsed keys using the category allowlist; omit unknown/secret fields.
let encoded = table.convert(to: .toml)
```

Malformed or unsupported source documents are skipped with a visible preview explanation while supported standalone assets remain selectable. Parser/build integration failure must be fixed rather than disguising all Codex preferences as unsupported.
- [ ] Partition settings structurally: hooks only under hooks, MCP entries only under connections, plugin metadata only under plugins. Filter known credential keys, secret env values and authentication helpers out of copied config, including nested tables/objects. Unknown fields that cannot be classified are omitted with a warning. Preserve managed login restrictions where understood; never alter system-managed policy. Custom provider preferences whose required credentials are excluded show a reconnect warning.
- [ ] Repair recognized plugin path fields in `known_marketplaces.json`, `installed_plugins.json`, and `config.json` as in claudewho, but compare source path components rather than replacing arbitrary prose. Remap only internal links whose targets are selected; report external/broken links. Never follow links out of source during enumeration.
- [ ] Digest source files and selected categories/project paths. Refuse write if content, source, destination, or selection differs from the reviewed preview. Test changed-source content and paths, malformed JSON/TOML, Unicode filenames, and plugins referencing an unrelated path with a matching text prefix.
- [ ] Re-run tests and commit the migration adapters plus reference attribution where needed.

## Task 4: Publish configurations safely and recover operations

**Files:** Create `ConfigurationPublisher.swift`, `Tests/ChauffeurRuntimeTests/Onboarding/ConfigurationPublisherTests.swift`; add `CopyReceipt` to `SetupContracts.swift`. If needed for exclusive directory rename, add a narrow wrapper to existing `Sources/CChauffeur/CChauffeur.c` and its public header.

**Interfaces:** `CopyReceipt` contains `operationID: UUID`, `destinationPath: String`, `files: [String: String]`. `ConfigurationPublisher` consumes FileStore and migration adapters; exposes `publish(operation: SetupOperation, preview: CopyPreview, pair: SetupAgentPair) async throws -> CopyReceipt` and `recover(operation: SetupOperation) async throws -> SetupOperation`.

- [ ] Build a temporary-directory fixture with injected interruption points after journal write, staging completion, publication, and receipt update. Verify source digests never change and an existing destination is never replaced.

```swift
// Within the fixture, use the same operation ID on both attempts.
let first = try await publisher.publish(operation: operation, preview: preview, pair: pair)
let resumed = try await publisher.publish(operation: operation, preview: preview, pair: pair)
#expect(resumed.destinationPath == first.destinationPath)
#expect(resumed.operationID == first.operationID)
```

- [ ] Run `swift test --filter ConfigurationPublisherTests` to establish failure.
- [ ] Persist the prepared journal before writes; create 0700 staging beside destination. Write validated selected contents, reject traversal and link races, and record relative-path digests plus a unique ownership marker in staging before publication. Use no-replace rename semantics on macOS (`renamex_np` with `RENAME_EXCL`), not a check followed by an overwriting rename.
- [ ] Reconcile a destination only if the recorded operation marker matches; never claim another process's directory. Once published, never recopy over user changes on retry. Record changed files as a recovery warning while preserving them. Remove only owned unpublished staging on draft discard. Keep successful receipts for later team publication.
- [ ] Test destination created during staging, disk/write failures, changed published files, and runtime failure immediately after rename. Re-run suite and commit.

## Task 5: Verify authentication in the same context as agent launch

**Files:** Create the three authentication files and `SetupEnvironment.swift`; modify existing `Sources/ChauffeurCore/Validation.swift` to reuse sanitization without changing existing launch grants. Create `Tests/ChauffeurRuntimeTests/Onboarding/AgentAuthenticationTests.swift` and `Tests/ChauffeurCoreTests/Onboarding/SetupEnvironmentTests.swift`.

**Interfaces:** `SetupCommand` contains `executable: String`, `arguments: [String]`, `directory: String`, `environment: [String: String]` and is runtime-only, not persisted. `AuthenticationContext` contains `kind: CLIKind`, `executable: String`, `configurationPath: String`, `baseEnvironment: [String: String]`, `workingDirectory: String`. `AgentAuthentication` exposes `loginCommand(context:) async throws -> SetupCommand`, `status(context:) async -> SetupAuthStatus`. Adapters accept an injected command runner matching `ProcessRunner` result semantics. `SetupEnvironment.make(base:kind:directory:) -> [String: String]` applies the existing LaunchPolicy denied lists and assigns the explicit profile variable.

- [ ] Add fake CLI scripts that report method/identity, capture only selected environment keys, simulate unknown output, and return authenticated/unauthenticated/timeout states. Do not emit a real environment dump.

```swift
@Test func inheritedAuthenticationCannotSelectAnotherProfile() {
    let env = SetupEnvironment.make(base: ["PATH": "/bin", "ANTHROPIC_API_KEY": "fixture",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/other", "CLAUDE_CONFIG_DIR": "/wrong"],
        kind: .claude, directory: "/profiles/work")
    #expect(env["CLAUDE_CONFIG_DIR"] == "/profiles/work")
    #expect(env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    #expect(env["ANTHROPIC_API_KEY"] == nil)
}
```

- [ ] Run `swift test --filter SetupEnvironmentTests` and `swift test --filter AgentAuthenticationTests` to establish failure.
- [ ] Use `codex login` / `codex login status` and `claude auth login` / `claude auth status --json`, with command availability checked from help and supported-output fixtures. Inspect status output only in fresh unauthenticated temporary profiles to establish negative-output contracts. Never call logout or status against the user's live profile during implementation.
- [ ] Use the same explicit profile environment for login, status, and later sessions. Extract common sanitization from LaunchPolicy; retain existing project/session grant insertion exclusively in normal launches. Preserve required transport/certificate behavior consistently instead of stripping it only in setup. Use a neutral wizard-owned working directory for status/login to avoid loading unrelated repository configuration.
- [ ] Preserve the reference tools' directory-based credential behavior. Do not introduce a new credential store, globally force file storage, or modify existing profile backend settings. Validate directory isolation for supported versions/backends; if a selected backend cannot be shown to isolate, return Unable to verify with actionable instructions instead of silently writing global credentials. Environment-only API credentials stripped by normal Chauffeur launches must also be absent during verification; explain that such a profile needs compatible configuration.
- [ ] Require known status output plus the matching exit code. Claude JSON identity fields are optional. Codex text output may provide only authentication method; leave email/organization unset. Unknown schema, output truncation, stderr errors or timeout produce Unable to verify. Never persist full status output or credential fragments. Already-cached login is reported as CLI-reported sign-in, not an online quota/access check.
- [ ] Test expired/negative status, unknown newer output, missing binary, wrong identity display, matching login/launch profile variables, and no token/session grant in setup environment. Run suites plus `swift test --filter ShellAgentEnvironmentTests`; commit.

## Task 6: Runtime-owned login terminal and setup orchestration

**Files:** Create `SetupLoginHost.swift`, `OnboardingCoordinator.swift`, `OnboardingDispatch.swift`; modify existing `RuntimeCoordinator.swift` and `IPCServer.swift` at their dispatch/initialization boundaries. Create `Tests/ChauffeurRuntimeTests/Onboarding/SetupLoginHostTests.swift` and `OnboardingCoordinatorTests.swift`.

**Interfaces:** `SetupLoginHandle` (Codable/Sendable) contains `operationID: UUID`, `generation: UInt64`, `phase: SetupAuthPhase`. `SetupLoginHost.start(operationID:command:) async throws -> SetupLoginHandle`, `input(operationID:generation:bytes:) async throws`, `resize(operationID:generation:cols:rows:) async throws`, `cancel(operationID:) async throws`. Output attachment uses existing `TerminalOutputSink` and framing, with a setup-specific attach method; the host issues new generations on controller takeover. `OnboardingCoordinator.handle(_ request: IPCRequest) async throws -> JSONValue` owns all methods below and exposes its login host for IPC attachment routing.

| Local IPC method | Parameters | Result |
| --- | --- | --- |
| `setupInventory` | none | `SetupInventory` |
| `setupDraft` | none | optional `Stored<SetupDraft>` |
| `saveSetupDraft` | record, expectedVersion | `Stored<SetupDraft>` |
| `previewSetupCopy` | draftID, pairID, expectedVersion | `CopyPreview` |
| `createSetupConfiguration` | draftID, pairID, previewID, expectedVersion | `CopyReceipt` |
| `verifySetupAuthentication` | draftID, pairID | `SetupAuthStatus` |
| `startSetupLogin` | draftID, pairID | `SetupLoginHandle` |
| `cancelSetupLogin` | operationID | cancellation acknowledgement |
| `attachSetupLogin` | operationID, dimensions, takeControl | generation then terminal frames |
| `finishSetup` | draftID, expectedVersion, defaultTeamID | `[UUID]` saved team IDs |
| `discardSetup` | draftID, expectedVersion | acknowledgement; published files retained |

- [ ] Write fake-PTY lifecycle tests and coordinator integration tests with temporary FileStore, fake auth adapters, and fake migration adapters. Assert setup doesn't create Session records:

```swift
let before = await store.reload().sessions.count
_ = try await coordinator.handle(IPCRequest("startSetupLogin", params: params))
#expect(await store.reload().sessions.count == before)
```

- [ ] Run `swift test --filter SetupLoginHostTests` and `swift test --filter OnboardingCoordinatorTests`; confirm failure.
- [ ] Implement PTY ownership using existing `chauffeur_spawn_pty` primitives, with nonblocking reads, bounded in-memory scrollback, resize, child reaping and process-group cancellation. No shell interpolation for executable/arguments. Closing an attachment leaves login running; cancellation terminates only that operation. Never archive login terminal contents into conversation history or runtime diagnostics.
- [ ] Route `attachSetupLogin` separately in IPCServer; apply current-user socket authorization and generation checks to input, resize and detach. Reuse wire framing and adapter behavior without fake Session IDs. Keep remote operation allowlists unchanged. A second login request returns the active operation or an actionable busy result, never a parallel browser flow.
- [ ] On login exit, move to Verifying and run the adapter; only its result may set Connected. On runtime startup, reconcile the journal and mark interrupted login retryable. Do not automatically relaunch browser login. Store only redacted outcomes.
- [ ] Use stable IDs to publish teams and custom presets idempotently after each successful configuration; skip pairs without usable directories. Keep pending pairs in the draft and preserve allBase when the chosen agents exactly match available base kinds; otherwise create custom copies. Use `BaseAgentPreset.agent(in:copy:)` and existing version checks, allocating stable copy IDs in the journal before saving. Reuse existing base presets and register selected executables only if none match.
- [ ] Finish saves ready teams, assigns a valid default via existing runtime normalization, and returns team IDs. Completing with pending logins leaves a resumable draft. Discard cancels active login, removes only owned staging, and keeps created folders/teams.
- [ ] Test crash between folder publication and team save; repeat finish without duplicate presets; conflicting team edits; two windows cancelling/replacing attachments; shared-path single verification; app detach/reconnect; unavailable runtime. Run the two suites and existing `TeamAgentRuntimeTests`, then commit.

## Task 7: Build and integrate the native wizard

**Files:** Create all App/Onboarding files in the map. Modify existing `WelcomeView.swift`, `SettingsView.swift`, `AppModel.swift`, `ProjectEditor.swift`, and `ChauffeurApp.swift`. Create `Tests/ChauffeurAppUITests/Onboarding/OnboardingWizardTests.swift` and `OnboardingUIFixture.swift`. Use existing `project.yml` source-directory inclusion; regenerate with `make gen`.

**Interfaces:** `@MainActor OnboardingModel: ObservableObject` owns `draft: Stored<SetupDraft>?`, `inventory: SetupInventory?`, `busy: Bool`, `error: String?`, and async `load()`, `save()`, `preview(pairID:)`, `create(pairID:)`, `login(pairID:)`, `verify(pairID:)`, `finish() -> [UUID]`. It calls Task 6 IPC through existing AppModel. `OnboardingWizard(onFinished: (UUID?) -> Void)` presents the model. Add `teamID: UUID?` to existing `AppModel.ProjectCreation` and `initialTeamID: UUID? = nil` to `ProjectEditor` initializer; use only if team still exists.

- [ ] Create a UI fixture launching the existing app and runtime in `/tmp` with fake CLI executables. Seed no team for first-run tests and known teams/windows for returning-user tests. Add accessibility IDs prefixed `onboarding.` for every step and primary action.

```swift
// Within OnboardingWizardTests using its isolated app fixture:
app.buttons["onboarding.useCurrent"].click()
app.buttons["onboarding.continue"].click()
XCTAssertTrue(app.buttons["onboarding.openProject"].waitForExistence(timeout: 5))
app.buttons["onboarding.openProject"].click()
XCTAssertTrue(app.staticTexts["Personal"].exists)
```

- [ ] Run `make test-ui XCODEBUILD_ARGS='-only-testing:ChauffeurAppUITests/OnboardingWizardTests'` and confirm the expected missing-wizard failure, not an unrelated fixture/build failure.
- [ ] Build the step views around typed state. Single/multiple/unsure questions are per agent; a single-account path proposes Personal and skips creation/login already verified. Multiple accounts asks about existing folders; mixed/shared configurations show their owning team labels. Keep source/destination controls behind creation, with hidden folders visible in the chooser. Distinguish installation missing, configuration pending, and sign-in pending.
- [ ] Implement checkbox defaults, per-project history selection for Claude, source/destination previews and changed-preview invalidation. Preserve draft text when IPC disconnects; reconcile versions before retrying. Name edits update proposed paths only until the user customizes them or publishes a folder. Prevent duplicate slug destinations while allowing explicit sharing via Use existing.
- [ ] Implement `SetupTerminalController` using `SwiftTermAdapter`, `TerminalEngineAdapterDelegate`, and setup attachment framing. Reuse appearance and input-gating conventions from TerminalController; preserve generation checks and prevent queued keystrokes replaying after reconnect. Show team/agent/directory, login progress, optional identity, Not the right account, Retry, Recheck, Cancel login, and Finish later.
- [ ] Wire first-run presentation only after inventory loads. Existing installations are recognized by existing teams/projects and preserve window restoration. Settings Add Team opens the wizard; Edit Team keeps current direct editor. Save and Finish Later records dismissal; Resume Setup reopens the draft. Retain manually entered existing paths even when temporarily unavailable.
- [ ] Add summary with shared-path labels and default-team picker. Close the wizard before presenting project creation, following WelcomeView's existing sheet-dismiss handoff pattern. Open first project with the chosen saved team; never claim all connected if some pairs remain pending.
- [ ] Run `make gen` and `make build`; inspect generated Xcode groups for `Onboarding` under App/Core/RuntimeKit (Core/RuntimeKit appear within the local package). Do not commit generated project output if repository policy ignores it.
- [ ] Exercise UI tests for first-run, one-account fast path, mixed shared setup, selection/backtracking, custom paths, save/resume, wrong identity/retry, missing agent, offline runtime, VoiceOver labels/keyboard navigation, and returning-user restoration. Commit tested UI integration.

## Task 8: End-to-end validation and user documentation

**Files:** Modify existing `README.md`, `docs/manual.html`, `docs/compatibility.md`, `docs/building.md`, and app help text in `Sources/ChauffeurApp/ChauffeurApp.swift`. Add `Prototypes/onboarding_smoke.py` using the repository's temporary-runtime fixture conventions.

- [ ] Add an integration fixture that creates one shared Codex profile and two Claude profiles, selects copy categories, simulates successful/failed login, restarts the runtime, resumes, creates a project and inspects its launch configuration. Assert that source digests are unchanged and session counts include only actual project launches. Use fake providers; no network inference.

```python
# Assertions in onboarding_smoke.py after loading the fixture's snapshots:
assert personal["configurationDirectories"]["codex"] == work["configurationDirectories"]["codex"]
assert personal["configurationDirectories"]["claude"] != work["configurationDirectories"]["claude"]
assert resumed_team_ids == initial_team_ids
assert source_digests_after == source_digests_before
```

- [ ] Run `python3 Prototypes/onboarding_smoke.py` and fix any integration failures with focused regression coverage.
- [ ] Run `make test`, `make build`, and `make test-ui`. Inspect failures and report any environment-limited UI checks accurately. Run existing `python3 Prototypes/team_agents_smoke.py` if its documented fixture prerequisites are available; don't run unrelated provider-backed suites.
- [ ] Perform isolated manual browser-login acceptance for both supported agents using designated test profiles/accounts. Verify that login produces the intended method/identity and another profile retains its account; cancel and retry once. If test accounts are unavailable, leave this acceptance explicitly unverified and request that concrete input rather than using personal profiles.
- [ ] Update docs and help to describe the wizard, source-preserving copies, shared configurations, pending logins, Resume Setup, and unsupported-version behavior. Remove claims that Chauffeur never creates configuration folders or assists sign-in. Record actual tested CLI versions and distinguish status detection from provider-access testing.
- [ ] Review the final diff against all nine acceptance items in the spec, run `git diff --check`, and commit. Report changed behavior, test evidence and any remaining manual acceptance limitation. Do not merge or install into `/Applications` as part of this plan.

## Execution and review

Tasks 1–6 share persistence, operation and terminal contracts; implement them sequentially. Migration and authentication fixtures can be reviewed independently once the contracts exist. Native execution in this session is recommended to keep those interfaces consistent, followed by a fresh whole-branch review. Subagent-driven execution remains an option if the user prefers per-task independent review.

No product code was changed while writing this plan. Review this plan and select the execution method before implementation, as required by the planning workflow.
