# CLI and platform compatibility

Last inspected: 2026-09-15. These are observed development-machine versions,
not a completed real-provider support matrix.

| Component | Version | Current evidence |
| --- | --- | --- |
| macOS | Development Mac; full hardware/OS capture pending release validation | Native Swift runtime builds and fixture integrations run |
| Swift | 6.2.4 | Swift 6 package builds; concurrency checking enabled |
| Xcode | 26.3 (17C529) | Installed; native app build pending |
| tmux | 3.6a | Fixture alternate-screen redraw, resize, input, detachment and runtime restart pass |
| SwiftTerm | 1.20.0 | Pinned; public API inspected; native view integration pending |
| Hummingbird | 2.26.0 | Actual loopback MCP requests exercised with fixture credentials |
| Codex | 0.154.0 | Help, flags, schema generation, isolated sign-in screen observed; authenticated/backend isolation pending |
| Claude Code | 2.1.272 | Help/flags observed; authenticated interactive/MCP validation pending |

## Capability behavior

The adapter checks `--version` and `--help` before spawning an agent. Baseline
versions have a candidate coordination configuration, recorded as unverified.
Other versions require an explicit basic-terminal launch, showing unavailable
coordination/status. Missing `--add-dir` support rejects a multi-directory launch.
Missing native conversation IDs disable resume; no global resume selector is used.

Codex's proposed status path is turn completion through `notify`. It does not
prove approval or input status; these remain unknown when no supported event is
available. Claude uses launch-scoped hooks, which may be affected by native trust
or managed policy. Silence and output volume never set completion.

The shared app-server behavior in Codex must be resolved before marking its
integration supported. See [V3](decisions/V3-mcp-and-status.md). The optional
Chauffeur skill's loading/removal route is also still pending.
