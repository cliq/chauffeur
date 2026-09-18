#!/usr/bin/env python3
"""Create synthetic data in a distinct sandbox app; never reads another app's data.

The certificate-signed owner uses an empty data-access allowlist, replacing
the default same-team exemption. An ad-hoc owner did not trigger AppData checks.
The sandbox container is OS-created; cleanup removes its sentinel, not the
OS-managed container metadata. No grants are changed or dialogs answered.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import uuid

from tcc_responsibility import REPO, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--identity", help="Developer ID identity; required when creating the fixture")
    args = parser.parse_args()
    if args.cleanup:
        manifest = json.loads(args.manifest.read_text())
        root = Path(manifest["root"])
        if root.parent != Path("/private/tmp") or not root.name.startswith("chauffeur-appdata-owner-"):
            parser.error("Manifest does not identify a disposable fixture root")
        if Path(manifest["app"]) != root / "Synthetic Data Owner.app":
            parser.error("Manifest app does not belong to the fixture root")
        run("open", "-W", "-n", manifest["app"], "--args", "cleanup")
        shutil.rmtree(root)
        return
    if args.manifest.exists():
        parser.error("Manifest exists; clean up its fixture before creating another")
    if not args.identity or args.identity == "-":
        parser.error("A certificate signing identity is required for container protection")
    root = Path(tempfile.mkdtemp(prefix="chauffeur-appdata-owner-", dir="/private/tmp"))
    app = root / "Synthetic Data Owner.app"
    binary = app / "Contents/MacOS/owner"
    binary.parent.mkdir(parents=True)
    bundle = "dev.cliq.chauffeur.synthetic-data." + uuid.uuid4().hex
    info = dict(CFBundleIdentifier=bundle, CFBundleExecutable="owner", CFBundlePackageType="APPL",
                CFBundleName="Chauffeur Synthetic Data Owner", CFBundleVersion="1", LSUIElement=True)
    info["NSDataAccessSecurityPolicy"] = {"AllowList": []}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    entitlements = root / "sandbox.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
    run("xcrun", "clang", "-Wall", "-Wextra", "-framework", "Foundation",
        REPO / "Prototypes/tcc_container_fixture.m", "-o", binary)
    run("codesign", "--force", "--sign", args.identity, "--entitlements", entitlements, app)
    target = Path.home() / "Library/Containers" / bundle / "Data/Library/Application Support/chauffeur-tcc-sentinel.txt"
    args.manifest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    args.manifest.write_text(json.dumps({"root": str(root), "app": str(app), "bundle": bundle,
                                        "target": str(target)}, indent=2) + "\n")
    run("open", "-W", "-n", app)
    print(target)


if __name__ == "__main__":
    main()
