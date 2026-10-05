#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

folder = Path(os.environ['IOS_SIGNING_DIR'])
if (folder / 'profiles.json').exists():
    profiles = json.loads((folder / 'profiles.json').read_text())
    for profile in profiles.values():
        (Path.home() / 'Library/MobileDevice/Provisioning Profiles' / (profile['uuid'] + '.mobileprovision')).unlink(missing_ok=True)
if (folder / 'original-keychains.txt').exists():
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s',
                    *shlex.split((folder / 'original-keychains.txt').read_text())], check=False)
subprocess.run(['security', 'delete-keychain', str(folder / 'build.keychain-db')], check=False,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if folder.exists():
    shutil.rmtree(folder)
