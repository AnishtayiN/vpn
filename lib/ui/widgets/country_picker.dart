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
/// (`AETHER_EXIT_LOC`, core 2.3.0 enforces it server-side and re-dials when the
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
    this.enabled = true,
  });

  /// Currently chosen ISO-3166 alpha-2 codes (any case).
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  /// Render the country names in Persian.
  final bool fa;
  final List<String> offer;

  /// False greys the chips out (inactive-engine settings): no tap changes
  /// anything while the rule does not apply.
  final bool enabled;

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
                onSelected: enabled
                    ? (_) {
                        final next = List<String>.from(selected);
                        final up = code.toUpperCase();
                        if (next.contains(up)) {
                          next.remove(up);
                        } else {
                          next.add(up);
                        }
                        onChanged(next);
                      }
                    : null,
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
    // The badge describes the rule the tunnel actually enforces, which —
    // while a Tor exit country is pinned — is the Tor override, not the
    // stored filter. See VpnSettings.effectiveExitFilter.
    final filter = st.effectiveExitFilter;
    if (filter == ExitFilter.off) return const SizedBox.shrink();
    final codes = filter == ExitFilter.preferred
        ? st.effectiveExitPreferred
        : st.effectiveExitBlocked;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          filter == ExitFilter.preferred
              ? Icons.flag_outlined
              : Icons.block,
          size: 13,
          color: VoidrauTheme.mutedOf(context),
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
            style: TextStyle(color: VoidrauTheme.mutedOf(context), fontSize: 12),
          ),
        ),
        const SizedBox(width: 4),
        Text(s.exitFilter,
            style: TextStyle(color: VoidrauTheme.mutedOf(context), fontSize: 10)),
      ],
    );
  }
}

/// Navigation row opening the country picker: label, flag + current choice,
/// chevron. Used on the Connect page (when a Psiphon/Tor hop is active) and
/// in Configurations (for the Psiphon exit country).
class CountryPickerEntryRow extends StatelessWidget {
  const CountryPickerEntryRow({
    super.key,
    required this.label,
    required this.display,
    required this.onTap,
    this.code,
  });

  /// Row label, e.g. the Psiphon/Tor exit-country title. Empty or null
  /// hides the label line (the caller may already label the row).
  final String? label;

  /// Resolved current choice: the country name, "Automatic", or
  /// "Fastest nearby".
  final String display;

  /// ISO code for the flag; null or '' shows the neutral globe badge.
  final String? code;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null && label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              label,
              style: TextStyle(
                  color: VoidrauTheme.mutedOf(context), fontSize: 13),
            ),
          ),
        Material(
          color: VoidrauTheme.surfaceOf(context),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VoidrauTheme.lineOf(context)),
              ),
              child: Row(
                children: [
                  FlagIcon(
                    countryCode:
                        (code == null || code!.isEmpty) ? null : code,
                    height: 26,
                    radius: 5,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      display,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: VoidrauTheme.mutedOf(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
