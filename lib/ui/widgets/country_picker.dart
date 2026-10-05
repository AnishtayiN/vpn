import 'package:flutter/material.dart';

import '../../data/countries.dart';
import '../../models/settings.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import 'flag_icon.dart';

/// Chips for the exit-country rule: tap to add or remove a country from the
/// preferred / blocked list in `VpnSettings`.
///
/// Only countries the flag painter knows are offered, so a selected chip can
/// always show the flag it stands for. The rule is handed to the core itself
/// (`AETHER_EXIT_LOC`, core 2.1.0 enforces it server-side and re-dials when the
/// gateway lands elsewhere) and the controller keeps the client-side check as
/// the last word — which is why this is a rule and not a server picker: the
/// core still chooses the gateway, the rule only says which answers count.
class CountryPickerRow extends StatelessWidget {
  const CountryPickerRow({
    super.key,
    required this.selected,
    required this.onChanged,
    this.fa = false,
    this.offer = _offer,
  });

  /// Currently chosen ISO-3166 alpha-2 codes (any case).
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  /// Render the country names in Persian.
  final bool fa;
  final List<String> offer;

  /// Realistic VPN exit countries first: these are the pools gateways actually
  /// live in, so the list stays short enough to scan on a phone.
  static const List<String> _offer = [
    'de', 'nl', 'fr', 'gb', 'us', 'ca', 'se', 'no', 'fi', 'dk',
    'ch', 'at', 'be', 'pl', 'cz', 'es', 'it', 'pt', 'ie', 'is',
    'tr', 'ae', 'ro', 'bg', 'hu', 'gr', 'ua', 'ru', 'sg', 'jp',
    'au', 'br', 'in', 'za',
  ];

  @override
  Widget build(BuildContext context) {
    final chosen = selected.map((e) => e.toUpperCase()).toSet();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          for (final code in offer)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: FilterChip(
                selected: chosen.contains(code.toUpperCase()),
                avatar: FlagIcon(countryCode: code, height: 14, radius: 2),
                label: Text(
                  countryLabel(code, fa: fa),
                  style: const TextStyle(fontSize: 12),
                ),
                showCheckmark: false,
                onSelected: (_) {
                  final next = List<String>.from(selected);
                  final up = code.toUpperCase();
                  if (next.contains(up)) {
                    next.remove(up);
                  } else {
                    next.add(up);
                  }
                  onChanged(next);
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// One-line summary of the active rule, drawn with the flags it refers to.
/// Shown on the Connect page so the user can see what the app is hunting for.
class ExitFilterBadge extends StatelessWidget {
  const ExitFilterBadge({super.key, required this.controller});

  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.s;
    final st = c.settings;
    if (st.exitFilter == ExitFilter.off) return const SizedBox.shrink();
    final codes = st.exitFilter == ExitFilter.preferred
        ? st.exitPreferred
        : st.exitBlocked;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          st.exitFilter == ExitFilter.preferred
              ? Icons.flag_outlined
              : Icons.block,
          size: 13,
          color: VoidrauColors.muted,
        ),
        const SizedBox(width: 6),
        for (final code in codes.take(4))
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: FlagIcon(countryCode: code, height: 12, radius: 2),
          ),
        const SizedBox(width: 2),
        Flexible(
          child: Text(
            c.exitFilterLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: VoidrauColors.muted, fontSize: 12),
          ),
        ),
        const SizedBox(width: 4),
        Text(s.exitFilter,
            style: const TextStyle(color: VoidrauColors.muted, fontSize: 10)),
      ],
    );
  }
}
