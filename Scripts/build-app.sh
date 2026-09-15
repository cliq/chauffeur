#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
task_identity=${CHAUFFEUR_SIGN_IDENTITY:--}
xcodebuild -project Chauffeur.xcodeproj -scheme Chauffeur -configuration "${1:-Debug}" -derivedDataPath build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation CHAUFFEUR_SIGN_IDENTITY="$task_identity" build
# Xcode can skip the outer CodeSign task when only an embedded Swift-package
# executable changed. Seal the completed bundle after the embedding script.
task_app="$PWD/build/Build/Products/${1:-Debug}/Chauffeur.app"
/usr/bin/codesign --force --sign "$task_identity" --preserve-metadata=identifier,entitlements,flags,runtime "$task_app"
/usr/bin/codesign --verify --deep --strict "$task_app"
printf '\nApp: %s/build/Build/Products/%s/Chauffeur.app\n' "$PWD" "${1:-Debug}"
