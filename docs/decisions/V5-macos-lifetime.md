# V5 — macOS lifetime

Status: native app and LaunchAgent prototype pending.

## Current evidence

The command-line runtime and tmux-owned terminal processes can run without any UI. The fixture smoke test starts the runtime directly, kills it, and restarts it against the same private data directory to reconcile process ownership. This proves neither LaunchAgent registration nor native window restoration.

## Next prototype / chosen candidate

Use SwiftUI `WindowGroup(for: UUID.self)` and a single welcome `Window`, with SwiftTerm hosted through AppKit. Build with XcodeGen. Embed runtime and helper binaries in the app, along with a `SMAppService.agent(plistName:)` LaunchAgent definition. Verify registration and startup from the signed local app before declaring service management available.

Test four project windows on independent Spaces; open the same project twice and confirm focus instead of duplication; restore frames/tabs/splits; close every window and quit/force-quit only the UI while confirming terminal PIDs. Test notification routing with the UI closed. If SMAppService registration is unavailable, record an explicit supported fallback and recovery instructions.

The full V5 gate remains open. No native app or Spaces validation is claimed by the runtime fixture checks.
