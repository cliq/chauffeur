#!/usr/bin/env python3
"""Check that the signed Sessions helper can prompt for every public TCC service.

TCC attributes session tools to Chauffeur Sessions. Under the hardened runtime a
service is denied without a prompt unless that app carries both the purpose
string and, where one exists, the resource-access entitlement.
"""
import plistlib
from pathlib import Path
import subprocess
import sys

# (service, Info.plist purpose strings, hardened-runtime entitlement or None)
SERVICES = [
    ('Camera', ['NSCameraUsageDescription'], 'com.apple.security.device.camera'),
    ('Microphone', ['NSMicrophoneUsageDescription'], 'com.apple.security.device.audio-input'),
    ('System audio recording', ['NSAudioCaptureUsageDescription'], None),
    ('Speech recognition', ['NSSpeechRecognitionUsageDescription'], None),
    ('Location', ['NSLocationUsageDescription', 'NSLocationWhenInUseUsageDescription'],
     'com.apple.security.personal-information.location'),
    ('Contacts', ['NSContactsUsageDescription'], 'com.apple.security.personal-information.addressbook'),
    ('Calendars', ['NSCalendarsUsageDescription', 'NSCalendarsFullAccessUsageDescription',
                   'NSCalendarsWriteOnlyAccessUsageDescription'],
     'com.apple.security.personal-information.calendars'),
    ('Reminders', ['NSRemindersUsageDescription', 'NSRemindersFullAccessUsageDescription'],
     'com.apple.security.personal-information.calendars'),
    ('Photos', ['NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription'],
     'com.apple.security.personal-information.photos-library'),
    ('Automation', ['NSAppleEventsUsageDescription'], 'com.apple.security.automation.apple-events'),
    ('Bluetooth', ['NSBluetoothAlwaysUsageDescription'], None),
    ('Local network', ['NSLocalNetworkUsageDescription'], None),
    ('Folders and volumes', ['NSDesktopFolderUsageDescription', 'NSDocumentsFolderUsageDescription',
                             'NSDownloadsFolderUsageDescription', 'NSRemovableVolumesUsageDescription',
                             'NSNetworkVolumesUsageDescription'], None),
]


def signed_entitlements(app):
    result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(app)],
                            capture_output=True, check=True)
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def main():
    app = Path(sys.argv[1])
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    entitlements = signed_entitlements(app)
    problems = []
    for service, keys, entitlement in SERVICES:
        for key in keys:
            if not str(info.get(key, '')).strip():
                problems.append(f'{service}: Info.plist is missing {key}')
        if entitlement and entitlements.get(entitlement) is not True:
            problems.append(f'{service}: signature is missing {entitlement}')
    if problems:
        print(f'error: {app.name} would deny these privacy requests without prompting:', file=sys.stderr)
        for problem in problems:
            print(f'  {problem}', file=sys.stderr)
        raise SystemExit(1)
    print(f'Verified {app.name} privacy declarations ({len(SERVICES)} services)')


if __name__ == '__main__':
    main()
