import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../services/core_args.dart';
import '../../services/ios_policy.dart';
import '../../services/split.dart';
import '../../services/license_service.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import '../widgets/country_picker.dart';
import '../widgets/mode_cards.dart';
import 'split_page.dart';

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key, required this.controller});
  final VpnController controller;

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  // Improvement 8: collapsible sections. Advanced starts collapsed — it is
  // the rarely-touched set; the rest start open so first launch still shows
  // the settings that matter.
  bool _xrayOpen = true;
  bool _connectionOpen = true;
  bool _exitOpen = true;
  bool _hopOpen = true;
  bool _advancedOpen = false;

  /// m27: text fields mutate the settings on every keystroke but only
  /// persist 600 ms after the last one, so a half-typed value can never be
  /// lost by a rebuild and the disk is not written on every character.
  Timer? _persistDebounce;

  @override
  void dispose() {
    _persistDebounce?.cancel();
    super.dispose();
  }

  void _persistSoon() {
    _persistDebounce?.cancel();
    _persistDebounce =
        Timer(const Duration(milliseconds: 600), () => widget.controller.persist());
  }

  /// M2: reset asks first, and the Xray/Worker wiring survives it. The old
  /// reset replaced the whole settings object with no confirmation, wiping
  /// the Worker domain, UUID and token, the WARP registration, chain proxies
  /// and the exit/split rules — settings that take real work to re-enter.
  Future<void> _reset() async {
    final c = widget.controller;
    final s = c.s;
    final st = c.settings;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.resetConfirmTitle),
        content: Text(s.resetConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.reset),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final keep = VpnSettings(
      theme: st.theme,
      language: st.language,
      orbStyle: st.orbStyle,
    )
      ..workerDomain = st.workerDomain
      ..workerScriptName = st.workerScriptName
      ..workerAccountId = st.workerAccountId
      ..workerDeployed = st.workerDeployed
      ..workerFallback = st.workerFallback
      ..workerProxyIps = st.workerProxyIps
      ..warpRegistered = st.warpRegistered
      ..warpEndpoints = st.warpEndpoints
      ..xrayMode = st.xrayMode
      ..xrayVariant = st.xrayVariant
      ..serverlessFragment = st.serverlessFragment
      ..serverlessNoise = st.serverlessNoise
      ..xrayChainProxies = st.xrayChainProxies
      ..xrayChainExitId = st.xrayChainExitId;
    c.settings = keep;
    c.persist();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.resetDone)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.s;
    final st = c.settings;
    // True while Xray is the engine a (re)connect takes: Aether-only
    // settings below (protocol, exit filter, second hop) are greyed out.
    final xray = c.useXray;
    // Trial/referral users get a read-only settings page; only paid
    // licenses may change the config (user request).
    final locked = !LicenseService.instance.isPaid;

    // m28: the whole list used to sit under one AbsorbPointer, which
    // swallowed scroll drags for trial users. The list itself stays
    // scrollable now; each section's controls are individually inert when
    // locked (IgnorePointer on the section body — hit-test transparent, so
    // drags still reach the ListView), while the section headers stay
    // tappable so locked users can at least view their settings.
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      children: [
        if (locked)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              s.settingsLocked,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (Platform.isIOS)
          Text(IosPolicy.help(s.isFa),
              style:
                  TextStyle(color: VoidrauTheme.mutedOf(context), height: 1.5)),
        // Improvement 8: Xray at the top on Android (improvement 4's shared
        // mode cards, same widget as Connect and Settings).
        if (Platform.isAndroid)
          _section(
            title: s.xrayTitle,
            open: _xrayOpen,
            locked: locked,
            onToggle: (v) => setState(() => _xrayOpen = v),
            children: [
              XrayModeCards(
                mode: st.xrayMode,
                enabled: !locked,
                onChanged: (mode) {
                  st.xrayMode = mode;
                  c.persist();
                },
              ),
            ],
          ),
        _section(
          title: s.sectionConnection,
          open: _connectionOpen,
          locked: locked,
          onToggle: (v) => setState(() => _connectionOpen = v),
          children: _connectionChildren(c, s, st, xray),
        ),
        _section(
          title: s.sectionExitCountry,
          open: _exitOpen,
          locked: locked,
          onToggle: (v) => setState(() => _exitOpen = v),
          children: _exitChildren(c, s, st, xray),
        ),
        // Aether-only settings (standalone mode + second hop): greyed out
        // while Xray is the selected engine — Xray never reads them.
        if (!Platform.isIOS)
          _section(
            title: s.secondHop,
            open: _hopOpen,
            locked: locked,
            onToggle: (v) => setState(() => _hopOpen = v),
            children: _hopChildren(c, s, st, xray),
          ),
        _section(
          title: s.advanced,
          open: _advancedOpen,
          locked: locked,
          onToggle: (v) => setState(() => _advancedOpen = v),
          children: _advancedChildren(c, s, st),
        ),
        const SizedBox(height: 18),
        OutlinedButton(
          onPressed: locked ? null : _reset,
          child: Text(s.reset),
        ),
      ],
    );
  }

  List<Widget> _connectionChildren(
      VpnController c, S s, VpnSettings st, bool xray) {
    return [
      _label(s.mode),
      _seg(st.mode.name, {
        'vpn': s.deviceVpn,
        if (!Platform.isIOS) 'proxy': s.socksProxy,
      }, (v) {
        st.mode = v == 'vpn' ? ConnectionMode.vpn : ConnectionMode.proxy;
        c.persist();
      }, enabled: !xray),
      _label(s.protocol),
      ProtocolCards(
        protocol: st.protocol,
        enabled: !xray,
        onChanged: (p) {
          st.protocol = p;
          c.persist();
        },
      ),
      _label(s.scan),
      _dropdown(
        st.scan.name,
        {
          'turbo': s.scanTurbo,
          'balanced': s.scanBalanced,
          'thorough': s.scanThorough,
          'stealth': s.scanStealth,
          'ironclad': s.scanIronclad,
        },
        (v) {
          st.scan = ScanMode.values.firstWhere((e) => e.name == v);
          c.persist();
        },
      ),
      _label(s.obfuscation),
      _dropdown(st.obfuscation, const {
        'auto': 'auto',
        'firewall': 'firewall',
        'gfw': 'gfw',
        'balanced': 'balanced',
        'aggressive': 'aggressive',
        'light': 'light',
        'off': 'off',
      }, (v) {
        st.obfuscation = v;
        c.persist();
      }),
      if (st.protocol == Protocol.masque ||
          st.protocol == Protocol.mim ||
          st.protocol == Protocol.smart) ...[
        _label(s.transport),
        _seg(st.transport.name, const {'h3': 'HTTP/3', 'h2': 'HTTP/2'}, (v) {
          st.transport = v == 'h2' ? MasqueTransport.h2 : MasqueTransport.h3;
          c.persist();
        }, enabled: !xray),
      ],
      // A reverse hop only speaks TCP: the core refuses WireGuard and runs
      // MASQUE over HTTP/2, so the protocol picker above is not what runs.
      // Say so here instead of letting the user believe WireGuard was used.
      if (CoreLaunch.isReverseHop(st) && !xray)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(s.reverseForcesMasque,
              style: TextStyle(
                  color: VoidrauTheme.mutedOf(context), fontSize: 12)),
        ),
      _label(s.ipVersion),
      _seg(st.ipVersion.name, const {
        'v4': 'IPv4',
        'v6': 'IPv6',
        'dual': 'Dual',
      }, (v) {
        st.ipVersion = IpVersion.values.firstWhere((e) => e.name == v);
        c.persist();
      }),
      _label(s.endpoint),
      TextFormField(
        initialValue: st.endpoint,
        decoration: InputDecoration(
          hintText: s.endpointAuto,
          filled: true,
          fillColor: VoidrauTheme.surfaceOf(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onChanged: (v) {
          st.endpoint = v;
          _persistSoon();
        },
        onFieldSubmitted: (_) => c.persist(),
      ),
    ];
  }

  List<Widget> _exitChildren(
      VpnController c, S s, VpnSettings st, bool xray) {
    return [
      _label(s.exitFilter),
      Text(s.exitFilterHelp,
          style:
              TextStyle(color: VoidrauTheme.mutedOf(context), fontSize: 12)),
      const SizedBox(height: 8),
      _seg(st.exitFilter.name, {
        'off': s.exitOff,
        'nonIran': s.exitNonIran,
        'preferred': s.exitPreferred,
      }, (v) {
        st.exitFilter = ExitFilter.values.firstWhere((e) => e.name == v);
        // Choosing a rule by hand is also the way out of the pause the
        // one-tap answer left behind.
        st.exitRulePaused = false;
        c.persist();
      }, wrap: true, enabled: !xray),
      if (st.exitFilter == ExitFilter.preferred) ...[
        _label(s.exitPreferredCountries),
        CountryPickerRow(
          fa: s.isFa,
          enabled: !xray,
          selected: st.exitPreferred,
          onChanged: (v) {
            st.exitPreferred = v;
            c.persist();
          },
        ),
      ],
      if (st.exitRulePaused)
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            s.exitPausedBody,
            style:
                const TextStyle(color: VoidrauColors.coral, fontSize: 12),
          ),
        ),
      if (st.exitFilter != ExitFilter.off) ...[
        _label(s.exitBlockedCountries),
        CountryPickerRow(
          fa: s.isFa,
          enabled: !xray,
          selected: st.exitBlocked,
          onChanged: (v) {
            st.exitBlocked = v;
            c.persist();
          },
        ),
        _label(s.exitAskAfter),
        TextFormField(
          initialValue: '${(st.exitAskAfter / 60).round()}',
          keyboardType: TextInputType.number,
          enabled: !xray,
          onChanged: (v) {
            final m = int.tryParse(v) ?? 3;
            st.exitAskAfter = (m < 1 ? 1 : m) * 60;
            _persistSoon();
          },
          onFieldSubmitted: (_) => c.persist(),
          decoration: InputDecoration(
            filled: true,
            fillColor: VoidrauTheme.surfaceOf(context),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            helperText: s.exitPromptTitle(c.exitFilterLabel),
          ),
        ),
      ],
      const SizedBox(height: 12),
      SwitchListTile(
        value: st.coreExitLoc,
        title: Text(s.exitLock),
        subtitle: Text(s.exitLockHelp),
        onChanged: xray
            ? null
            : (v) {
                st.coreExitLoc = v;
                c.persist();
              },
      ),
    ];
  }

  List<Widget> _hopChildren(VpnController c, S s, VpnSettings st, bool xray) {
    return [
      _disabledWhen(
        xray,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Standalone top-level modes: plain Psiphon or plain Tor on the
            // proxy port, with no WARP underneath. They reuse the existing
            // standalone env (AETHER_PSIPHON* / AETHER_TOR*) — no new core
            // variables. The region/country fields below (in the second-hop
            // section) already appear for these modes, so they are not
            // duplicated here. This is the connection mode itself, so it
            // carries that label — the same words the Connect page shows.
            _label(s.connectionMode),
            Text(s.standaloneHelp,
                style: TextStyle(
                    color: VoidrauTheme.mutedOf(context), fontSize: 12)),
            const SizedBox(height: 8),
            _seg(
              st.standaloneMode.name,
              {
                'standard': s.standaloneStandard,
                'psiphonOnly': s.hopPsiphonOnly,
                'torOnly': s.hopTorOnly,
              },
              (v) {
                // Separate field from the second hop below: 'standard' only
                // clears the standalone mode; a second hop stays untouched.
                st.standaloneMode =
                    StandaloneMode.values.firstWhere((e) => e.name == v);
                c.persist();
              },
              wrap: true,
            ),
            if (st.standaloneMode == StandaloneMode.torOnly) ...[
              const SizedBox(height: 8),
              Text(s.standaloneTorHeavy,
                  style: TextStyle(
                      color: VoidrauTheme.mutedOf(context), fontSize: 12)),
            ],
            if (st.isStandaloneHop && !CoreLaunch.standaloneHopVerified) ...[
              const SizedBox(height: 8),
              Text(s.standaloneUnverified,
                  style: const TextStyle(
                      color: VoidrauColors.coral, fontSize: 12)),
            ],
            if (st.isStandaloneHop) ...[
              const SizedBox(height: 8),
              Text(s.standaloneSlow,
                  style: TextStyle(
                      color: VoidrauTheme.mutedOf(context), fontSize: 12)),
            ],
            _label(s.secondHop),
            Text(s.secondHopHelp,
                style: TextStyle(
                    color: VoidrauTheme.mutedOf(context), fontSize: 12)),
            const SizedBox(height: 8),
            // A standalone mode has no WARP underneath to carry a second hop
            // through, so the hop below is silently ignored while one is set.
            // Grey it out and say so instead of letting the user pick a hop
            // that will never run.
            if (st.isStandaloneHop)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(s.hopIgnoredNote,
                    style: TextStyle(
                        color: VoidrauTheme.mutedOf(context), fontSize: 12)),
              ),
            _disabledWhen(
              st.isStandaloneHop,
              _seg(st.secondHop.name, {
                'off': s.hopOff,
                'psiphon': s.hopPsiphon,
                'psiphonReverse': s.hopPsiphonReverse,
                'tor': s.hopTor,
                'torReverse': s.hopTorReverse,
              }, (v) {
                st.secondHop =
                    SecondHop.values.firstWhere((e) => e.name == v);
                c.persist();
              }, wrap: true),
            ),
            if (st.secondHop != SecondHop.off || st.isStandaloneHop) ...[
              if (CoreLaunch.isPsiphon(st)) ...[
                _label(s.hopRegion),
                TextFormField(
                  initialValue: st.psiphonRegion,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (v) {
                    st.psiphonRegion = v;
                    _persistSoon();
                  },
                  onFieldSubmitted: (_) => c.persist(),
                  decoration: InputDecoration(
                    helperText: s.hopRegionHelp,
                    filled: true,
                    fillColor: VoidrauTheme.surfaceOf(context),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                SwitchListTile(
                  value: st.psiphonCdn,
                  title: Text(s.hopCdn),
                  onChanged: (v) {
                    st.psiphonCdn = v;
                    c.persist();
                  },
                ),
              ] else ...[
                _label(s.torCountry),
                TextFormField(
                  initialValue: st.torCountry,
                  onChanged: (v) {
                    st.torCountry = v;
                    _persistSoon();
                  },
                  onFieldSubmitted: (_) => c.persist(),
                  decoration: InputDecoration(
                    helperText: s.torCountryHelp,
                    filled: true,
                    fillColor: VoidrauTheme.surfaceOf(context),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
              SwitchListTile(
                value: st.hopHttp,
                title: Text(s.hopHttp),
                subtitle: Text(s.hopHttpHelp),
                onChanged: (v) {
                  st.hopHttp = v;
                  c.persist();
                },
              ),
            ],
          ],
        ),
      ),
    ];
  }

  List<Widget> _advancedChildren(VpnController c, S s, VpnSettings st) {
    return [
      SwitchListTile(
        value: st.quickReconnect,
        title: Text(s.autoReconnect),
        subtitle: Text(s.autoReconnectHelp),
        onChanged: (v) {
          st.quickReconnect = v;
          c.persist();
        },
      ),
      SwitchListTile(
        value: st.fragment,
        title: Text(s.fragment),
        subtitle: Text(s.fragmentHelp),
        onChanged: (v) {
          st.fragment = v;
          c.persist();
        },
      ),
      SwitchListTile(
        value: st.autoConnect,
        title: Text(s.autoConnect),
        onChanged: (v) {
          st.autoConnect = v;
          c.persist();
        },
      ),
      SwitchListTile(
        value: st.killSwitch,
        title: Text(s.killSwitch),
        subtitle: Text(Platform.isIOS
            ? (s.isFa
                ? 'محدودکردن مسیرها با API سیستم؛ نه Always-On و نه تضمین حفاظت بین توقف و اتصال دوباره.'
                : 'System route enforcement; not Always-On or guaranteed protection between stop and restart.')
            : s.killSwitchHelp),
        onChanged: (v) {
          st.killSwitch = v;
          c.persist();
        },
      ),
      if (!Platform.isIOS)
        SwitchListTile(
          value: st.privateDns,
          title: Text(s.privateDns),
          onChanged: (v) {
            st.privateDns = v;
            c.persist();
          },
        ),
      if (!Platform.isIOS)
        SwitchListTile(
          value: st.lanShare,
          title: Text(s.lanShare),
          subtitle: Text(s.lanShareHelp),
          onChanged: (v) {
            st.lanShare = v;
            c.persist();
          },
        ),
      _label(s.splitTitle),
      Text(s.splitHelp,
          style:
              TextStyle(color: VoidrauTheme.mutedOf(context), fontSize: 12)),
      const SizedBox(height: 8),
      if (Platform.isAndroid)
        _seg(st.splitMode.name, {
          'off': s.splitOff,
          'include': s.splitInclude,
          'exclude': s.splitExclude,
        }, (v) {
          st.splitMode = SplitMode.values.firstWhere((e) => e.name == v);
          c.persist();
          c.notifyToast(s.splitApplied);
        }, wrap: true),
      if (SplitRules.summary(st, fa: s.isFa, android: Platform.isAndroid)
          .isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          SplitRules.summary(st, fa: s.isFa, android: Platform.isAndroid),
          style: const TextStyle(color: VoidrauColors.cyan, fontSize: 12),
        ),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SplitPage(controller: c)),
          ),
          icon: const Icon(Icons.alt_route_rounded, size: 18),
          label: Text(s.splitTitle),
        ),
      ),
      if (st.lanShare)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText(
            c.lanEndpoint == null
                ? '${s.lanAddress}: ${st.socksBind} → LAN ${st.socksPort + 1}'
                : '${s.lanAddress}: ${c.lanEndpoint}\n${s.lanUser}: ${c.lanUser}\n${s.lanPass}: ${c.lanPass}',
            style: TextStyle(
                color: VoidrauTheme.mutedOf(context), height: 1.4),
          ),
        ),
      SwitchListTile(
        value: st.bypassLan,
        title: Text(s.bypassLan),
        subtitle: Text(s.bypassLanHelp),
        onChanged: (v) {
          st.bypassLan = v;
          c.persist();
        },
      ),
      SwitchListTile(
        value: st.ipv6Tunnel,
        title: Text(s.ipv6Tunnel),
        onChanged: (v) {
          st.ipv6Tunnel = v;
          c.persist();
        },
      ),
      SwitchListTile(
        value: st.watchdog,
        title: Text(s.watchdog),
        subtitle: Text(s.watchdogHelp),
        onChanged: (v) {
          st.watchdog = v;
          c.persist();
        },
      ),
      SwitchListTile(
        value: st.httpProxy,
        title: Text(s.httpProxy),
        subtitle: Text(s.httpProxyHelp),
        onChanged: (v) {
          st.httpProxy = v;
          c.persist();
        },
      ),
      _label(s.socksPort),
      TextFormField(
        initialValue: '${st.socksPort}',
        keyboardType: TextInputType.number,
        onChanged: (v) {
          st.socksPort = (int.tryParse(v) ?? 1819).clamp(1024, 65535);
          _persistSoon();
        },
        onFieldSubmitted: (_) => c.persist(),
        decoration: InputDecoration(
          filled: true,
          fillColor: VoidrauTheme.surfaceOf(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      _label(s.keepalive),
      TextFormField(
        initialValue: '${st.keepalive}',
        keyboardType: TextInputType.number,
        onChanged: (v) {
          st.keepalive = (int.tryParse(v) ?? 5).clamp(1, 3600);
          _persistSoon();
        },
        onFieldSubmitted: (_) => c.persist(),
        decoration: InputDecoration(
          filled: true,
          fillColor: VoidrauTheme.surfaceOf(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      _label(s.tunMtu),
      TextFormField(
        initialValue: '${st.tunMtu}',
        keyboardType: TextInputType.number,
        onChanged: (v) {
          st.tunMtu = (int.tryParse(v) ?? 1500).clamp(576, 65535);
          _persistSoon();
        },
        onFieldSubmitted: (_) => c.persist(),
        decoration: InputDecoration(
          filled: true,
          fillColor: VoidrauTheme.surfaceOf(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          helperText: s.mtuHelp,
          helperMaxLines: 3,
        ),
      ),
      _label(s.logLevel),
      _dropdown(st.logLevel, const {
        'error': 'error',
        'warn': 'warn',
        'info': 'info',
        'debug': 'debug',
        'trace': 'trace',
      }, (v) {
        st.logLevel = v;
        c.persist();
      }),
      _label(s.stallTimeout),
      TextFormField(
        initialValue: '${st.stallTimeout}',
        keyboardType: TextInputType.number,
        onChanged: (v) {
          st.stallTimeout = (int.tryParse(v) ?? 90).clamp(15, 600);
          _persistSoon();
        },
        onFieldSubmitted: (_) => c.persist(),
        decoration: InputDecoration(
          filled: true,
          fillColor: VoidrauTheme.surfaceOf(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ];
  }

  /// A collapsible section header (improvement 8). The header itself stays
  /// tappable even when [locked] — only the body is inert — so trial users
  /// can still open a section and read their settings.
  Widget _section({
    required String title,
    required bool open,
    required ValueChanged<bool> onToggle,
    required List<Widget> children,
    bool locked = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => onToggle(!open),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                ),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more, size: 22),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: IgnorePointer(
            ignoring: locked,
            child: Opacity(
              opacity: locked ? 0.55 : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
          crossFadeState:
              open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
        Divider(height: 1, color: VoidrauTheme.lineOf(context)),
      ],
    );
  }

  /// Greys out (and blocks input on) a section whose settings belong to the
  /// engine that is not active — e.g. the Aether hop settings while Xray
  /// is selected. The values stay visible; they just cannot be changed
  /// into a setting that would silently do nothing. IgnorePointer (not
  /// AbsorbPointer) so scroll drags still reach the ListView.
  Widget _disabledWhen(bool disabled, Widget child) => Opacity(
        opacity: disabled ? 0.4 : 1,
        child: IgnorePointer(ignoring: disabled, child: child),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(t,
            style: TextStyle(
                color: VoidrauTheme.mutedOf(context), fontSize: 13)),
      );

  Widget _seg(
    String value,
    Map<String, String> items,
    ValueChanged<String> onChanged, {
    bool wrap = false,
    bool enabled = true,
  }) {
    final buttons = items.entries
        .map(
          (e) => ChoiceChip(
            label: Text(e.value, style: const TextStyle(fontSize: 12)),
            selected: value == e.key,
            onSelected: enabled ? (_) => onChanged(e.key) : null,
          ),
        )
        .toList();
    if (wrap) {
      return Wrap(spacing: 8, runSpacing: 8, children: buttons);
    }
    return Wrap(spacing: 8, children: buttons);
  }

  Widget _dropdown(
    String value,
    Map<String, String> items,
    ValueChanged<String> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      value: items.containsKey(value) ? value : items.keys.first,
      items: items.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      decoration: InputDecoration(
        filled: true,
        fillColor: VoidrauTheme.surfaceOf(context),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
