import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/windows_tun.dart';

void main() {
  group('ProcessSweep.quote', () {
    test('wraps a plain path in single quotes', () {
      expect(
        ProcessSweep.quote(r'C:\Program Files\VoidrauVPN\aether.exe'),
        r"'C:\Program Files\VoidrauVPN\aether.exe'",
      );
    });

    test('doubles embedded single quotes (PowerShell escaping)', () {
      expect(
        ProcessSweep.quote(r"C:\Users\O'Brien\VoidrauVPN\aether.exe"),
        r"'C:\Users\O''Brien\VoidrauVPN\aether.exe'",
      );
    });
  });

  group('ProcessSweep.taskkillArgs', () {
    test('force-kills the whole process tree by PID', () {
      expect(ProcessSweep.taskkillArgs(4242), ['/PID', '4242', '/T', '/F']);
    });
  });

  group('ProcessSweep.sweepScript', () {
    const targets = [
      r'C:\Program Files\VoidrauVPN\aether.exe',
      r'C:\Program Files\VoidrauVPN\pt\psiphon-tunnel-core.exe',
      r'C:\Program Files\VoidrauVPN\pt\lyrebird.exe',
    ];

    test('matches on the full executable path of every target', () {
      final script = ProcessSweep.sweepScript(targets);
      for (final t in targets) {
        expect(script, contains(ProcessSweep.quote(t)));
      }
      expect(script, contains('Get-Process'));
      expect(script, contains(r'$_.Path'));
      expect(script, contains(r'$targets -contains $_.Path'));
      expect(script, contains('Stop-Process'));
      expect(script, contains('-Force'));
    });

    test('never matches by bare image name', () {
      final script = ProcessSweep.sweepScript(targets);
      expect(script, isNot(contains('-Name')));
      expect(script, isNot(contains('ProcessName')));
    });

    test('reports each stopped process for the log', () {
      final script = ProcessSweep.sweepScript(targets);
      expect(script, contains('sweep-kill'));
    });

    test('a quote in the install path cannot break out of the literal', () {
      final script =
          ProcessSweep.sweepScript([r"C:\O'Brien\VoidrauVPN\aether.exe"]);
      expect(script, contains(r"'C:\O''Brien\VoidrauVPN\aether.exe'"));
    });
  });
}
