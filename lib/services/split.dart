import '../models/settings.dart';

/// Split-tunneling helpers, shared by the pickers, the launchers and the tests.
///
/// Two independent mechanisms make up "split tunneling" here, because the two
/// halves run in different places:
///
/// * **per app** — Android's `VpnService.Builder.addAllowedApplication` /
///   `addDisallowedApplication`. The kernel decides, so an app on the bypass
///   list never even reaches the tunnel. Not available on Windows (a TUN
///   adapter sees packets, not processes) and not on iOS.
/// * **per destination** — the core's own routing rules
///   (`AETHER_ROUTE_DIRECT` / `AETHER_ROUTE_BLOCK`): a domain, IP, port or
///   `private` entry is sent out of the physical interface or refused. This
///   works on every platform, including under a full-device tunnel, because the
///   rules live inside the core, which is the process that dials the connection.
class SplitRules {
  /// Ready-made destination rules for the common cases.
  static const List<List<String>> presetEntries = [
    ['private'],
    ['port:25'],
  ];

  /// Entries the core understands without a value, kept in one place so the UI
  /// and the validator cannot drift apart.
  static const List<String> bareKeywords = ['private'];

  /// Prefixes the core documents (`Docs/DOCS.en.md → Routing rules`).
  static const List<String> prefixes = [
    'full:',
    'keyword:',
    'regexp:',
    'domain:',
    'suffix:',
    'ip:',
    'cidr:',
    'port:',
    'geoip:',
  ];

  /// Why an entry cannot be used, or null when it is fine.
  ///
  /// The rules travel as one comma-separated environment value
  /// (`AETHER_ROUTE_DIRECT=a.example,b.example`), so a comma, a space or a
  /// newline inside an entry would silently split or truncate the list.
  static String? problem(String raw) {
    final entry = raw.trim();
    if (entry.isEmpty) return 'empty';
    if (entry.contains(',')) return 'comma';
    if (RegExp(r'\s').hasMatch(entry)) return 'space';
    if (entry.contains('=')) return 'equals';
    if (entry.startsWith('#')) return 'comment';
    if (entry.length > 256) return 'too-long';
    // A bare prefix ("port:") matches everything.
    for (final p in prefixes) {
      if (entry == p) return 'empty-value';
    }
    return null;
  }

  static bool valid(String raw) => problem(raw) == null;

  /// Trims, drops the unusable entries and de-duplicates, keeping the order the
  /// user typed so the list reads back the way it was written.
  static List<String> normalize(Iterable<String> raw) {
    final out = <String>[];
    for (final e in raw) {
      final v = canonical(e);
      if (v.isEmpty || !valid(v) || out.contains(v)) continue;
      out.add(v);
    }
    return out;
  }

  /// Spells out the entries the core would misread.
  ///
  /// The core splits an entry on its first `:`, so a bare IPv6 address or
  /// prefix (`2001:db8::/32`) is read as an unknown rule name and dropped;
  /// `ip:` / `cidr:` are the documented spellings. Everything else is kept
  /// exactly as typed.
  static String canonical(String raw) {
    final v = raw.trim();
    if (v.isEmpty || !v.contains(':')) return v;
    // Anything already naming a rule the core knows is left untouched.
    final head = v.split(':').first.toLowerCase();
    if (prefixes.any((p) => p.startsWith(head)) ||
        bareKeywords.contains(head)) {
      return v;
    }
    final isV6 = RegExp(r'^[0-9a-fA-F:]+(/[0-9]{1,3})?$').hasMatch(v) &&
        ':'.allMatches(v).length >= 2;
    if (!isV6) return v;
    return v.contains('/') ? 'cidr:$v' : 'ip:$v';
  }

  /// Splits a pasted blob — commas, semicolons or newlines — into entries.
  static List<String> parse(String blob) =>
      normalize(blob.split(RegExp(r'[,;\r\n]+')));

  /// Serialises the list back into one editable string.
  static String join(List<String> entries) => normalize(entries).join(', ');

  /// True when a destination rule list is in play.
  static bool routingActive(VpnSettings s) =>
      s.routeDirect.isNotEmpty || s.routeBlock.isNotEmpty;

  /// True for an IPv4 network or address entry ("10.0.0.0/8", "1.2.3.4").
  static bool isIpv4(String entry) =>
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$').hasMatch(entry);

  /// A `network mask` pair for `route add`, or null when the entry is not an
  /// IPv4 network.
  static List<String>? ipv4NetworkMask(String entry) {
    if (!isIpv4(entry)) return null;
    final parts = entry.split('/');
    final octets = parts[0].split('.').map(int.parse).toList();
    for (final o in octets) {
      if (o > 255) return null;
    }
    final prefix = parts.length == 2 ? int.parse(parts[1]) : 32;
    if (prefix > 32) return null;
    var mask = 0;
    for (var i = 0; i < 32; i++) {
      if (i < prefix) mask |= 1 << (31 - i);
    }
    final net = [
      for (var i = 0; i < 4; i++)
        (octets[i] & ((mask >> (24 - i * 8)) & 0xff)).toString()
    ];
    final dotted =
        '${(mask >> 24) & 0xff}.${(mask >> 16) & 0xff}.'
        '${(mask >> 8) & 0xff}.${mask & 0xff}';
    return [net.join('.'), dotted];
  }

  /// The direct rules handed to the core on this platform.
  ///
  /// Under a full-device tunnel on Windows the core's own "direct" socket is
  /// captured by the adapter and handed straight back to the core — a loop. Only
  /// destinations that also get a bypass route in the routing table (an IPv4
  /// address or network, or `private`) can leave the tunnel there, so the
  /// name-based rules are left out on Windows instead of being promised and
  /// silently looping.
  static List<String> coreDirectEntries(VpnSettings s, {required bool windows}) {
    final entries = normalize(s.routeDirect);
    if (!windows) return entries;
    return entries.where(windowsRoutable).toList();
  }

  /// True when a *direct* rule can actually leave the tunnel on Windows.
  ///
  /// The rule is applied by the core, but on Windows the core's own socket is
  /// captured by the adapter and handed straight back to it; only a destination
  /// the routing table can be told to bypass (an IPv4 address/network, or
  /// `private`) escapes that loop. The UI marks the others instead of letting
  /// the user believe they work.
  static bool windowsRoutable(String entry) =>
      entry == 'private' || isIpv4(entry);

  /// Networks Windows must route around the adapter for the direct rules to
  /// work: every IPv4 entry as `network mask`, plus the three private ranges for
  /// `private`.
  static List<List<String>> windowsBypassRoutes(VpnSettings s) {
    final out = <List<String>>[];
    for (final entry in coreDirectEntries(s, windows: true)) {
      if (entry == 'private') {
        out.addAll(const [
          ['10.0.0.0', '255.0.0.0'],
          ['172.16.0.0', '255.240.0.0'],
          ['192.168.0.0', '255.255.0.0'],
        ]);
        continue;
      }
      final pair = ipv4NetworkMask(entry);
      if (pair != null) out.add(pair);
    }
    return out;
  }

  /// True when this platform can act on the per-app list.
  static bool perAppSupported({required bool android}) => android;

  /// The app list as the picker sees it.
  ///
  /// `raw` is what the platform channel returned (`package`, `label`, and
  /// `system` where the platform can tell). Everything here is pure so the
  /// picker's search, filter and invert behaviour is testable without a device.
  static List<SplitApp> parseApps(List<Map<String, String>> raw) {
    final out = <SplitApp>[];
    final seen = <String>{};
    for (final row in raw) {
      final id = (row['package'] ?? '').trim();
      if (id.isEmpty || !seen.add(id)) continue;
      final label = (row['label'] ?? '').trim();
      out.add(SplitApp(
        id: id,
        label: label.isEmpty ? id : label,
        system: row['system'] == '1' || row['system'] == 'true',
      ));
    }
    out.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return out;
  }

  /// Rows that survive the search box and the system-app toggle.
  ///
  /// A selected app is never hidden by the system filter: a preinstalled
  /// browser that the user deliberately put on the list must stay visible (and
  /// removable), or the setting would look like it applies to something the
  /// user cannot see any more.
  static List<SplitApp> visibleApps(
    Iterable<SplitApp> apps, {
    String query = '',
    bool showSystem = true,
    Set<String> selected = const {},
  }) {
    final q = query.trim().toLowerCase();
    return apps
        .where((a) => a.system == false || showSystem || selected.contains(a.id))
        .where((a) =>
            q.isEmpty ||
            a.label.toLowerCase().contains(q) ||
            a.id.toLowerCase().contains(q))
        .toList();
  }

  /// Selection after "invert": everything visible that was not selected.
  /// Rows outside the current filter keep their state, so inverting never
  /// silently changes an app the user cannot see.
  static Set<String> invertSelection(
    Set<String> selected,
    Iterable<SplitApp> visible,
  ) {
    final out = {...selected};
    for (final app in visible) {
      if (!out.remove(app.id)) out.add(app.id);
    }
    return out;
  }

  /// One-line summary for the dashboard badge.
  static String summary(VpnSettings s, {required bool fa, required bool android}) {
    final parts = <String>[];
    if (android && s.splitMode != SplitMode.off) {
      final n = s.splitApps.length;
      if (s.splitMode == SplitMode.include) {
        parts.add(fa ? 'فقط $n برنامه' : 'only $n apps');
      } else {
        parts.add(fa ? '$n برنامه مستثنی' : '$n apps bypassed');
      }
    }
    if (s.routeDirect.isNotEmpty) {
      parts.add(fa
          ? '${s.routeDirect.length} مقصد مستقیم'
          : '${s.routeDirect.length} direct');
    }
    if (s.routeBlock.isNotEmpty) {
      parts.add(
          fa ? '${s.routeBlock.length} مقصد مسدود' : '${s.routeBlock.length} blocked');
    }
    return parts.join(' · ');
  }
}

/// One row of the app picker.
class SplitApp {
  const SplitApp({required this.id, required this.label, this.system = false});

  /// Android package name (or an executable path on Windows).
  final String id;

  /// What the launcher shows.
  final String label;

  /// Preinstalled, as opposed to installed by the user.
  final bool system;

  @override
  String toString() => '$label <$id>${system ? ' [system]' : ''}';
}
