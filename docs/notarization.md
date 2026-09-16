# Releases and notarization

The [release workflow](../.github/workflows/release.yml) runs in GitHub Actions
when a version tag is pushed. It builds Chauffeur for Apple Silicon with Xcode
26.3, signs the app and embedded executables with Developer ID and secure
timestamps, creates a DMG with an Applications shortcut, and submits it to Apple.
Only after Apple accepts the submission and the stapled ticket passes validation
does it attach `Chauffeur.dmg` to the GitHub Release. The DMG is also saved as a
workflow artifact; failed submissions retain available notarization diagnostics.

## One-time GitHub setup

Configure these Actions secrets and variables in the
[Chauffeur repository settings](https://github.com/cliq/chauffeur/settings/secrets/actions).
These are the same names used by Claude Monitor's release workflow:

| Name | Store as | Value |
| --- | --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Secret | Base64-encoded Developer ID Application `.p12`, including its private key. |
| `P12_PASSWORD` | Secret | Password used when exporting that `.p12`. |
| `KEYCHAIN_PASSWORD` | Secret | A nonempty password for the temporary runner keychain. |
| `TEAM_ID` | Variable | Apple Developer Team ID associated with the certificate. |
| `NOTARY_KEY_BASE64` | Secret | Base64-encoded App Store Connect API `.p8` key. |
| `NOTARY_KEY_ID` | Variable | API key ID. |
| `NOTARY_ISSUER_ID` | Variable | API key issuer UUID. |

The same certificate and API key used by Claude Monitor can be used here when
releasing under the same Apple Developer team. Repository secrets are not shared
automatically, and GitHub does not allow reading their values back. Populate them
from the original credentials, or grant this repository access to organization
secrets. Never commit certificates, private keys, or passwords. Credentials are
imported into a temporary keychain and removed at the end of the job.

## Publish a release

Commit and push the release changes, including the workflow, then tag the intended
commit:

```sh
git tag -a v1.0 -m "v1.0"
git push origin v1.0
```

Tags must have the form `vX.Y` or `vX.Y.Z`. The tag supplies the app's marketing
version; the Actions run number supplies its build number. A manual run must
also select an existing version tag, for example:

```sh
gh workflow run release.yml --ref v1.0
```

The workflow must exist on the default branch for manual dispatch. A manual run
on a tag also publishes or updates that tag's release.

## Local builds

`make release` still only builds, signs, and verifies locally. It does not contact
Apple's notary service or publish anything. Notarization can also run on a local
Mac with the same credentials and Apple's `xcrun notarytool` and `xcrun stapler`;
GitHub Actions is where this project's automated release process runs.

For a local build intended for subsequent notarization, explicitly enable secure
timestamps for the embedded helpers and the final app signature:

```sh
make release CODESIGN_FLAGS=--timestamp \
  XCODEBUILD_ARGS="CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM=YOUR_TEAM_ID CHAUFFEUR_NOTARIZE=1 OTHER_CODE_SIGN_FLAGS='--timestamp --options=runtime'"
```

See Apple's [notarization workflow documentation](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
for submitting and stapling locally.
