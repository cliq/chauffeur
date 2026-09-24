# Appearance

Open **Chauffeur → Settings → Appearance** and choose a theme:

- **System** follows the Mac's appearance and is the default.
- **Light** keeps Chauffeur light regardless of the system setting.
- **Dark** keeps Chauffeur dark regardless of the system setting.

The choice applies immediately to all app windows and is saved for future
launches. Both themes use the warm orange accent, adjusted for their backgrounds.

Terminal default foreground, background, and cursor colors follow the setting,
including saved-history views. Changing the theme preserves terminal text and
does not restart or reconnect sessions. Explicit colors drawn by an agent remain
under that CLI's control; use the CLI's own theme setting when needed.

## Terminal font and colors

The **Terminal** section of the same pane sets the default look of every terminal:

- **Font** lists the installed monospaced families; **Default** is Ghostty's built-in
  JetBrains Mono. **Size** ranges from 8 to 32 points.
- **Light Mode Colors** and **Dark Mode Colors** pick a color theme for each system
  appearance from a curated list (Catppuccin, Dracula, GitHub, Gruvbox, Nord, Solarized,
  Tokyo Night, and more). **System** keeps the default colors described above.

Changes apply to open terminals immediately, without reconnecting or losing their text,
and are saved for future launches. A font change resizes the terminal grid, and the
session's process sees an ordinary window resize.

**View ▸ Bigger** (⌘+ or ⌘=), **Smaller** (⌘−) and **Actual Size** (⌘0) zoom only the
selected terminal. Zoom is not saved: a terminal opened later, or reopened, uses the size
from Settings.

## Verification

Native previews use a separate app identifier and an isolated socket. They check
light/dark/system resolution across windows, default text/background/cursor
contrast, colors in newly created terminals, and unchanged terminal buffers.
Four app launches check initial System behavior and persistence of Dark, Light,
and System selections. Reports are under
`.local/appearance-preview/`. These are focused native view checks, not a real
CLI workload or a change to the Mac's system appearance.
