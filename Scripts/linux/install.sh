#!/usr/bin/env bash
# Builds the headless runtime and chauffeurctl, installs them in ~/.local/lib/chauffeur and
# runs the runtime as a systemd user service. Rerun it to update; sessions keep running.
# Requires Swift 6.2 or later, libssl-dev, libsqlite3-dev and tmux. See docs/linux.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
# swiftly installs Swift per user, and a non-login shell may not have its environment.
if ! command -v swift >/dev/null && [ -f "$HOME/.local/share/swiftly/env.sh" ]; then source "$HOME/.local/share/swiftly/env.sh"; fi

# A static Swift runtime keeps the binaries working when the toolchain is updated or removed.
# Swift 6.4's default swiftbuild system leaves Foundation's ICU library out of that link.
build=(swift build -c release --static-swift-stdlib --build-system native)
"${build[@]}" --product ChauffeurRuntime
"${build[@]}" --product chauffeurctl
bin=$("${build[@]}" --show-bin-path)
dest="$HOME/.local/lib/chauffeur"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$dest" "$HOME/.local/bin" "$unit_dir"

# Replace each file with a rename, so the running service keeps its old executable until restarted.
for name in ChauffeurRuntime chauffeurctl; do
    install -m 755 "$bin/$name" "$dest/.$name.new"
    mv -f "$dest/.$name.new" "$dest/$name"
done
# Bundled skills and plugins, found next to the executable.
for resources in "$bin"/*.resources; do
    name=$(basename "$resources")
    rm -rf "$dest/.$name.new"
    cp -R "$resources" "$dest/.$name.new"
    rm -rf "$dest/$name"
    mv "$dest/.$name.new" "$dest/$name"
done
ln -sf "$dest/chauffeurctl" "$HOME/.local/bin/chauffeurctl"

cat > "$unit_dir/chauffeur.service" <<UNIT
[Unit]
Description=Chauffeur runtime (agent sessions and remote access)

[Service]
ExecStart=$dest/ChauffeurRuntime
Restart=on-failure
RestartSec=3
# Sessions live in a tmux server the runtime starts. Stop only the runtime, so agents
# keep running across restarts and updates, as with the macOS LaunchAgent.
KillMode=process
LimitNOFILE=65536

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable chauffeur.service
systemctl --user restart chauffeur.service

for _ in $(seq 20); do
    if "$dest/chauffeurctl" status >/dev/null 2>&1; then break; fi
    sleep 0.5
done
systemctl --user --no-pager status chauffeur.service | head -5
user=$(id -un)
if [ "$(loginctl show-user "$user" --property=Linger --value 2>/dev/null)" != "yes" ]; then
    echo "The service stops when you log out. To keep it running: sudo loginctl enable-linger $user"
fi
