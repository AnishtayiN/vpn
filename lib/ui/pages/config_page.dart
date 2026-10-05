import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../models/settings.dart';
import '../../services/ios_policy.dart';
import '../../services/split.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import '../widgets/country_picker.dart';
import 'split_page.dart';

class ConfigPage extends StatelessWidget {
  const ConfigPage({super.key, required this.controller});
  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.s;
    final st = c.settings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      children: [
        if (Platform.isIOS)
          Text(IosPolicy.help(s.isFa),
              style: const TextStyle(color: VoidrauColors.muted, height: 1.5)),
        _label(s.mode),
        _seg(st.mode.name, {
          'vpn': s.deviceVpn,
          if (!Platform.isIOS) 'proxy': s.socksProxy,
        }, (v) {
          st.mode = v == 'vpn' ? ConnectionMode.vpn : ConnectionMode.proxy;
          c.persist();
        }),
        _label(s.protocol),
        _seg(st.protocol.name, const {
          'smart': 'Smart',
          'masque': 'MASQUE',
          'wg': 'WireGuard',
          'gool': 'gool',
          'mim': 'MASQUE×2',
        }, (v) {
          st.protocol = Protocol.values.firstWhere((e) => e.name == v);
          c.persist();
        }, wrap: true),
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
            st.transport =
                v == 'h2' ? MasqueTransport.h2 : MasqueTransport.h3;
            c.persist();
          }),
        ],
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
            hintText: 'Automatic',
            filled: true,
            fillColor: VoidrauColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (v) => st.endpoint = v,
          onFieldSubmitted: (_) => c.persist(),
        ),
        _label(s.exitFilter),
        Text(s.exitFilterHelp,
            style: const TextStyle(color: VoidrauColors.muted, fontSize: 12)),
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
        }, wrap: true),
        if (st.exitFilter == ExitFilter.preferred) ...[
          _label(s.exitPreferredCountries),
          CountryPickerRow(
            fa: s.isFa,
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
              style: const TextStyle(color: VoidrauColors.coral, fontSize: 12),
            ),
          ),
        if (st.exitFilter != ExitFilter.off) ...[
          _label(s.exitBlockedCountries),
          CountryPickerRow(
            fa: s.isFa,
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
            onChanged: (v) {
              final m = int.tryParse(v) ?? 3;
              st.exitAskAfter = (m < 1 ? 1 : m) * 60;
            },
            onFieldSubmitted: (_) => c.persist(),
            decoration: InputDecoration(
              filled: true,
              fillColor: VoidrauColors.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              helperText: s.exitPromptTitle(c.exitFilterLabel),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SwitchListTile(
          value: st.coreExitLoc,
          title: Text(s.exitLock),
          subtitle: Text(s.exitLockHelp),
          onChanged: (v) {
            st.coreExitLoc = v;
            c.persist();
          },
        ),
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
            style: const TextStyle(color: VoidrauColors.muted, fontSize: 12)),
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
              style: const TextStyle(color: VoidrauColors.muted, height: 1.4),
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
        if (!Platform.isIOS) ...[
          _label(s.secondHop),
          Text(s.secondHopHelp,
              style: const TextStyle(color: VoidrauColors.muted, fontSize: 12)),
          const SizedBox(height: 8),
          _seg(st.chain.name, {
            'off': s.hopOff,
            'psiphon': s.hopPsiphon,
            'psiphonReverse': s.hopPsiphonReverse,
            'psiphonOnly': s.hopPsiphonOnly,
            'tor': s.hopTor,
            'torReverse': s.hopTorReverse,
            'torOnly': s.hopTorOnly,
          }, (v) {
            st.chain = ChainMode.values.firstWhere((e) => e.name == v);
            c.persist();
          }, wrap: true),
          if (st.chain != ChainMode.off) ...[
            if (st.chain.name.startsWith('psiphon')) ...[
              _label(s.hopRegion),
              TextFormField(
                initialValue: st.psiphonRegion,
                textCapitalization: TextCapitalization.characters,
                onChanged: (v) => st.psiphonRegion = v,
                onFieldSubmitted: (_) => c.persist(),
                decoration: InputDecoration(
                  helperText: s.hopRegionHelp,
                  filled: true,
                  fillColor: VoidrauColors.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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
                onChanged: (v) => st.torCountry = v,
                onFieldSubmitted: (_) => c.persist(),
                decoration: InputDecoration(
                  helperText: s.torCountryHelp,
                  filled: true,
                  fillColor: VoidrauColors.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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
        SwitchListTile(
          value: st.httpProxy,
          title: Text(s.httpProxy),
          subtitle: Text(s.httpProxyHelp),
          onChanged: (v) {
            st.httpProxy = v;
            c.persist();
          },
        ),
        _label(s.advanced),
        _label(s.socksPort),
        TextFormField(
          initialValue: '${st.socksPort}',
          keyboardType: TextInputType.number,
          onChanged: (v) {
            st.socksPort = (int.tryParse(v) ?? 1819).clamp(1024, 65535);
          },
          onFieldSubmitted: (_) => c.persist(),
          decoration: InputDecoration(
            filled: true,
            fillColor: VoidrauColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        _label(s.keepalive),
        TextFormField(
          initialValue: '${st.keepalive}',
          keyboardType: TextInputType.number,
          onChanged: (v) => st.keepalive = (int.tryParse(v) ?? 5).clamp(1, 3600),
          onFieldSubmitted: (_) => c.persist(),
          decoration: InputDecoration(
            filled: true,
            fillColor: VoidrauColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        _label(s.tunMtu),
        TextFormField(
          initialValue: '${st.tunMtu}',
          keyboardType: TextInputType.number,
          onChanged: (v) => st.tunMtu = (int.tryParse(v) ?? 1500).clamp(576, 65535),
          onFieldSubmitted: (_) => c.persist(),
          decoration: InputDecoration(
            filled: true,
            fillColor: VoidrauColors.surface,
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
          onChanged: (v) => st.stallTimeout = (int.tryParse(v) ?? 90).clamp(15, 600),
          onFieldSubmitted: (_) => c.persist(),
          decoration: InputDecoration(
            filled: true,
            fillColor: VoidrauColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        const SizedBox(height: 18),
        OutlinedButton(
          onPressed: () {
            c.settings = VpnSettings(
              theme: st.theme,
              language: st.language,
              orbStyle: st.orbStyle,
            );
            c.persist();
          },
          child: Text(s.reset),
        ),
      ],
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(t, style: const TextStyle(color: VoidrauColors.muted, fontSize: 13)),
      );

  Widget _seg(
    String value,
    Map<String, String> items,
    ValueChanged<String> onChanged, {
    bool wrap = false,
  }) {
    final buttons = items.entries
        .map(
          (e) => ChoiceChip(
            label: Text(e.value, style: const TextStyle(fontSize: 12)),
            selected: value == e.key,
            onSelected: (_) => onChanged(e.key),
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
        fillColor: VoidrauColors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
