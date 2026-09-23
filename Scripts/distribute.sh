#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: Scripts/distribute.sh VERSION BUILD_NUMBER

Build Chauffeur with Developer ID, notarize and staple the app, then wrap it in a
signed, notarized, and stapled DMG at dist/Chauffeur.dmg. Nothing is published.

Signing (optional; defaults come from Configuration/LocalSigning.xcconfig):
  CHAUFFEUR_DEVELOPER_ID     Developer ID Application identity name or SHA-1
                             (default: "Developer ID Application")
  CHAUFFEUR_TEAM_ID          Apple Developer Team ID

Notarization credentials (choose one):
  CHAUFFEUR_NOTARY_PROFILE   notarytool Keychain profile (xcrun notarytool store-credentials)
  CHAUFFEUR_NOTARY_KEY_PATH  App Store Connect API key (.p8)
  CHAUFFEUR_NOTARY_KEY_ID    API key ID (required with KEY_PATH)
  CHAUFFEUR_NOTARY_ISSUER_ID Issuer UUID (required for a team API key)

Example: Scripts/distribute.sh 1.4.0 12
EOF
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
if (( $# != 2 )); then usage >&2; exit 1; fi
version=$1
build_number=$2
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo 'Use a numeric version (e.g. 1.4 or 1.4.0) and a positive integer build number.' >&2
  exit 1
fi

command -v create-dmg >/dev/null || { echo 'Install create-dmg first: brew install create-dmg' >&2; exit 1; }
if [[ -n "${CHAUFFEUR_NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$CHAUFFEUR_NOTARY_PROFILE")
elif [[ -n "${CHAUFFEUR_NOTARY_KEY_PATH:-}" ]]; then
  : "${CHAUFFEUR_NOTARY_KEY_ID:?Set CHAUFFEUR_NOTARY_KEY_ID for the API key.}"
  [[ -f "$CHAUFFEUR_NOTARY_KEY_PATH" ]] || { echo 'Notarization API key file does not exist.' >&2; exit 1; }
  notary_args=(--key "$CHAUFFEUR_NOTARY_KEY_PATH" --key-id "$CHAUFFEUR_NOTARY_KEY_ID")
  if [[ -n "${CHAUFFEUR_NOTARY_ISSUER_ID:-}" ]]; then notary_args+=(--issuer "$CHAUFFEUR_NOTARY_ISSUER_ID"); fi
else
  echo 'Set CHAUFFEUR_NOTARY_PROFILE, or CHAUFFEUR_NOTARY_KEY_PATH and CHAUFFEUR_NOTARY_KEY_ID.' >&2
  exit 1
fi
# Reject bad credentials before spending time on a build.
xcrun notarytool history "${notary_args[@]}" --output-format json >/dev/null

identity=${CHAUFFEUR_DEVELOPER_ID:-Developer ID Application}
xcodebuild_args="ARCHS=arm64 CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='$identity' CHAUFFEUR_NOTARIZE=1"
xcodebuild_args+=" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS='--timestamp --options=runtime'"
xcodebuild_args+=" MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$build_number"
if [[ -n "${CHAUFFEUR_TEAM_ID:-}" ]]; then xcodebuild_args+=" DEVELOPMENT_TEAM=$CHAUFFEUR_TEAM_ID"; fi
make release CODESIGN_FLAGS=--timestamp XCODEBUILD_ARGS="$xcodebuild_args"

built_app=build/Build/Products/Release/Chauffeur.app
signing_identity=$(cat build/Build/Products/Release/Chauffeur.signing-identity)
# Never ship an ad-hoc or Apple Development signature.
if ! codesign --display --verbose=2 "$built_app" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
  echo 'The app is not signed with a Developer ID Application certificate.' >&2
  exit 1
fi

# Notarization rejects executables that keep the debugging entitlement.
python3 - "$built_app" <<'PY'
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
executables = [path for path in sorted(app.glob("**/Contents/MacOS/*")) if path.is_file()]
if not executables:
    sys.exit("No release executables found")
for executable in executables:
    result = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(executable)],
                            check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    if entitlements.get("com.apple.security.get-task-allow"):
        sys.exit(f"{executable} has get-task-allow enabled")
    print(f"Notarization entitlements OK: {executable}")
PY

mkdir -p dist build
staging=$(mktemp -d build/distribution.XXXXXX)
trap 'rm -rf -- "$staging"' EXIT
rm -f build/notarization-*.json

# Submit, then keep Apple's log beside the result in build/ for diagnostics.
notarize() {
  local artifact=$1 label=$2 result="build/notarization-$2.json" submission_id status
  xcrun notarytool submit "$artifact" "${notary_args[@]}" --wait --timeout 30m --output-format json > "$result" || true
  cat "$result"
  if ! submission_id=$(plutil -extract id raw "$result" 2>/dev/null); then
    echo "Notarization returned no submission ID for the $label." >&2
    return 1
  fi
  status=$(plutil -extract status raw "$result" 2>/dev/null || echo Unknown)
  xcrun notarytool log "$submission_id" "${notary_args[@]}" "build/notarization-$label-log.json" || true
  if [[ "$status" != Accepted ]]; then
    echo "Apple did not accept the $label ($status). See build/notarization-$label-log.json." >&2
    return 1
  fi
}

# Staple the app itself so a copy outside the DMG passes Gatekeeper offline.
mkdir "$staging/payload"
app="$staging/payload/Chauffeur.app"
ditto "$built_app" "$app"
ditto -c -k --keepParent "$app" "$staging/Chauffeur.zip"
notarize "$staging/Chauffeur.zip" app
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

# Finder lays out the window through AppleScript; locally, allow the terminal to
# control Finder when asked. create-dmg can exit with -43 on its final UDZO
# conversion while leaving a good read-write image, so finish that one ourselves.
dmg="$staging/Chauffeur.dmg"
if ! create-dmg --volname Chauffeur --volicon "$app/Contents/Resources/AppIcon.icns" \
  --background Resources/dmg/background.tiff --window-pos 200 120 --window-size 600 400 \
  --icon-size 128 --icon Chauffeur.app 150 160 --app-drop-link 450 160 \
  --hide-extension Chauffeur.app --no-internet-enable "$dmg" "$staging/payload"; then
  rw_dmg=$(find "$staging" -maxdepth 1 -name 'rw.*.dmg' | head -1)
  [[ -n "$rw_dmg" ]] || { echo 'create-dmg failed without a recoverable image.' >&2; exit 1; }
  hdiutil convert "$rw_dmg" -format UDZO -o "$dmg"
fi
codesign --sign "$signing_identity" --timestamp --identifier dev.cliq.chauffeur.dmg "$dmg"
notarize "$dmg" dmg
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
hdiutil verify "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

# Expose the DMG only after every submission and check succeeded.
mv -f "$dmg" dist/Chauffeur.dmg
printf '\nReady for distribution: %s/dist/Chauffeur.dmg\n' "$PWD"
