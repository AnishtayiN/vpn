#!/usr/bin/env python3
"""Validate Apple profiles before archiving. Never print secret/profile contents."""
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


def validate_profile(profile, bundle, team, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile.get('ExpirationDate')
    if not expiry or expiry.replace(tzinfo=dt.timezone.utc) <= now:
        raise ValueError(f'{bundle}: provisioning profile expired')
    if team not in profile.get('TeamIdentifier', []):
        raise ValueError(f'{bundle}: profile belongs to another team')
    ent = profile.get('Entitlements', {})
    prefixes = profile.get('ApplicationIdentifierPrefix', [team])
    if not any(ent.get('application-identifier') == f'{prefix}.{bundle}' for prefix in prefixes):
        raise ValueError(f'{bundle}: profile must match the explicit bundle ID')
    if 'packet-tunnel-provider' not in ent.get('com.apple.developer.networking.networkextension', []):
        raise ValueError(f'{bundle}: Network Extension capability missing')
    if ent.get('get-task-allow') or profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices'):
        raise ValueError(f'{bundle}: use an App Store distribution profile, not development/ad hoc/enterprise')
    if not re.fullmatch(r'[0-9a-fA-F-]{36}', profile.get('UUID', '')):
        raise ValueError(f'{bundle}: invalid profile UUID')
    if not profile.get('DeveloperCertificates'):
        raise ValueError(f'{bundle}: profile has no distribution certificate')
    return {'uuid': profile['UUID'], 'name': profile['Name']}


def main():
    folder = Path(os.environ['IOS_SIGNING_DIR'])
    bundle = os.environ['IOS_BUNDLE_ID']
    team = os.environ['APPLE_TEAM_ID']
    profiles = {}
    destination = Path.home() / 'Library/MobileDevice/Provisioning Profiles'
    destination.mkdir(parents=True, exist_ok=True)
    for target, identifier in [('Runner', bundle), ('PacketTunnel', bundle + '.PacketTunnel')]:
        source = folder / f'{target}.mobileprovision'
        raw = subprocess.check_output(['security', 'cms', '-D', '-i', str(source)])
        profile = plistlib.loads(raw)
        profiles[target] = validate_profile(profile, identifier, team)
        (destination / f"{profile['UUID']}.mobileprovision").write_bytes(source.read_bytes())
    (folder / 'profiles.json').write_text(json.dumps(profiles))
    options = {
        'method': 'app-store-connect', 'teamID': team, 'signingStyle': 'manual',
        'signingCertificate': 'Apple Distribution', 'manageAppVersionAndBuildNumber': False,
        'uploadSymbols': True,
        'provisioningProfiles': {
            bundle: profiles['Runner']['uuid'],
            bundle + '.PacketTunnel': profiles['PacketTunnel']['uuid'],
        },
    }
    (folder / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
    print('App and extension distribution profiles validated.')


if __name__ == '__main__':
    main()
