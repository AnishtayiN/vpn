import copy
import datetime as dt
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('signing', Path(__file__).resolve().parents[1] / 'signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime(2026, 9, 22, tzinfo=dt.timezone.utc)
        self.bundle = 'pm.example.vpn'
        self.team = 'ABCDE12345'
        self.profile = {
            'Name': 'VPN App Store',
            'UUID': 'A0000000-1111-2222-3333-444444444444',
            'ExpirationDate': dt.datetime(2027, 1, 1),
            'TeamIdentifier': [self.team],
            'ApplicationIdentifierPrefix': [self.team],
            'DeveloperCertificates': [b'fixture'],
            'Entitlements': {
                'application-identifier': f'{self.team}.{self.bundle}',
                'com.apple.developer.networking.networkextension': ['packet-tunnel-provider'],
                'get-task-allow': False,
            },
        }

    def check(self, profile=None, bundle=None):
        return signing.validate_profile(profile or self.profile, bundle or self.bundle, self.team, self.now)

    def test_app_store_profile_accepted(self):
        self.assertEqual(self.check()['name'], 'VPN App Store')

    def test_extension_requires_own_identifier(self):
        with self.assertRaisesRegex(ValueError, 'explicit bundle ID'):
            self.check(bundle=self.bundle + '.PacketTunnel')
        self.profile['Entitlements']['application-identifier'] += '.PacketTunnel'
        self.check(bundle=self.bundle + '.PacketTunnel')

    def test_expired_profile(self):
        self.profile['ExpirationDate'] = dt.datetime(2026, 9, 21)
        with self.assertRaisesRegex(ValueError, 'expired'):
            self.check()

    def test_wrong_team(self):
        self.profile['TeamIdentifier'] = ['DIFFERENT1']
        with self.assertRaisesRegex(ValueError, 'another team'):
            self.check()

    def test_wildcard_profile(self):
        self.profile['Entitlements']['application-identifier'] = self.team + '.*'
        with self.assertRaisesRegex(ValueError, 'explicit bundle ID'):
            self.check()

    def test_missing_network_extension(self):
        self.profile['Entitlements']['com.apple.developer.networking.networkextension'] = ['app-proxy-provider']
        with self.assertRaisesRegex(ValueError, 'capability missing'):
            self.check()

    def test_development_ad_hoc_enterprise_rejected(self):
        for key, value in [('ProvisionedDevices', ['UDID']), ('ProvisionsAllDevices', True)]:
            profile = copy.deepcopy(self.profile)
            profile[key] = value
            with self.assertRaisesRegex(ValueError, 'App Store'):
                self.check(profile)
        self.profile['Entitlements']['get-task-allow'] = True
        with self.assertRaisesRegex(ValueError, 'App Store'):
            self.check()

    def test_missing_certificate(self):
        self.profile['DeveloperCertificates'] = []
        with self.assertRaisesRegex(ValueError, 'certificate'):
            self.check()

    def test_invalid_uuid_cannot_be_used_as_path(self):
        self.profile['UUID'] = '../../bad/path'
        with self.assertRaisesRegex(ValueError, 'UUID'):
            self.check()

    def test_legacy_application_prefix_is_supported(self):
        self.profile['ApplicationIdentifierPrefix'] = ['LEGACYPREF']
        self.profile['Entitlements']['application-identifier'] = 'LEGACYPREF.' + self.bundle
        self.check()


if __name__ == '__main__':
    unittest.main()
