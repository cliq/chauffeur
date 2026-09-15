#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Chauffeur.xcodeproj -scheme Chauffeur -configuration "${1:-Debug}" -derivedDataPath build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation build
printf '\nApp: %s/build/Build/Products/%s/Chauffeur.app\n' "$PWD" "${1:-Debug}"
