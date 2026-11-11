import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../data/jalali.dart';
import '../../l10n/strings.dart';
import '../../services/license_service.dart';
import '../../services/links.dart';
import '../../theme/voidrau_theme.dart';

/// Sessions screen: lists the devices using this license, marks the current
/// one, and lets the user remove one session or all sessions except this
/// device. Data comes only from the Worker — nothing is faked.
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  bool _busy = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  S get s => S(Localizations.localeOf(context).languageCode);

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final ok = await LicenseService.instance.check();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (!ok && LicenseService.instance.lastError == 'network') {
        _error = s.isFa
            ? 'به اینترنت وصل نیستید — آخرین وضعیت ذخیره‌شده نمایش داده می‌شود'
            : 'No internet — showing the last saved state';
      }
    });
  }

  bool _isCurrent(LicenseSession session) {
    final lic = LicenseService.instance;
    if (lic.sessionId != null && session.id == lic.sessionId) return true;
    if (lic.deviceId != null &&
        session.deviceId != null &&
        session.deviceId == lic.deviceId) {
      return true;
    }
    return false;
  }

  String _lastActiveText(LicenseSession session) {
    final seen = session.lastSeenDate;
    if (seen == null) return '—';
    final j = JalaliDate.fromDateTime(seen.toLocal());
    return j.formatReadable();
  }

  IconData _platformIcon(String platform) {
    switch (platform) {
      case 'android':
        return Icons.android_rounded;
      case 'windows':
        return Icons.desktop_windows_rounded;
      case 'ios':
        return Icons.phone_iphone_rounded;
      default:
        return Icons.devices_rounded;
    }
  }

  Future<void> _deleteOne(LicenseSession session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.sessionsDeleteTitle),
        content: Text(s.sessionsDeleteBody(session.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.isFa ? 'لغو' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.sessionsDelete),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    final ok =
        await LicenseService.instance.revokeSession(session.id);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? s.sessionsDeleted : s.sessionsDeleteFailed),
      ),
    );
    if (ok) setState(() {});
  }

  Future<void> _deleteAllExceptThis() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.sessionsDeleteAllTitle),
        content: Text(s.sessionsDeleteAllBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.isFa ? 'لغو' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.sessionsDeleteAllExceptThis),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    final ok = await LicenseService.instance
        .revokeAllSessions(keepCurrent: true);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? s.sessionsDeleted : s.sessionsDeleteFailed),
      ),
    );
    if (ok) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final lic = LicenseService.instance;
    final sessions = lic.sessions;
    final maxUsers = lic.maxUsers ?? 1;
    final others = sessions.where((s) => !_isCurrent(s)).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(s.sessionsTitle),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: s.licenseRecheck,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          s.sessionsActiveCount(sessions.length, maxUsers),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          s.sessionsUpToDevices(maxUsers),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: VoidrauColors.muted),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: VoidrauColors.coral),
                  ),
                ],
                const SizedBox(height: 12),
                if (sessions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      s.sessionsEmpty,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: VoidrauColors.muted),
                    ),
                  )
                else
                  ...sessions.map((session) {
                    final current = _isCurrent(session);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          _platformIcon(session.platform),
                          color: current
                              ? VoidrauColors.cyan
                              : VoidrauColors.muted,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                session.displayName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (current)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: VoidrauColors.cyan
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  s.sessionsThisDevice,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: VoidrauColors.cyan,
                                  ),
                                ),
                              ),
                            if (session.isStale && !current) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: VoidrauColors.coral
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  s.sessionsInactive,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: VoidrauColors.coral,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${session.platformLabel}'
                          '${session.appVersion.isNotEmpty ? ' • v${session.appVersion}' : ''}\n'
                          '${s.sessionsLastActive} ${_lastActiveText(session)}',
                        ),
                        isThreeLine: true,
                        trailing: current
                            ? null
                            : IconButton(
                                onPressed:
                                    _busy ? null : () => _deleteOne(session),
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  color: VoidrauColors.coral,
                                ),
                                tooltip: s.sessionsDelete,
                              ),
                      ),
                    );
                  }),
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed:
                        _busy ? null : _deleteAllExceptThis,
                    icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                    label: Text(s.sessionsDeleteAllExceptThis),
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () =>
                      Links.open(AppInfo.botStartUrl('sessions')),
                  icon: const Icon(Icons.telegram, size: 18),
                  label: Text(s.sessionsManageInBot),
                ),
              ],
            ),
    );
  }
}
