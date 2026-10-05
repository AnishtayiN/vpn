import json
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]


class ContractTests(unittest.TestCase):
    def test_app_and_extension_entitlements_match(self):
        for target in ('Runner', 'PacketTunnel'):
            ent = plistlib.loads((ROOT / f'overlays/ios/{target}/{target}.entitlements').read_bytes())
            self.assertEqual(ent['com.apple.developer.networking.networkextension'], ['packet-tunnel-provider'])

    def test_extension_entry_and_version(self):
        info = plistlib.loads((ROOT / 'overlays/ios/PacketTunnel/Info.plist').read_bytes())
        self.assertEqual(info['NSExtension']['NSExtensionPointIdentifier'], 'com.apple.networkextension.packet-tunnel')
        self.assertEqual(info['CFBundleVersion'], '$(FLUTTER_BUILD_NUMBER)')
        self.assertEqual(info['CFBundleShortVersionString'], '$(FLUTTER_BUILD_NAME)')

    def test_channels_agree(self):
        dart = (ROOT / 'lib/services/platform_engine.dart').read_text()
        swift = (ROOT / 'overlays/ios/Runner/VPNPlugin.swift').read_text()
        for channel in ('nimbus.vpn/engine', 'nimbus.vpn/events'):
            self.assertIn(channel, dart)
            self.assertIn(channel, swift)

    def test_core_environment_contract(self):
        dart = (ROOT / 'lib/services/core_args.dart').read_text()
        swift = (ROOT / 'overlays/ios/Shared/TunnelConfiguration.swift').read_text()
        keys = set(re.findall(r"['\"](AETHER_[A-Z0-9_]+)['\"]", dart))
        allowed = set(re.findall(r'"(AETHER_[A-Z0-9_]+)"', swift))
        self.assertTrue(keys <= allowed, f'Swift validator is missing: {keys - allowed}')

    def test_native_sources_are_revision_pinned(self):
        pins = json.loads((ROOT / 'scripts/pins.json').read_text())
        for key in ('ios_aether_revision', 'ios_hev_revision'):
            self.assertRegex(pins[key], r'^[0-9a-f]{40}$')

    def test_no_private_tun_descriptor_lookup(self):
        code = '\n'.join(p.read_text() for p in (ROOT / 'overlays/ios').rglob('*.swift'))
        self.assertNotIn('value(forKey:', code)
        self.assertNotIn('valueForKey', code)
        self.assertIn('flow.readPackets', code)
        self.assertIn('flow.writePackets', code)
        self.assertIn('socketpair(AF_UNIX, SOCK_DGRAM', code)

    def test_hev_extension_process_policy_patch(self):
        patch = (ROOT / 'scripts/ios/hev-ios.patch').read_text()
        self.assertIn('hev-exec.c', patch)
        self.assertIn('hev-utils.c', patch)
        self.assertEqual(patch.count('TARGET_OS_TV || TARGET_OS_IOS'), 1)
        self.assertEqual(patch.count('TARGET_OS_TV) && !(TARGET_OS_IOS'), 1)
        build = (ROOT / 'scripts/ios/build_native.sh').read_text()
        self.assertIn('scripts/ios/hev-ios.patch', build)

    def test_privacy_manifest_is_valid(self):
        manifest = plistlib.loads((ROOT / 'overlays/ios/Runner/PrivacyInfo.xcprivacy').read_bytes())
        self.assertFalse(manifest['NSPrivacyTracking'])
        self.assertTrue(manifest['NSPrivacyAccessedAPITypes'])

    def test_ios_release_publishing_stays_opt_in_and_prerelease(self):
        """The iOS workflow publishes an IPA, and the in-app updater reads
        `releases/latest`: publishing must stay opt-in, dispatch-only and
        pre-release, or an iOS build would retire Android/Windows installs."""
        workflow = (ROOT / '.github/workflows/ios.yml').read_text()
        self.assertIn('name: Publish GitHub Release', workflow)
        self.assertRegex(
            workflow,
            r"if: \$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.publish_release \}\}",
        )
        self.assertIn('--prerelease', workflow)
        self.assertIn('publish_release needs upload_testflight', workflow)
        # The published files must be the ones the build job uploaded.
        self.assertIn('name: ${{ needs.build.outputs.artifact }}', workflow)


if __name__ == '__main__':
    unittest.main()
