import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/countries.dart';
import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import '../widgets/flag_icon.dart';

/// Which engine the country is picked for.
enum CountryPickerEngine { psiphon, tor }

/// UAC-style exit-country picker: a search field, an "Automatic" row, a
/// "Recommended" section and an "All countries" section. Rows carry the
/// painted flag, the localized name and an `ISO • <engine> exit` subtitle,
/// with a check on the selected row.
///
/// Tapping a row saves the choice and, when a tunnel is up, re-dials at
/// once (the new exit applies to the fresh tunnel); otherwise the choice
/// applies to the next connection.
///
/// Recommended lists are UAC's, chosen for Iran: Psiphon
/// `[de, nl, us, fr, gb, ca, se, sg, jp, au]` with the nearby countries
/// (DE NL AT PL CH SE FR GB CZ DK BE IT RS RO LT FI NO IE ES) first in the
/// full list; Tor `[de, nl, us, fr, gb, ch, se, ca, at, pl, fi, ro, bg,
/// cz, es, it, ua, sg, jp, au]` plus a "Fastest nearby" row
/// (DE NL CH AT FR SE PL GB).
class CountryPickerScreen extends StatefulWidget {
  const CountryPickerScreen({
    super.key,
    required this.controller,
    required this.engine,
  });

  final VpnController controller;
  final CountryPickerEngine engine;

  @override
  State<CountryPickerScreen> createState() => _CountryPickerScreenState();
}

enum _RowKind { automatic, fast, header, country }

class _Row {
  const _Row(this.kind, [this.code = '', this.header = '']);
  final _RowKind kind;
  final String code;
  final String header;
}

class _CountryPickerScreenState extends State<CountryPickerScreen> {
  static const List<String> _psiphonRecommended = [
    'de', 'nl', 'us', 'fr', 'gb', 'ca', 'se', 'sg', 'jp', 'au',
  ];

  /// Nearby first — countries close to Iran, nearest first (UAC's NEARBY).
  static const List<String> _psiphonNearby = [
    'de', 'nl', 'at', 'pl', 'ch', 'se', 'fr', 'gb', 'cz', 'dk',
    'be', 'it', 'rs', 'ro', 'lt', 'fi', 'no', 'ie', 'es',
  ];

  static const List<String> _torRecommended = [
    'de', 'nl', 'us', 'fr', 'gb', 'ch', 'se', 'ca', 'at', 'pl',
    'fi', 'ro', 'bg', 'cz', 'es', 'it', 'ua', 'sg', 'jp', 'au',
  ];

  String _query = '';

  bool get _isPsiphon => widget.engine == CountryPickerEngine.psiphon;

  VpnSettings get _st => widget.controller.settings;

  /// The currently picked code ('' = automatic).
  String get _selected =>
      _isPsiphon ? _st.psiphonRegion : _st.torExitCountry;

  bool get _fastSelected => !_isPsiphon && _st.torFastExit;

  bool _matchesCountry(String code, String query) {
    final needle = query.trim();
    if (needle.isEmpty) return true;
    final lower = needle.toLowerCase();
    if (code.contains(lower)) return true;
    final flag = kCountries[code];
    if (flag == null) return false;
    return flag.en.toLowerCase().contains(lower) ||
        flag.fa.contains(needle);
  }

  bool _matchesWord(String query, List<String> words) {
    final needle = query.trim();
    if (needle.isEmpty) return true;
    final lower = needle.toLowerCase();
    return words.any((w) =>
        w.toLowerCase().contains(lower) || lower.contains(w.toLowerCase()));
  }

  List<_Row> _rows(S s) {
    final recommended = _isPsiphon ? _psiphonRecommended : _torRecommended;
    final recSet = recommended.toSet();
    final allCodes = kCountries.keys.toList();
    // Psiphon: nearby countries first (in NEARBY order), then the rest
    // sorted by localized name. Tor: everything sorted by localized name.
    final List<String> allOrdered;
    if (_isPsiphon) {
      final rest = allCodes.where((c) => !_psiphonNearby.contains(c)).toList()
        ..sort((a, b) => countryLabel(a, fa: s.isFa)
            .compareTo(countryLabel(b, fa: s.isFa)));
      allOrdered = [..._psiphonNearby, ...rest];
    } else {
      allOrdered = allCodes
        ..sort((a, b) => countryLabel(a, fa: s.isFa)
            .compareTo(countryLabel(b, fa: s.isFa)));
    }
    final rows = <_Row>[];
    if (_matchesWord(_query, const [
      'auto',
      'automatic',
      'خودکار',
      'اتوماتیک',
      'بهترین',
    ])) {
      rows.add(const _Row(_RowKind.automatic));
    }
    if (!_isPsiphon &&
        _matchesWord(
            _query, const ['fast', 'fastest', 'nearby', 'سریع', 'نزدیک'])) {
      rows.add(const _Row(_RowKind.fast));
    }
    final rec = recommended.where((c) => _matchesCountry(c, _query)).toList();
    if (rec.isNotEmpty) {
      rows.add(_Row(_RowKind.header, '', s.countryRecommended));
      for (final c in rec) {
        rows.add(_Row(_RowKind.country, c));
      }
    }
    final rest = allOrdered
        .where((c) => !recSet.contains(c) && _matchesCountry(c, _query))
        .toList();
    if (rest.isNotEmpty) {
      rows.add(_Row(_RowKind.header, '', s.countryAll));
      for (final c in rest) {
        rows.add(_Row(_RowKind.country, c));
      }
    }
    return rows;
  }

  /// Saves the choice and re-dials when a tunnel is up. Tapping the row
  /// that is already selected does nothing — no redundant reconnect.
  Future<void> _apply({String code = '', bool fast = false}) async {
    final c = widget.controller;
    final s = c.s;
    final st = c.settings;
    if (_isPsiphon) {
      if (st.psiphonRegion == code) return;
      st.psiphonRegion = code;
    } else {
      if (st.torExitCountry == code && st.torFastExit == fast) return;
      st.torFastExit = fast;
      st.torExitCountry = code;
      st.torExitStrict = code.isNotEmpty;
    }
    await c.persist();
    if (!mounted) return;
    final name = code.isEmpty
        ? (fast ? s.torExitFast : s.countryAutomatic)
        : countryLabel(code, fa: s.isFa);
    final wasConnected = c.snapshot.isActive || c.busy;
    if (wasConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.countryReconnecting(name))),
      );
      unawaited(c.redial());
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.countrySelectedNext)),
      );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.s;
    final rows = _rows(s);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isPsiphon ? s.hopRegion : s.torExitCountry),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: s.countrySearch,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () => setState(() => _query = ''),
                      ),
                filled: true,
                fillColor: VoidrauTheme.surfaceOf(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          if (!_isPsiphon)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                s.torExitNote,
                style: TextStyle(
                  color: VoidrauTheme.mutedOf(context),
                  fontSize: 12,
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                switch (row.kind) {
                  case _RowKind.header:
                    return Padding(
                      padding: const EdgeInsets.only(top: 14, bottom: 6),
                      child: Text(
                        row.header,
                        style: TextStyle(
                          color: VoidrauTheme.mutedOf(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    );
                  case _RowKind.automatic:
                    return _CountryRow(
                      title: s.countryAutomatic,
                      subtitle: _isPsiphon
                          ? s.countryAutomaticPsiphon
                          : s.countryAutomaticTor,
                      selected: _selected.isEmpty && !_fastSelected,
                      onTap: () => _apply(),
                    );
                  case _RowKind.fast:
                    return _CountryRow(
                      title: s.torExitFast,
                      subtitle: s.torExitFastHelp,
                      icon: Icons.bolt_outlined,
                      selected: _fastSelected,
                      onTap: () => _apply(fast: true),
                    );
                  case _RowKind.country:
                    final code = row.code;
                    return _CountryRow(
                      title: countryLabel(code, fa: s.isFa),
                      subtitle:
                          s.countryExit(code.toUpperCase(), _isPsiphon),
                      countryCode: code,
                      selected: _selected.toLowerCase() == code,
                      onTap: () => _apply(code: code),
                    );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CountryRow extends StatelessWidget {
  const _CountryRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.countryCode,
    this.icon,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final String? countryCode;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? VoidrauColors.cyan : VoidrauTheme.mutedOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? VoidrauColors.cyan.withValues(alpha: 0.08)
            : VoidrauTheme.surfaceOf(context),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? VoidrauColors.cyan.withValues(alpha: 0.5)
                    : VoidrauTheme.lineOf(context),
              ),
            ),
            child: Row(
              children: [
                if (countryCode != null)
                  FlagIcon(countryCode: countryCode, height: 30, radius: 6)
                else if (icon != null)
                  Container(
                    width: 45,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: VoidrauTheme.surface2Of(context),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(icon, size: 20, color: accent),
                  )
                else
                  const FlagIcon(countryCode: null, height: 30, radius: 6),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: VoidrauTheme.mutedOf(context),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: VoidrauColors.cyan.withValues(alpha: 0.13),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      color: VoidrauColors.cyan,
                      size: 18,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
