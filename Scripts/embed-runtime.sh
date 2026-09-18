#!/bin/bash
set -euo pipefail
task_config=debug
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then task_config=release; fi
task_service_label=dev.chauffeur.debug.runtime
task_notification_identifier=dev.chauffeur.debug.notifications
task_notification_name="Chauffeur Debug Notifications"
task_sessions_identifier=dev.cliq.chauffeur.debug.sessions
task_sessions_name="Chauffeur Debug Sessions"
if [[ "$task_config" == release ]]; then
  task_service_label=dev.chauffeur.runtime
  task_notification_identifier=dev.chauffeur.notifications
  task_notification_name="Chauffeur Notifications"
  task_sessions_identifier=dev.cliq.chauffeur.sessions
  task_sessions_name="Chauffeur Sessions"
fi
cd "$SRCROOT"
/usr/bin/env swift build -c "$task_config" --product ChauffeurRuntime
/usr/bin/env swift build -c "$task_config" --product chauffeurctl
/usr/bin/env swift build -c "$task_config" --product chauffeur
/usr/bin/env swift build -c "$task_config" --product ChauffeurNotifications
/usr/bin/env swift build -c "$task_config" --product ChauffeurSessions
task_binary_dir=$(/usr/bin/env swift build -c "$task_config" --show-bin-path)
task_app_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
task_identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
task_signing_flags=(--options runtime)
if [[ "${CHAUFFEUR_NOTARIZE:-0}" == 1 ]]; then
  task_signing_flags+=(--timestamp)
fi
mkdir -p "$task_app_dir/MacOS" "$task_app_dir/Library/LaunchAgents"
task_stage=$(mktemp -d "$task_app_dir/MacOS/.chauffeur-embed.XXXXXX")
trap 'rm -rf "$task_stage"' EXIT
for task_binary in ChauffeurRuntime chauffeurctl chauffeur; do
  task_embedded_name="$task_binary"
  # Most macOS volumes are case-insensitive: chauffeur would replace Chauffeur.
  if [[ "$task_binary" == chauffeur ]]; then task_embedded_name=chauffeur-launcher; fi
  if [[ "$task_app_dir/MacOS/$task_embedded_name" -ef "$TARGET_BUILD_DIR/$EXECUTABLE_PATH" ]]; then
    echo "error: Embedded executable $task_embedded_name collides with the app executable" >&2
    exit 1
  fi
  # Replace executable inodes atomically; do not overwrite a Mach-O that launchd
  # may have mapped or whose code signature the kernel has already cached.
  cp "$task_binary_dir/$task_binary" "$task_stage/$task_binary"
  /usr/bin/codesign --force "${task_signing_flags[@]}" --sign "$task_identity" "$task_stage/$task_binary"
  mv -f "$task_stage/$task_binary" "$task_app_dir/MacOS/$task_embedded_name"
done
task_notification_app="$task_stage/ChauffeurNotifications.app"
mkdir -p "$task_notification_app/Contents/MacOS"
cp "$task_binary_dir/ChauffeurNotifications" "$task_notification_app/Contents/MacOS/"
cp "$SRCROOT/Resources/notifications/Info.plist" "$task_notification_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $task_notification_identifier" "$task_notification_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $task_notification_name" "$task_notification_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $task_notification_name" "$task_notification_app/Contents/Info.plist"
/usr/bin/codesign --force "${task_signing_flags[@]}" --sign "$task_identity" "$task_notification_app"
# The old bundle's executable inode remains valid for a running helper.
if [[ -d "$task_app_dir/Library/ChauffeurNotifications.app" ]]; then
  mv "$task_app_dir/Library/ChauffeurNotifications.app" "$task_stage/previous-notifications.app"
fi
mv "$task_notification_app" "$task_app_dir/Library/ChauffeurNotifications.app"
task_sessions_app="$task_stage/ChauffeurSessions.app"
mkdir -p "$task_sessions_app/Contents/MacOS"
cp "$task_binary_dir/ChauffeurSessions" "$task_sessions_app/Contents/MacOS/"
cp "$SRCROOT/Resources/sessions/Info.plist" "$task_sessions_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $task_sessions_identifier" "$task_sessions_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $task_sessions_name" "$task_sessions_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $task_sessions_name" "$task_sessions_app/Contents/Info.plist"
/usr/bin/codesign --force "${task_signing_flags[@]}" --sign "$task_identity" "$task_sessions_app"
# Running owners use immutable copies in Application Support, never this path.
if [[ -d "$task_app_dir/Library/ChauffeurSessions.app" ]]; then
  mv "$task_app_dir/Library/ChauffeurSessions.app" "$task_stage/previous-sessions.app"
fi
mv "$task_sessions_app" "$task_app_dir/Library/ChauffeurSessions.app"
cp "$SRCROOT/Resources/launchd/dev.chauffeur.runtime.plist" "$task_stage/dev.chauffeur.runtime.plist"
/usr/libexec/PlistBuddy -c "Set :Label $task_service_label" "$task_stage/dev.chauffeur.runtime.plist"
# Bind the job to the helper's signing identity, or its exact code hash for an
# ad-hoc build. Generate the constraint from the already-signed executable.
/usr/bin/python3 "$SRCROOT/Scripts/runtime-launch-constraint.py" "$task_app_dir" "$task_stage/dev.chauffeur.runtime.plist"
mv -f "$task_stage/dev.chauffeur.runtime.plist" "$task_app_dir/Library/LaunchAgents/"
# Make reseals the outer bundle after the build with this exact signing identity.
printf '%s\n' "$task_identity" > "$TARGET_BUILD_DIR/Chauffeur.signing-identity"
