import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../services/chain_proxy.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';

/// Chain proxies: the user's own proxy links, used as the exit of an Xray
/// connection (Worker / WARP — never Serverless, which has no upstream).
///
/// Only links the user enters are listed here. Nothing is bundled with the
/// app, and a UDP-only proxy (WireGuard / Hysteria2) is marked as WARP-only:
/// the Worker relays TCP only.
class ChainProxiesPage extends StatefulWidget {
  const ChainProxiesPage({super.key, required this.controller});
  final VpnController controller;

  @override
  State<ChainProxiesPage> createState() => _ChainProxiesPageState();
}

class _ChainProxiesPageState extends State<ChainProxiesPage> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  VpnController get c => widget.controller;

  Future<void> _add() async {
    final s = c.s;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    try {
      final added = parseChainProxies(text);
      final st = c.settings;
      st.xrayChainProxies = [...st.xrayChainProxies, ...added];
      await c.persist();
      _input.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.chainAdded(added.length))),
        );
      }
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${s.chainInvalid}: ${e.message}')),
        );
      }
    }
  }

  Future<void> _remove(ChainProxy proxy) async {
    final st = c.settings;
    st.xrayChainProxies =
        st.xrayChainProxies.where((p) => p.id != proxy.id).toList();
    if (st.xrayChainExitId == proxy.id) st.xrayChainExitId = '';
    await c.persist();
  }

  @override
  Widget build(BuildContext context) {
    final s = c.s;
    final st = c.settings;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final mode = st.xrayMode;
        return Scaffold(
          appBar: AppBar(title: Text(s.chainTitle)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
            children: [
              Text(s.chainHelp,
                  style:
                      const TextStyle(color: VoidrauColors.muted, height: 1.5)),
              const SizedBox(height: 6),
              Text(s.chainUdpNote,
                  style: const TextStyle(
                      color: VoidrauColors.cyan, fontSize: 12, height: 1.5)),
              const SizedBox(height: 16),
              TextField(
                controller: _input,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: s.chainHint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _add,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(s.chainAdd),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      final text = data?.text?.trim() ?? '';
                      if (text.isNotEmpty) {
                        setState(() => _input.text = text);
                      }
                    },
                    icon: const Icon(Icons.paste_rounded, size: 18),
                    label: Text(s.chainPaste),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (st.xrayChainProxies.isEmpty)
                Text(s.chainEmpty,
                    style: const TextStyle(color: VoidrauColors.muted)),
              for (final proxy in st.xrayChainProxies)
                _tile(context, s, st, proxy, mode),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(
    BuildContext context,
    S s,
    VpnSettings st,
    ChainProxy proxy,
    XrayMode mode,
  ) {
    final info = ChainInfo.of(proxy.link);
    final usable = info != null &&
        info.canChainOver(mode == XrayMode.off ? XrayMode.worker : mode);
    final isExit = st.xrayChainExitId == proxy.id ||
        (st.xrayChainExitId.isEmpty &&
            st.xrayChainProxies.isNotEmpty &&
            st.xrayChainProxies.first == proxy);
    return Card(
      color: VoidrauColors.surface,
      child: ListTile(
        title: Text(proxy.name),
        subtitle: Text(
          info == null
              ? proxy.link
              : '${info.tags.join(' · ')}\n${info.address}'
                  '${info.isUdp ? '\n${s.chainUdpOnly}' : ''}',
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!usable)
              const Icon(Icons.warning_amber_rounded,
                  color: VoidrauColors.coral, size: 20),
            IconButton(
              icon: Icon(
                isExit
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: isExit ? VoidrauColors.cyan : VoidrauColors.muted,
              ),
              tooltip: s.chainUseAsExit,
              onPressed: () async {
                st.xrayChainExitId = proxy.id;
                await c.persist();
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: VoidrauColors.coral),
              onPressed: () => _remove(proxy),
            ),
          ],
        ),
      ),
    );
  }
}
