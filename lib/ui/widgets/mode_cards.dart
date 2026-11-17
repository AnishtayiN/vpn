import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../theme/voidrau_theme.dart';

/// Tappable mode cards (improvement 4): icon + name + one-line benefit +
/// selected ring. The Xray choice used to be duplicated as ChoiceChips in
/// Connect, Config and Settings; it is defined once here and reused by all
/// three pages, so the options can never drift apart again.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.name,
    required this.benefit,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String name;
  final String benefit;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final card = InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? VoidrauColors.cyan.withValues(alpha: 0.12)
              : VoidrauTheme.surfaceOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? VoidrauColors.cyan
                : VoidrauTheme.lineOf(context),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 22,
              color: selected
                  ? VoidrauColors.cyan
                  : VoidrauTheme.mutedOf(context),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: selected
                          ? VoidrauColors.cyan
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    benefit,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: VoidrauTheme.mutedOf(context),
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_circle,
                size: 20,
                color: VoidrauColors.cyan,
              ),
          ],
        ),
      ),
    );
    return Opacity(opacity: enabled ? 1 : 0.45, child: card);
  }
}

class _ModeGrid extends StatelessWidget {
  const _ModeGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.4,
      children: children,
    );
  }
}

/// Xray tunnel modes: off (Aether), Worker, WARP, Serverless.
class XrayModeCards extends StatelessWidget {
  const XrayModeCards({
    super.key,
    required this.mode,
    required this.onChanged,
    this.enabled = true,
  });

  final XrayMode mode;
  final ValueChanged<XrayMode> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final s = S(Localizations.localeOf(context).languageCode);
    return _ModeGrid(
      children: [
        _ModeCard(
          icon: Icons.cloud_off_outlined,
          name: s.xrayOff,
          benefit: s.xrayOffBenefit,
          selected: mode == XrayMode.off,
          enabled: enabled,
          onTap: () => onChanged(XrayMode.off),
        ),
        _ModeCard(
          icon: Icons.cloud_queue,
          name: s.xrayWorker,
          benefit: s.xrayWorkerBenefit,
          selected: mode == XrayMode.worker,
          enabled: enabled,
          onTap: () => onChanged(XrayMode.worker),
        ),
        _ModeCard(
          icon: Icons.bolt_outlined,
          name: s.xrayWarp,
          benefit: s.xrayWarpBenefit,
          selected: mode == XrayMode.warp,
          enabled: enabled,
          onTap: () => onChanged(XrayMode.warp),
        ),
        _ModeCard(
          icon: Icons.public,
          name: s.xrayServerless,
          benefit: s.xrayServerlessBenefit,
          selected: mode == XrayMode.serverless,
          enabled: enabled,
          onTap: () => onChanged(XrayMode.serverless),
        ),
      ],
    );
  }
}

/// Aether protocols: smart, MASQUE, WireGuard, gool, MASQUE×2. The names
/// are technical terms, identical in fa and en; the benefit lines are
/// localised through S.
class ProtocolCards extends StatelessWidget {
  const ProtocolCards({
    super.key,
    required this.protocol,
    required this.onChanged,
    this.enabled = true,
  });

  final Protocol protocol;
  final ValueChanged<Protocol> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final s = S(Localizations.localeOf(context).languageCode);
    return _ModeGrid(
      children: [
        _ModeCard(
          icon: Icons.auto_awesome_outlined,
          name: 'Smart',
          benefit: s.protoSmartBenefit,
          selected: protocol == Protocol.smart,
          enabled: enabled,
          onTap: () => onChanged(Protocol.smart),
        ),
        _ModeCard(
          icon: Icons.shield_outlined,
          name: 'MASQUE',
          benefit: s.protoMasqueBenefit,
          selected: protocol == Protocol.masque,
          enabled: enabled,
          onTap: () => onChanged(Protocol.masque),
        ),
        _ModeCard(
          icon: Icons.cable_outlined,
          name: 'WireGuard',
          benefit: s.protoWgBenefit,
          selected: protocol == Protocol.wg,
          enabled: enabled,
          onTap: () => onChanged(Protocol.wg),
        ),
        _ModeCard(
          icon: Icons.privacy_tip_outlined,
          name: 'gool',
          benefit: s.protoGoolBenefit,
          selected: protocol == Protocol.gool,
          enabled: enabled,
          onTap: () => onChanged(Protocol.gool),
        ),
        _ModeCard(
          icon: Icons.layers_outlined,
          name: 'MASQUE×2',
          benefit: s.protoMimBenefit,
          selected: protocol == Protocol.mim,
          enabled: enabled,
          onTap: () => onChanged(Protocol.mim),
        ),
      ],
    );
  }
}
