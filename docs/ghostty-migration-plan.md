# Ghostty migration plan (desktop)

Replace SwiftTerm with Ghostty in the macOS app. The iOS client keeps SwiftTerm for now, behind
the same `TerminalEngineAdapter`. Follows the strategy in `docs/mobile-poc-implementation-plan.md`
and `docs/decisions/M1-mobile-transport-and-terminal.md`.

## Survey

The five most-starred macOS apps embedding libghostty (cmux, OmniWM, Supacode, Muxy, rootshell)
all write their own view on the C API. Most let Ghostty own a PTY running an attach client
(`zmx attach`, a session daemon, a login shell); the ones with several clients per session
(cmux's remote tmux, rootshell everywhere) feed bytes from the host instead. Upstream `ghostty.h`
has no host-fed I/O, so every host-fed integration carries a patch.

## Decisions

- **Library**: [libghostty-spm](https://github.com/Lakr233/libghostty-spm) pinned with
  `exact: "1.6.20260922"` (Ghostty `3c47ca159368`, MIT), using only its `GhosttyKit` product (the
  C API). Prebuilt, checksummed xcframework; no Zig in our build. If the package stalls, its
  `build.sh` rebuilds the same patch stack from upstream. Upgrades are deliberate pin bumps that
  rerun the validation below.
- **I/O model**: host-managed (`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`). The runtime keeps
  owning the tmux attachment, the generation/take-control protocol and the wire format; nothing in
  `ChauffeurRuntimeKit` changes. Letting Ghostty spawn `tmux attach` itself was rejected: it
  bypasses the runtime's single-controller attachment and moves the input gate into the view.
- **Own view**: `ChauffeurTerminalGhostty` owns an `NSView` around `ghostty_surface_t`, one shared
  `ghostty_app_t` per configuration, and the runtime callbacks. Ghostty types stay inside the
  module, as SwiftTerm types stay inside `ChauffeurTerminalSwiftTerm`. MIT code from
  libghostty-spm's wrapper and Muxy may be adapted with attribution; cmux (GPL), OmniWM (GPL) and
  Supacode (FSL) are reference only.
- **Output off the main thread**: `ghostty_surface_write_buffer` parses synchronously and can block
  on the app mailbox, so output goes through a per-surface serial queue; the main thread ticks
  the app while it waits. The queue drains before `ghostty_surface_free`.
- **One input exit**: every byte Ghostty generates (typing, paste, protocol replies) arrives in
  `receive_buffer`. The adapter hops it to the main actor and applies the input gate there, so
  "dropped, never queued" holds for all of it. Replies must reach tmux (it queries its outer
  terminal), so they are not filtered.
- **Keys encoded by the engine**: `sendKey` becomes a Ghostty key press, `paste` uses
  `ghostty_surface_text`, so application cursor, bracketed paste and the kitty keyboard protocol
  follow Ghostty's live modes. Ghostty exposes no mode query, so `modes` leaves the adapter
  protocol; `TerminalKeyEncoder` stays for SwiftTerm and the fake adapter.
- **Resize handshake**: cell-size reports come from `receive_resize` (after Ghostty applied the
  grid), not from view layout, so tmux never redraws into a stale grid.
- **App owns shortcuts and config**: we generate the whole Ghostty config (never load
  `~/.config/ghostty`), start with `keybind = clear`, and add back only Terminal.app word
  navigation (`alt+left=esc:b`, `alt+right=esc:f`, `alt+backspace=text:\x1b\x7f`) with
  `macos-option-as-alt`. The main menu keeps Copy/Paste/Select All/Find. This replaces
  `ThemedTerminalView.sendWordNavigation` and the `ProjectWindow` key-monitor hook.
- **Find**: Ghostty's native search (`search:<text>`, `navigate_search:next|previous`,
  `end_search`, with `SEARCH_TOTAL`/`SEARCH_SELECTED` for the count) behind engine-neutral adapter
  methods, and our own find bar in the history sheet instead of `NSTextFinder`.
- **History replay**: the read-only history sheet feeds the snapshot with
  `ghostty_surface_write_buffer_replay`, which suppresses protocol replies.
- **Accessibility**: `.textArea` with the visible rows from `ghostty_surface_read_text`, cached
  briefly, read-only (upstream Ghostty's approach).
- **Colors**: light and dark palettes from `NSColor.textColor` / `textBackgroundColor`, switched
  with `ghostty_app_set_color_scheme` on appearance changes.

## Phases

1. **Engine module** — `ChauffeurTerminalGhostty` (macOS): app/config runtime, surface view
   (Metal layer, sizing, occlusion, focus), key and IME input (`NSTextInputClient`), mouse and
   scroll, selection/copy/paste, file drops, accessibility, search, and `GhosttyTerminalAdapter`.
2. **Desktop** — `TerminalController`, history sheet, setup login terminal and the native probe
   use the Ghostty adapter; `ThemedTerminalView` and the SwiftTerm imports leave `ChauffeurApp`.
3. **Cleanup** — SwiftTerm leaves the macOS target in `project.yml` (iOS keeps it), comments in
   `TmuxHost.swift`, the M1 decision record and docs updated.
4. **Validation** — package tests, `make build`, iOS build unchanged, native probe and UI smokes,
   then the manual checklist carried over from `SwiftTermAdapter.swift` (typing/echo, cursor keys
   in `less`/`vim`, bracketed paste, input gate, resize, title/bell/OSC 52, links, reset + redraw,
   selection, Unicode/wide glyphs, alternate screen, IME, conformance check).

## Known risks

- The package tracks upstream `main` and patches it; the embedding API is unstable upstream.
- tmux runs with mouse reporting, so wheel scrolling scrolls tmux history, not Ghostty's; search
  in the live terminal only sees what Ghostty holds. The history sheet remains the searchable view.
- The surface exists only once the view is in a window with a size; bytes that arrive earlier are
  buffered by the adapter and `cellSize` falls back to a default until the first grid report.
