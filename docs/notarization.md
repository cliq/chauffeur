# Releases and notarization

The [release workflow](../.github/workflows/release.yml) runs in GitHub Actions
when a version tag is pushed. It runs [`Scripts/distribute.sh`](../Scripts/distribute.sh),
the same script used for local releases, which:

1. builds Chauffeur for Apple Silicon and signs the app and embedded executables
   with Developer ID, the hardened runtime, and secure timestamps;
2. notarizes the app and staples its ticket, so a copy dragged out of the DMG
   passes Gatekeeper even offline;
3. wraps it in a styled drag-to-Applications DMG (background in
   `Resources/dmg/background.tiff`), then signs, notarizes, and staples the DMG.

Only after both submissions are accepted and every check passes does the workflow
attach `Chauffeur.dmg` to the GitHub Release. The DMG is also saved as a workflow
artifact; failed submissions keep Apple's notarization logs as diagnostics.

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

To rehearse a release before tagging, run the workflow from a branch. It builds
and notarizes the version in `project.yml` and keeps the DMG as a workflow
artifact, but publishes nothing:

```sh
gh workflow run release.yml --ref main
```

## Local releases

`make release` only builds, signs, and verifies. To produce the same notarized DMG
as CI on your Mac, install `create-dmg` (`brew install create-dmg`), store
notarization credentials once, and run the distribution script with a version and
build number:

```sh
xcrun notarytool store-credentials chauffeur-notary \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer YOUR_ISSUER_UUID
CHAUFFEUR_NOTARY_PROFILE=chauffeur-notary Scripts/distribute.sh 1.4.0 1
```

It signs with the Developer ID identity from `Configuration/LocalSigning.xcconfig`
(override with `CHAUFFEUR_DEVELOPER_ID` and `CHAUFFEUR_TEAM_ID`) and writes
`dist/Chauffeur.dmg`. Nothing is published. macOS may ask to let your terminal
control Finder the first time, while `create-dmg` lays out the DMG window.
`Scripts/distribute.sh --help` lists every option, including passing an API key
file directly instead of a Keychain profile.

See Apple's [notarization workflow documentation](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
for submitting and stapling locally.
