import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidrauvpn/services/license_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Future<String> Function() originalProvider;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    originalProvider = LicenseService.instance.deviceIdProvider;
  });

  setUp(() {
    LicenseService.instance.deviceIdProvider = () async => 'dev-test-123';
  });

  tearDown(() {
    LicenseService.instance.deviceIdProvider = originalProvider;
  });

  const key = 'VDRV-AAAA-BBBB-CCCC';

  group('deviceId', () {
    test('generateDeviceId is 32 lowercase hex chars and unique', () {
      final a = LicenseService.generateDeviceId();
      final b = LicenseService.generateDeviceId();
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(b, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a, isNot(b));
    });

    test('device id is stored under the documented secure-storage key', () {
      expect(LicenseService.deviceIdStorageKey, 'device.id');
    });

    test('formatDeviceName builds a display name from OS tokens only', () {
      expect(LicenseService.formatDeviceName('android', '12'), 'Android 12');
      expect(LicenseService.formatDeviceName('windows', ''), 'Windows');
      expect(LicenseService.formatDeviceName('ios', '17.2'), 'Ios 17.2');
    });
  });

  group('sessions parsing', () {
    test('parses a full session object', () {
      final sessions = LicenseService.parseSessions([
        {
          'id': 'ses_abc123',
          'deviceId': 'dev-1',
          'name': 'Android 12',
          'platform': 'android',
          'appVersion': '1.5.3',
          'firstSeen': 1794360000,
          'lastSeen': 1794363600,
        },
      ]);
      expect(sessions, hasLength(1));
      final s = sessions.first;
      expect(s.id, 'ses_abc123');
      expect(s.deviceId, 'dev-1');
      expect(s.name, 'Android 12');
      expect(s.platform, 'android');
      expect(s.appVersion, '1.5.3');
      expect(s.lastSeen, 1794363600);
      expect(s.displayName, 'Android 12');
      expect(s.platformLabel, 'اندروید');
    });

    test('parses the short 409 summary (missing fields tolerated)', () {
      final sessions = LicenseService.parseSessions([
        {'id': 'ses_1', 'name': 'Android 12', 'platform': 'android', 'lastSeen': 1794363600},
        {'id': 'ses_2', 'name': 'Windows 11', 'platform': 'windows'},
      ]);
      expect(sessions, hasLength(2));
      expect(sessions[1].deviceId, isNull);
      expect(sessions[1].lastSeen, isNull);
      expect(sessions[1].lastSeenDate, isNull);
    });

    test('skips entries without an id and non-list input', () {
      expect(
        LicenseService.parseSessions([
          {'name': 'No id here'},
          'not-a-map',
          {'id': 'ses_ok', 'name': 'Android 12', 'platform': 'android'},
        ]),
        hasLength(1),
      );
      expect(LicenseService.parseSessions(null), isEmpty);
      expect(LicenseService.parseSessions({'id': 'ses_x'}), isEmpty);
    });

    test('isStale flags sessions quiet for over 30 days only', () {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final old = LicenseSession(
        id: 'ses_old',
        name: 'Android 12',
        platform: 'android',
        appVersion: '1.5.2',
        lastSeen: now - 40 * 24 * 3600,
      );
      final recent = LicenseSession(
        id: 'ses_new',
        name: 'Android 12',
        platform: 'android',
        appVersion: '1.5.3',
        lastSeen: now - 3600,
      );
      const unknown = LicenseSession(
        id: 'ses_unknown',
        name: '',
        platform: '',
        appVersion: '',
      );
      expect(old.isStale, isTrue);
      expect(recent.isStale, isFalse);
      expect(unknown.isStale, isFalse);
      expect(unknown.displayName, 'دستگاه ناشناس');
    });
  });

  group('session-limit error parsing', () {
    test('parses a 409 body into a structured error', () {
      final err = LicenseService.parseLimitError(
        {
          'ok': false,
          'error': 'session-limit',
          'maxUsers': 1,
          'activeCount': 1,
          'sessions': [
            {'id': 'ses_1', 'name': 'Android 12', 'platform': 'android', 'lastSeen': 1794363600},
          ],
        },
        409,
      );
      expect(err, isNotNull);
      expect(err!.maxUsers, 1);
      expect(err.activeCount, 1);
      expect(err.sessions, hasLength(1));
      expect(err.sessions.first.id, 'ses_1');
    });

    test('returns null for non-409 status or other errors', () {
      expect(LicenseService.parseLimitError({'error': 'session-limit'}, 200),
          isNull);
      expect(
          LicenseService.parseLimitError({'error': 'invalid'}, 409), isNull);
    });
  });

  group('check() session flows (mocked HTTP)', () {
    test('409 keeps a structured limit error instead of a plain string', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/license');
        expect(request.url.queryParameters['deviceId'], 'dev-test-123');
        expect(request.url.queryParameters['deviceName'], isNotEmpty);
        expect(request.url.queryParameters['platform'], isNotEmpty);
        expect(request.url.queryParameters['appVersion'], isNotEmpty);
        return http.Response(
          jsonEncode({
            'ok': false,
            'error': 'session-limit',
            'maxUsers': 1,
            'activeCount': 1,
            'sessions': [
              {'id': 'ses_1', 'name': 'Android 12', 'platform': 'android', 'lastSeen': 1794363600},
            ],
          }),
          409,
        );
      });
      final ok = await LicenseService.instance
          .check(keyOverride: key, client: client);
      expect(ok, isFalse);
      expect(LicenseService.instance.lastError, 'session-limit');
      final err = LicenseService.instance.lastLimitError;
      expect(err, isNotNull);
      expect(err!.maxUsers, 1);
      expect(err.sessions, hasLength(1));
      expect(err.sessions.first.name, 'Android 12');
    });

    test('success stores maxUsers, sessions, sessionId and sessionActive',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'ok': true,
            'plan': 'paid',
            'expiresAt': 1893456000,
            'maxUsers': 3,
            'activeSessions': 2,
            'sessionId': 'ses_mine',
            'sessionActive': true,
            'sessions': [
              {
                'id': 'ses_mine',
                'deviceId': 'dev-test-123',
                'name': 'Android 12',
                'platform': 'android',
                'appVersion': '1.5.3',
                'firstSeen': 1794360000,
                'lastSeen': 1794363600,
              },
              {
                'id': 'ses_other',
                'deviceId': 'dev-other',
                'name': 'Windows 11',
                'platform': 'windows',
                'appVersion': '1.5.3',
                'lastSeen': 1794363600,
              },
            ],
          }),
          200,
        );
      });
      final ok = await LicenseService.instance
          .check(keyOverride: key, client: client);
      expect(ok, isTrue);
      final lic = LicenseService.instance;
      expect(lic.maxUsers, 3);
      expect(lic.sessionId, 'ses_mine');
      expect(lic.sessionActive, isTrue);
      expect(lic.sessions, hasLength(2));
      expect(lic.key, key);
    });

    test('revoked session clears the stored key with session-revoked',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'ok': true,
            'plan': 'paid',
            'expiresAt': 1893456000,
            'maxUsers': 1,
            'sessionId': 'ses_gone',
            'sessionActive': false,
            'sessions': [],
          }),
          200,
        );
      });
      final ok = await LicenseService.instance
          .check(keyOverride: key, client: client);
      expect(ok, isFalse);
      expect(LicenseService.instance.lastError, 'session-revoked');
      expect(LicenseService.instance.key, isNull);
    });

    test('missing sessionActive is derived from the sessions list',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'ok': true,
            'plan': 'paid',
            'expiresAt': 1893456000,
            'maxUsers': 1,
            'sessions': [
              {
                'id': 'ses_someone_else',
                'deviceId': 'dev-other',
                'name': 'Windows 11',
                'platform': 'windows',
                'lastSeen': 1794363600,
              },
            ],
          }),
          200,
        );
      });
      final ok = await LicenseService.instance
          .check(keyOverride: key, client: client);
      expect(ok, isFalse);
      expect(LicenseService.instance.lastError, 'session-revoked');
      expect(LicenseService.instance.key, isNull);
    });
  });

  group('revoke flows (mocked HTTP)', () {
    Future<void> seedLicense() async {
      final seed = MockClient((request) async => http.Response(
            jsonEncode({
              'ok': true,
              'plan': 'paid',
              'expiresAt': 1893456000,
              'sessionId': 'ses_mine',
              'sessionActive': true,
              'sessions': [
                {'id': 'ses_mine', 'deviceId': 'dev-test-123', 'name': 'Android 12', 'platform': 'android'},
                {'id': 'ses_old', 'deviceId': 'dev-old', 'name': 'Windows 11', 'platform': 'windows'},
              ],
            }),
            200,
          ));
      expect(
          await LicenseService.instance.check(keyOverride: key, client: seed),
          isTrue);
    }

    test('revokeSession posts key, sessionId and deviceId', () async {
      Map<String, dynamic>? sentBody;
      String? sentPath;
      final client = MockClient((request) async {
        sentPath = request.url.path;
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'ok': true,
            'sessions': [
              {'id': 'ses_keep', 'name': 'Android 12', 'platform': 'android'},
            ],
          }),
          200,
        );
      });
      await seedLicense();
      final ok = await LicenseService.instance
          .revokeSession('ses_old', client: client);
      expect(ok, isTrue);
      expect(sentPath, '/api/sessions/revoke');
      expect(sentBody?['sessionId'], 'ses_old');
      expect(sentBody?['deviceId'], 'dev-test-123');
      expect(sentBody?['key'], key);
      expect(LicenseService.instance.sessions.map((s) => s.id), ['ses_keep']);
    });

    test('revokeAllSessions keeps the current session id in the body',
        () async {
      Map<String, dynamic>? sentBody;
      String? sentPath;
      final client = MockClient((request) async {
        sentPath = request.url.path;
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'ok': true, 'sessions': []}), 200);
      });
      await seedLicense();
      final ok = await LicenseService.instance
          .revokeAllSessions(keepCurrent: true, client: client);
      expect(ok, isTrue);
      expect(sentPath, '/api/sessions/revoke-all');
      expect(sentBody?['deviceId'], 'dev-test-123');
      expect(sentBody?['keepSessionId'], 'ses_mine');
    });
  });
}
