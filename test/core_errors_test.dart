import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/l10n/strings.dart';
import 'package:voidrauvpn/services/core_errors.dart';

void main() {
  final fa = S('fa');
  final en = S('en');

  test('the missing-psiphon-helper error names the fix', () {
    const raw =
        'Error: Other("psiphon needs the psiphon-tunnel-core console client, and it was not in ., pt or on PATH")';
    expect(friendlyCoreError(raw, fa), contains('Psiphon'));
    expect(friendlyCoreError(raw, fa), isNot(contains('psiphon-tunnel-core')));
    expect(friendlyCoreError(raw, en), contains('Psiphon helper'));
  });

  test('tor without pluggable transports names the fix', () {
    expect(
        friendlyCoreError(
            '[-] nothing here can speak obfs4, snowflake, webtunnel', fa),
        contains('obfs4'));
  });

  test('the reverse-plus-wireguard refusal names the fix', () {
    expect(
        friendlyCoreError(
            'tor carries tcp only and warp\'s wireguard endpoints answer on udp alone, so WireGuard can never be reached through tor',
            fa),
        contains('MASQUE'));
  });

  test('slow-hop timeouts are explained, not repeated raw', () {
    expect(friendlyCoreError('psiphon did not come up in time', fa),
        contains('مسدود'));
    expect(
        friendlyCoreError('SOCKS5 listener did not start in time', fa),
        contains('هسته'));
    expect(
        friendlyCoreError(
            'Real traffic validation failed — the gateway cannot carry traffic',
            fa),
        contains('ترافیک'));
    expect(friendlyCoreError('Tunnel core exited (1)', fa),
        contains('عیب‌یابی'));
  });

  test('unknown errors pass through unchanged', () {
    const raw = 'something nobody has seen before (code 42)';
    expect(friendlyCoreError(raw, fa), raw);
    expect(friendlyCoreError(raw, en), raw);
  });
}
