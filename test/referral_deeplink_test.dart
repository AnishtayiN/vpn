import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/app_info.dart';

void main() {
  test('license actions use the live license bot and Telegram start payloads', () {
    expect(AppInfo.botUsername, 'VoidRauBot');
    expect(AppInfo.botStartUrl('trial'), 'https://t.me/VoidRauBot?start=trial');
    expect(AppInfo.botStartUrl('buy'), 'https://t.me/VoidRauBot?start=buy');
    expect(AppInfo.botStartUrl('ref'), 'https://t.me/VoidRauBot?start=ref');
  });

  test('personal referral payloads are kept intact in deep links', () {
    expect(
      AppInfo.botStartUrl('ref_6508600903'),
      'https://t.me/VoidRauBot?start=ref_6508600903',
    );
  });
}
