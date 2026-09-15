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
for task_binary in ChauffeurRuntime chauffeurctl; do
  cp "$task_binary_dir/$task_binary" "$task_app_dir/MacOS/$task_binary"
  /usr/bin/codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$task_app_dir/MacOS/$task_binary"
done
cp "$SRCROOT/Resources/launchd/dev.chauffeur.runtime.plist" "$task_app_dir/Library/LaunchAgents/"
