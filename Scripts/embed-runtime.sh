#!/bin/bash
set -euo pipefail
task_config=debug
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then task_config=release; fi
cd "$SRCROOT"
/usr/bin/env swift build -c "$task_config" --product ChauffeurRuntime
/usr/bin/env swift build -c "$task_config" --product chauffeurctl
task_binary_dir=$(/usr/bin/env swift build -c "$task_config" --show-bin-path)
task_app_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
mkdir -p "$task_app_dir/MacOS" "$task_app_dir/Library/LaunchAgents"
task_stage=$(mktemp -d "$task_app_dir/MacOS/.chauffeur-embed.XXXXXX")
trap 'rm -rf "$task_stage"' EXIT
for task_binary in ChauffeurRuntime chauffeurctl; do
  # Replace executable inodes atomically; do not overwrite a Mach-O that launchd
  # may have mapped or whose code signature the kernel has already cached.
  cp "$task_binary_dir/$task_binary" "$task_stage/$task_binary"
  /usr/bin/codesign --force --options runtime --sign "${CHAUFFEUR_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:--}}" "$task_stage/$task_binary"
  mv -f "$task_stage/$task_binary" "$task_app_dir/MacOS/$task_binary"
done
cp "$SRCROOT/Resources/launchd/dev.chauffeur.runtime.plist" "$task_stage/dev.chauffeur.runtime.plist"
# Bind the job to the helper's signing identity, or its exact code hash for an
# ad-hoc build. Generate the constraint from the already-signed executable.
/usr/bin/python3 "$SRCROOT/Scripts/runtime-launch-constraint.py" "$task_app_dir" "$task_stage/dev.chauffeur.runtime.plist"
mv -f "$task_stage/dev.chauffeur.runtime.plist" "$task_app_dir/Library/LaunchAgents/"
