import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/windows_killswitch.dart';

/// Runtime behaviour of the kill switch (finding 17 + the sweep): engage /
/// disengage / sweep against the real `netsh`, which does not exist on the
/// test host — so every `netsh` call fails to run. That is exactly the
/// "not on Windows" behaviour under test: engage must fail *closed*
/// (no policy flip, no snapshot left behind), and disengage/sweep must
/// still honour and delete a leftover snapshot file. The command shapes
/// themselves are covered in windows_killswitch_test.dart; the actual
/// firewall flip can only be verified on Windows (listed as not-done).
void main() {
  group('WindowsKillSwitch runtime (no netsh on this host)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('killswitch-test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    File snapshotFile(Directory d) =>
        File('${d.path}${Platform.pathSeparator}killswitch.policy');

    test('engage fails closed when netsh cannot run', () async {
      final ks = WindowsKillSwitch(stateDir: dir.path);
      final ok = await ks.engage([
        r'C:\Program Files\VoidrauVPN\aether.exe',
      ]);
      expect(ok, isFalse);
      expect(ks.engaged, isFalse);
      // No snapshot left behind: a later sweep must not "restore" a
      // policy that was never changed.
      expect(await snapshotFile(dir).exists(), isFalse);
    });

    test('engage fails closed when the snapshot cannot be written', () async {
      final ks = WindowsKillSwitch(
          stateDir: '${dir.path}${Platform.pathSeparator}missing-dir');
      expect(await ks.engage([r'C:\x\aether.exe']), isFalse);
      expect(ks.engaged, isFalse);
    });

    test('engage is a no-op second call once engaged — and never engaged '
        'here', () async {
      final ks = WindowsKillSwitch(stateDir: dir.path);
      expect(await ks.engage([r'C:\x\aether.exe']), isFalse);
      expect(await ks.engage([r'C:\x\aether.exe']), isFalse);
    });

    test('disengage honours and deletes a leftover snapshot', () async {
      final ks = WindowsKillSwitch(stateDir: dir.path);
      await snapshotFile(dir)
          .writeAsString(KillSwitchPlan.defaultPolicy);
      await ks.disengage();
      expect(await snapshotFile(dir).exists(), isFalse);
      expect(ks.engaged, isFalse);
    });

    test('disengage falls back to the default policy on a corrupt '
        'snapshot', () async {
      final ks = WindowsKillSwitch(stateDir: dir.path);
      await snapshotFile(dir).writeAsString('garbage, not a policy');
      await ks.disengage();
      expect(await snapshotFile(dir).exists(), isFalse);
    });

    test('disengage with no snapshot and nothing engaged is a no-op',
        () async {
      final ks = WindowsKillSwitch(stateDir: dir.path);
      await ks.disengage();
      expect(await snapshotFile(dir).exists(), isFalse);
      expect(ks.engaged, isFalse);
    });

    test('sweep heals a leftover block from a hard-killed run', () async {
      final ks = WindowsKillSwitch(stateDir: dir.path);
      await snapshotFile(dir).writeAsString(KillSwitchPlan.blockPolicy);
      await ks.sweep();
      expect(await snapshotFile(dir).exists(), isFalse);
      expect(ks.engaged, isFalse);
    });

    test('sweep with no snapshot stays silent and creates nothing',
        () async {
      final ks = WindowsKillSwitch(stateDir: dir.path);
      await ks.sweep();
      expect(await snapshotFile(dir).exists(), isFalse);
    });
  });

  group('KillSwitchPlan command shapes (finding 17)', () {
    test('engage with no exes still allows loopback and DHCP, then flips',
        () {
      final cmds = KillSwitchPlan.engageCommands([]);
      expect(cmds, hasLength(3));
      expect(cmds.last, [
        'advfirewall',
        'set',
        'allprofiles',
        'firewallpolicy',
        KillSwitchPlan.blockPolicy,
      ]);
      expect(cmds.any((c) => c.contains('remoteip=127.0.0.1')), isTrue);
      expect(cmds.any((c) => c.contains('protocol=UDP')), isTrue);
    });

    test('disengage with zero rules deletes only loopback and DHCP', () {
      final cmds = KillSwitchPlan.disengageCommands(
          restorePolicy: KillSwitchPlan.defaultPolicy, ruleCount: 0);
      expect(cmds.first[4], KillSwitchPlan.defaultPolicy);
      final deletes = cmds.where((c) => c.contains('delete')).toList();
      expect(deletes, hasLength(2));
      expect(
        deletes.every((d) =>
            d.any((a) => a.startsWith('name=${KillSwitchPlan.rulePrefix}'))),
        isTrue,
      );
    });

    test('every rule name carries the shared prefix', () {
      for (final cmd in KillSwitchPlan.engageCommands([r'C:\x\a.exe'])) {
        for (final arg in cmd) {
          if (arg.startsWith('name=')) {
            expect(arg, startsWith('name=${KillSwitchPlan.rulePrefix}'));
          }
        }
      }
    });
  });
}
