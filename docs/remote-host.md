# Remote servers on the Mac

- Date: 2026-10-10
- Status: pairing, the session list and live terminals were checked against a
  [Linux server](linux.md). Launching and stopping use the same client calls as the iPhone app.

The Mac app can be a remote client of another Chauffeur runtime, the same way the iPhone
app is ([mobile remote control](mobile-remote.md)). Sessions, checkouts and processes stay
on the server; the Mac only shows them.

## Using it

1. On the server, print a pairing code: `Scripts/linux/pair.sh` on a Linux server, or
   **Settings ▸ Remote Access ▸ Pair iPhone…** on another Mac. Codes expire after 120 s.
2. On this Mac, choose **File ▸ Remote Servers ▸ Manage Remote Servers…** (⇧⌘R), enter the
   server's address, its main port (51847 for Release runtimes; pairing uses the next port)
   and the code, then **Pair and Open**.
3. Each paired server has its own window, opened from **File ▸ Remote Servers**, from the
   menu bar icon, or with **Open** in Manage Remote Servers. The window connects when it opens
   and its subtitle shows the connection state; **Reconnect** appears when it drops.
4. The window lists the server's live sessions by project. Selecting one attaches its
   terminal. If the iPhone (or another Mac) controls that terminal, **Take Control** moves it
   here; the other device can take it back the same way.
5. **New Session** (⌥⌘N) starts an agent or shell in an existing checkout or a new worktree.
6. **Stop** (in the terminal header or the session's context menu) appears only when the
   server advertises `session.stop.v1`; older servers don't.
7. Closing a server's window detaches its terminals and closes the connection.

Paired servers are saved in `<data root>/remote-hosts.json` (mode 0600), not the keychain:
the Mac app has no data-protection keychain entitlement. The menu bar helper reads only their
names from it. Use **Forget…** in Manage Remote Servers to remove one; the server keeps the device until it is revoked there.

## Not included

- Progress panels, file upload and session links.
- Remote projects in the regular project window.
- Terminal history and search (they read local files on the runtime's host).
- Dropping files on a remote terminal (local paths mean nothing on the server).
