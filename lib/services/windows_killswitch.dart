import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows kill switch ("Fail closed" in the UI): when the tunnel drops
/// unexpectedly, device traffic must stop — not fall back to the raw line
/// while the watchdog reconnects.
///
/// Android gets this from the VpnService architecture: the TUN stays
/// established across core restarts, so packets die inside it instead of
/// leaking. Windows has no such anchor — kill the bridge and the adapter
/// (and its routes) vanish, and the machine is direct again. So Windows
/// blocks at the firewall instead:
///
/// * the firewall's *default* outbound action is set to Block
///   (`netsh advfirewall set allprofiles firewallpolicy
///   blockinbound,blockoutbound`), and
/// * explicit Allow rules punch holes for exactly the tunnel core's own
///   executables (so it can re-dial) and for DHCP renewals (so the lease
///   survives a long recovery). Allow rules override the default action —
///   unlike a blanket Block *rule*, which would override the allows and
///   strand the core too.
///
/// Crash safety is the whole design constraint: a machine must never be
/// left permanently blocked. The original firewall policy is snapshotted
/// to a file before anything changes; disengage restores it and deletes
/// our rules, and a startup sweep ([WindowsKillSwitch.sweep]) does the
/// same for a run that was hard-killed mid-block — the same self-heal
/// pattern as the orphan-process sweep. Every rule we add carries the
/// [KillSwitchPlan.rulePrefix] name, so cleanup never touches rules that
/// are not ours.
///
/// Needs Administrator (netsh advfirewall refuses otherwise); the caller
/// checks elevation and only engages in TUN mode. In proxy mode the
/// fail-closed behaviour is the system proxy left pointing at the dead
/// listener, which the engine handles separately.
class KillSwitchPlan {
  /// Every rule we add starts with this name — cleanup deletes by name,
  /// so a user's own rules are never touched.
  static const String rulePrefix = 'VoidrauVPN-KillSwitch';

  /// The Windows factory default, restored when no snapshot exists.
  static const String defaultPolicy = 'blockinbound,allowoutbound';

  /// The blocking policy: nothing out unless an Allow rule names it.
  static const String blockPolicy = 'blockinbound,blockoutbound';

  static String allowRuleName(int index) => '$rulePrefix-Allow-$index';
  static const String loopbackRuleName = '$rulePrefix-Allow-Loopback';
  static const String dhcpRuleName = '$rulePrefix-Allow-DHCP';

  /// Commands that engage the block: allow rules first (so the core is
  /// never locked out mid-engage), then the default policy flip.
  static List<List<String>> engageCommands(List<String> exePaths) {
    return [
      for (var i = 0; i < exePaths.length; i++)
        [
          'advfirewall', 'firewall', 'add', 'rule',
          'name=${allowRuleName(i)}',
          'dir=out', 'action=allow',
          'program=${exePaths[i]}',
          'enable=yes', 'profile=any',
        ],
      [
        'advfirewall', 'firewall', 'add', 'rule',
        'name=$loopbackRuleName',
        'dir=out', 'action=allow',
        'remoteip=127.0.0.1',
        'enable=yes', 'profile=any',
      ],
      [
        'advfirewall', 'firewall', 'add', 'rule',
        'name=$dhcpRuleName',
        'dir=out', 'action=allow',
        'protocol=UDP', 'localport=68', 'remoteport=67',
        'enable=yes', 'profile=any',
      ],
      ['advfirewall', 'set', 'allprofiles', 'firewallpolicy', blockPolicy],
    ];
  }

  /// Commands that disengage: restore the snapshotted policy first (the
  /// machine is usable again even if a rule delete below fails), then
  /// remove our rules. [ruleCount] is how many per-exe allow rules the
  /// matching engage added.
  static List<List<String>> disengageCommands({
    required String restorePolicy,
    required int ruleCount,
  }) {
    return [
      ['advfirewall', 'set', 'allprofiles', 'firewallpolicy', restorePolicy],
      for (var i = 0; i < ruleCount; i++)
        ['advfirewall', 'firewall', 'delete', 'rule', 'name=${allowRuleName(i)}'],
      ['advfirewall', 'firewall', 'delete', 'rule', 'name=$loopbackRuleName'],
      ['advfirewall', 'firewall', 'delete', 'rule', 'name=$dhcpRuleName'],
    ];
  }

  /// Extracts the current firewall policy from `netsh advfirewall show
  /// allprofiles` output, normalized to the form `set ... firewallpolicy`
  /// accepts (`blockinbound,allowoutbound`). The label is localized but
  /// the policy tokens (`BlockInbound`, `AllowOutbound`, …) are not, so
  /// the parse anchors on them. Returns null when nothing matches —
  /// the caller then restores [defaultPolicy] instead of guessing.
  static String? parseFirewallPolicy(String showOutput) {
    final m = RegExp(
      r'(BlockInbound|AllowInbound)\s*,\s*(BlockOutbound|AllowOutbound)',
      caseSensitive: false,
    ).firstMatch(showOutput);
    if (m == null) return null;
    return '${m.group(1)!.toLowerCase()},${m.group(2)!.toLowerCase()}';
  }

  /// True when [policy] (normalized form) blocks outbound by default.
  static bool blocksOutbound(String? policy) =>
      policy != null && policy.endsWith('blockoutbound');
}

/// Executes [KillSwitchPlan] against the real firewall. Every failure is
/// logged and swallowed — a kill switch that throws inside a disconnect
/// path would strand the machine in exactly the state it exists to
/// prevent. The snapshot file is the crash-recovery anchor: it is
/// written *before* the policy flips and deleted only after a verified
/// restore.
class WindowsKillSwitch {
  WindowsKillSwitch({required this.stateDir, this.onLog});

  /// Per-user writable dir holding the policy snapshot (the engine's
  /// runtime dir — never next to the exe, which may be Program Files).
  final String stateDir;
  final void Function(String line)? onLog;

  bool _engaged = false;
  int _ruleCount = 0;

  bool get engaged => _engaged;

  String get _snapshotPath => p.join(stateDir, 'killswitch.policy');

  void _log(String line) => onLog?.call(line);

  Future<ProcessResult?> _netsh(List<String> args) async {
    try {
      return await Process.run('netsh', args);
    } catch (e) {
      _log('kill switch: netsh ${args.join(' ')} failed to run: $e');
      return null;
    }
  }

  Future<String?> _currentPolicy() async {
    final r = await _netsh(['advfirewall', 'show', 'allprofiles']);
    if (r == null || r.exitCode != 0) return null;
    return KillSwitchPlan.parseFirewallPolicy('${r.stdout}');
  }

  /// Engages the block. Returns true only when the blocking policy is
  /// verified in place (read back, like the system-proxy writes — a
  /// silently failed netsh must never be reported as "traffic blocked").
  /// [exePaths] are the tunnel core executables allowed to re-dial.
  Future<bool> engage(List<String> exePaths) async {
    if (_engaged) return true;
    final before = await _currentPolicy();
    // Snapshot first: if the process dies between the flip and the
    // restore, the next launch's sweep needs the original policy.
    try {
      await File(_snapshotPath)
          .writeAsString(before ?? KillSwitchPlan.defaultPolicy);
    } catch (e) {
      _log('kill switch: cannot snapshot firewall policy: $e');
      return false;
    }
    _ruleCount = exePaths.length;
    for (final cmd in KillSwitchPlan.engageCommands(exePaths)) {
      final r = await _netsh(cmd);
      if (r == null || r.exitCode != 0) {
        _log('kill switch: netsh ${cmd.join(' ')} → '
            '${r == null ? 'did not run' : '${r.stdout}${r.stderr}'.trim()}');
      }
    }
    final after = await _currentPolicy();
    _engaged = KillSwitchPlan.blocksOutbound(after);
    _log(_engaged
        ? 'kill switch engaged — outbound blocked except the tunnel core'
        : 'kill switch could not be verified (policy: ${after ?? 'unknown'})');
    if (!_engaged) {
      // Nothing is verified blocked; do not leave a snapshot behind that
      // a later sweep would "restore" over a policy we never changed.
      try {
        await File(_snapshotPath).delete();
      } catch (_) {}
    }
    return _engaged;
  }

  /// Disengages: restore the snapshotted policy, delete our rules,
  /// remove the snapshot. Safe to call when not engaged (a leftover
  /// snapshot from a crashed run is still honoured — that is the sweep).
  Future<void> disengage() async {
    String restore = KillSwitchPlan.defaultPolicy;
    var hadSnapshot = false;
    try {
      final f = File(_snapshotPath);
      if (await f.exists()) {
        hadSnapshot = true;
        final saved = (await f.readAsString()).trim();
        if (KillSwitchPlan.parseFirewallPolicy(saved) != null ||
            saved == KillSwitchPlan.defaultPolicy ||
            saved == KillSwitchPlan.blockPolicy) {
          restore = saved;
        }
      }
    } catch (_) {}
    if (!_engaged && !hadSnapshot) return;
    // A crashed run may have added more allow rules than this process
    // knows about; the count from the snapshot era is unknowable, so
    // delete a generous range — deleting a rule that does not exist is
    // a harmless netsh error.
    final count = _ruleCount > 0 ? _ruleCount : 8;
    for (final cmd in KillSwitchPlan.disengageCommands(
        restorePolicy: restore, ruleCount: count)) {
      await _netsh(cmd);
    }
    try {
      await File(_snapshotPath).delete();
    } catch (_) {}
    _engaged = false;
    _ruleCount = 0;
    _log('kill switch disengaged — firewall policy restored ($restore)');
  }

  /// Startup / recovery sweep: a previous run that was hard-killed while
  /// blocked leaves the snapshot file (and the blocking policy) behind.
  /// Restore and clean up so the machine is never permanently blocked.
  /// No snapshot → nothing of ours is in force; stay silent.
  Future<void> sweep() async {
    try {
      if (!await File(_snapshotPath).exists()) return;
    } catch (_) {
      return;
    }
    _log('kill switch: leftover block from a previous run — restoring');
    await disengage();
  }
}
