import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/windows_killswitch.dart';

void main() {
  group('KillSwitchPlan.engageCommands', () {
    final cmds = KillSwitchPlan.engageCommands([
      r'C:\Program Files\VoidrauVPN\aether.exe',
      r'C:\Program Files\VoidrauVPN\pt\psiphon-tunnel-core.exe',
    ]);

    test('allow rules come before the policy flip', () {
      final policyIdx = cmds.indexWhere((c) => c.contains('firewallpolicy'));
      expect(policyIdx, cmds.length - 1);
      for (var i = 0; i < policyIdx; i++) {
        expect(cmds[i], contains('add'));
        expect(cmds[i], contains('action=allow'));
      }
    });

    test('one allow rule per core exe, named with the shared prefix', () {
      final programRules =
          cmds.where((c) => c.any((a) => a.startsWith('program='))).toList();
      expect(programRules.length, 2);
      expect(programRules[0],
          contains('name=${KillSwitchPlan.allowRuleName(0)}'));
      expect(programRules[0],
          contains(r'program=C:\Program Files\VoidrauVPN\aether.exe'));
      expect(programRules[1],
          contains('name=${KillSwitchPlan.allowRuleName(1)}'));
    });

    test('loopback and DHCP are allowed through the block', () {
      expect(
          cmds.any((c) => c.contains('remoteip=127.0.0.1')), isTrue);
      expect(cmds.any((c) => c.contains('protocol=UDP')), isTrue);
    });

    test('the flip blocks outbound by default', () {
      expect(cmds.last, [
        'advfirewall',
        'set',
        'allprofiles',
        'firewallpolicy',
        KillSwitchPlan.blockPolicy,
      ]);
    });
  });

  group('KillSwitchPlan.disengageCommands', () {
    final cmds = KillSwitchPlan.disengageCommands(
        restorePolicy: 'blockinbound,allowoutbound', ruleCount: 2);

    test('restores the policy first, then deletes our rules', () {
      expect(cmds.first, [
        'advfirewall',
        'set',
        'allprofiles',
        'firewallpolicy',
        'blockinbound,allowoutbound',
      ]);
      final deletes = cmds.where((c) => c.contains('delete')).toList();
      // 2 per-exe rules + loopback + DHCP.
      expect(deletes.length, 4);
      for (final d in deletes) {
        expect(d.any((a) => a.startsWith('name=${KillSwitchPlan.rulePrefix}')),
            isTrue);
      }
    });
  });

  group('KillSwitchPlan.parseFirewallPolicy', () {
    test('reads the Windows default from show output', () {
      const out = '''
Domain Profile Settings:
----------------------------------------------------------------------
State                                 ON
Firewall Policy                       BlockInbound,AllowOutbound
''';
      expect(KillSwitchPlan.parseFirewallPolicy(out),
          'blockinbound,allowoutbound');
    });

    test('reads a blocking policy and normalizes case', () {
      const out = 'Firewall Policy    BLOCKINBOUND,BLOCKOUTBOUND';
      expect(KillSwitchPlan.parseFirewallPolicy(out),
          'blockinbound,blockoutbound');
    });

    test('returns null when nothing matches', () {
      expect(KillSwitchPlan.parseFirewallPolicy('no policy here'), isNull);
      expect(KillSwitchPlan.parseFirewallPolicy(''), isNull);
    });

    test('blocksOutbound only for the blocking form', () {
      expect(KillSwitchPlan.blocksOutbound('blockinbound,blockoutbound'),
          isTrue);
      expect(KillSwitchPlan.blocksOutbound('blockinbound,allowoutbound'),
          isFalse);
      expect(KillSwitchPlan.blocksOutbound(null), isFalse);
    });
  });
}
