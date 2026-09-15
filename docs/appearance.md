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

## Verification

Native previews use a separate app identifier and an isolated socket. They check
light/dark/system resolution across windows, default text/background/cursor
contrast, colors in newly created terminals, and unchanged terminal buffers.
Four app launches check initial System behavior and persistence of Dark, Light,
and System selections. Reports are under
`.local/appearance-preview/`. These are focused native view checks, not a real
CLI workload or a change to the Mac's system appearance.
