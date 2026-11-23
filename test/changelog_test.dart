import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/update_service.dart';

void main() {
  group('ReleaseNotes.userNotes', () {
    test('strips the workflow boilerplate, keeps the author notes', () {
      const body = '''
## VoidrauVPN v1.9.0

- Xray on Windows
- Kill switch

> **Important:** as soon as a release is published, older builds stop
> working. If you are running an older version, the app tells you to
> install this one — the installer, the notes and support live in the
> Telegram channel: https://t.me/Voidrau

### Downloads — read this first on Android
- `VoidrauVPN-v1.9.0-Android-Universal.apk` — Android 10+
''';
      expect(ReleaseNotes.userNotes(body), '- Xray on Windows\n- Kill switch');
    });

    test('cuts at the Downloads heading even without the blockquote', () {
      const body = 'Fixed the thing.\n\n### Downloads\n- file.apk';
      expect(ReleaseNotes.userNotes(body), 'Fixed the thing.');
    });

    test('a hand-written body passes through (minus a version header)', () {
      expect(ReleaseNotes.userNotes('## VoidrauVPN v2.0.0\n\nHello'),
          'Hello');
      expect(ReleaseNotes.userNotes('Just notes'), 'Just notes');
    });

    test('empty and boilerplate-only bodies yield empty', () {
      expect(ReleaseNotes.userNotes(''), '');
      expect(
          ReleaseNotes.userNotes(
              '## VoidrauVPN v1.9.0\n\n> **Important:** x'),
          '');
    });
  });
}
