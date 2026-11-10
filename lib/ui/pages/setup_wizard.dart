import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../services/cloudflare_api.dart';
import '../../services/links.dart';
import '../../services/secure_store.dart';
import '../../services/vpn_controller.dart';
import '../../services/warp.dart';
import '../../theme/voidrau_theme.dart';
import 'chain_proxies_page.dart';

/// Setup wizard for the Xray modes (Android only).
///
/// One page per account, in order:
///   1. pick the mode (Worker / WARP / Serverless),
///   2. Worker: paste the user's own Cloudflare API token → pick an account
///      → deploy the user's own Worker (a fresh VLESS UUID is generated on
///      the device; the token and the UUID go to secure storage only),
///   3. WARP: register an account on this device (keys generated on device),
///   4. Serverless: just the fragment / noise toggles.
///
/// The wizard never shows a token, UUID or private key back to the user after
/// it is saved, and it never writes one to a log. Removing the Worker account
/// wipes the token and the UUID from secure storage.
class SetupWizardPage extends StatefulWidget {
  const SetupWizardPage({super.key, required this.controller});
  final VpnController controller;

  @override
  State<SetupWizardPage> createState() => _SetupWizardPageState();
}

class _SetupWizardPageState extends State<SetupWizardPage> {
  final _token = TextEditingController();
  final _fallback = TextEditingController();
  final _proxyIps = TextEditingController();
  final _customDomain = TextEditingController();

  XrayMode _mode = XrayMode.worker;
  List<CfAccount> _accounts = const [];
  String? _accountId;
  bool _busy = false;
  String _status = '';
  bool _tokenSaved = false;

  VpnController get c => widget.controller;
  VpnSettings get st => c.settings;

  @override
  void initState() {
    super.initState();
    _mode = st.xrayMode == XrayMode.off ? XrayMode.worker : st.xrayMode;
    _fallback.text = st.workerFallback;
    _proxyIps.text = st.workerProxyIps.join('\n');
    _tokenSaved = st.workerDeployed;
  }

  @override
  void dispose() {
    _token.dispose();
    _fallback.dispose();
    _proxyIps.dispose();
    _customDomain.dispose();
    super.dispose();
  }

  void _fail(Object e) {
    setState(() {
      _busy = false;
      _status = '$e';
    });
  }

  static String _newUuid() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  /// Step 1: validate the pasted token and list the user's accounts.
  Future<void> _loadAccounts() async {
    final s = c.s;
    setState(() {
      _busy = true;
      _status = s.wizardCheckingToken;
    });
    try {
      final token = CloudflareApi.normalizeToken(_token.text);
      final api = CloudflareApi(token);
      final accounts = await api.accounts();
      api.close();
      if (accounts.isEmpty) throw const CloudflareException('No accounts');
      setState(() {
        _busy = false;
        _status = '';
        _accounts = accounts;
        _accountId = accounts.first.id;
      });
      await SecureStore.saveCloudflareToken(token);
    } catch (e) {
      _fail(e);
    }
  }

  /// Step 2: deploy the Worker to the chosen account.
  Future<void> _deploy() async {
    final s = c.s;
    final accountId = _accountId;
    if (accountId == null) return;
    setState(() {
      _busy = true;
      _status = s.wizardDeploying;
    });
    try {
      final token = await SecureStore.readCloudflareToken();
      if (token == null || token.isEmpty) {
        throw const CloudflareException('Token missing — paste it again.');
      }
      final uuid = _newUuid();
      final proxyIps = _proxyIps.text
          .split(RegExp(r'[\s,]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final env = CloudflareApi.encodeEnv(
        uuid: uuid,
        proxyIps: proxyIps,
        fallbackUrl: _fallback.text.trim(),
      );
      final api = CloudflareApi(token);
      final deployed = await api.deployWorker(
        accountId: accountId,
        scriptName: st.workerScriptName,
        env: env,
        customDomain:
            _customDomain.text.trim().isEmpty ? null : _customDomain.text.trim(),
      );
      api.close();
      await SecureStore.saveWorkerUuid(uuid);
      st.workerDomain = deployed.domain;
      st.workerAccountId = deployed.accountId;
      st.workerDeployed = true;
      st.workerFallback = _fallback.text.trim();
      st.workerProxyIps = proxyIps;
      st.xrayMode = XrayMode.worker;
      st.xrayVariant = XrayVariant.normal;
      await c.persist();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = s.wizardDeployed(deployed.domain);
        _tokenSaved = true;
      });
    } catch (e) {
      _fail(e);
    }
  }

  /// WARP: register an account on this device and keep its keys in secure
  /// storage.
  Future<void> _registerWarp() async {
    final s = c.s;
    setState(() {
      _busy = true;
      _status = s.wizardRegisteringWarp;
    });
    try {
      final reg = await const WarpRegistrar().register();
      await SecureStore.saveWarpAccount(jsonEncode(reg.account.toJson()));
      st.warpRegistered = true;
      st.warpEndpoints = reg.endpoints;
      st.xrayMode = XrayMode.warp;
      st.xrayVariant = XrayVariant.normal;
      await c.persist();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = s.wizardWarpDone;
      });
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _removeWorker() async {
    await SecureStore.deleteCloudflareToken();
    await SecureStore.deleteWorkerUuid();
    st.workerDomain = '';
    st.workerAccountId = '';
    st.workerDeployed = false;
    if (st.xrayMode == XrayMode.worker) st.xrayMode = XrayMode.off;
    await c.persist();
    setState(() {
      _accounts = const [];
      _accountId = null;
      _tokenSaved = false;
      _status = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = c.s;
    if (!Platform.isAndroid) {
      return Scaffold(
        appBar: AppBar(title: Text(s.xrayTitle)),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(s.xrayAndroidOnly,
              style: const TextStyle(color: VoidrauColors.muted, height: 1.6)),
        ),
      );
    }
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(s.xrayTitle)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
            children: [
              Text(s.xrayHelp,
                  style: const TextStyle(
                      color: VoidrauColors.muted, height: 1.5)),
              const SizedBox(height: 16),
              _modePicker(s),
              const SizedBox(height: 18),
              if (_mode == XrayMode.worker) ..._workerSection(s),
              if (_mode == XrayMode.warp) ..._warpSection(s),
              if (_mode == XrayMode.serverless) ..._serverlessSection(s),
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(_status,
                    style: const TextStyle(
                        color: VoidrauColors.cyan, height: 1.5)),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChainProxiesPage(controller: c),
                  ),
                ),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: Text(s.chainTitle),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _modePicker(S s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.xrayModeLabel,
            style: const TextStyle(color: VoidrauColors.muted)),
        const SizedBox(height: 8),
        SegmentedButton<XrayMode>(
          segments: [
            ButtonSegment(value: XrayMode.worker, label: Text(s.xrayWorker)),
            ButtonSegment(value: XrayMode.warp, label: Text(s.xrayWarp)),
            ButtonSegment(
                value: XrayMode.serverless, label: Text(s.xrayServerless)),
          ],
          selected: {_mode},
          onSelectionChanged: (v) => setState(() => _mode = v.first),
        ),
        const SizedBox(height: 8),
        Text(
          switch (_mode) {
            XrayMode.worker => s.xrayWorkerHelp,
            XrayMode.warp => s.xrayWarpHelp,
            XrayMode.serverless => s.xrayServerlessHelp,
            XrayMode.off => '',
          },
          style: const TextStyle(color: VoidrauColors.muted, height: 1.5),
        ),
      ],
    );
  }

  List<Widget> _workerSection(S s) {
    return [
      if (!_tokenSaved) ...[
        TextField(
          controller: _token,
          decoration: InputDecoration(
            labelText: s.wizardToken,
            hintText: s.wizardTokenHint,
            border: const OutlineInputBorder(),
          ),
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton(
              onPressed: _busy ? null : _loadAccounts,
              child: Text(s.wizardCheckToken),
            ),
            const SizedBox(width: 10),
            TextButton.icon(
              onPressed: () => Links.open(CloudflareApi.tokenCreationUrl()),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(s.wizardMakeToken),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(s.wizardTokenHelp,
            style: const TextStyle(
                color: VoidrauColors.muted, fontSize: 12, height: 1.5)),
      ],
      if (_accounts.isNotEmpty) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _accountId,
          decoration: InputDecoration(
            labelText: s.wizardAccount,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final a in _accounts)
              DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: (v) => setState(() => _accountId = v),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _fallback,
          decoration: InputDecoration(
            labelText: s.wizardFallback,
            hintText: s.wizardFallbackHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _proxyIps,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: s.wizardProxyIps,
            hintText: s.wizardProxyIpsHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _customDomain,
          decoration: InputDecoration(
            labelText: s.wizardCustomDomain,
            hintText: s.wizardCustomDomainHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _deploy,
          icon: const Icon(Icons.cloud_upload_rounded, size: 18),
          label: Text(s.wizardDeploy),
        ),
      ],
      if (st.workerDeployed) ...[
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              const Icon(Icons.check_circle_rounded, color: VoidrauColors.cyan),
          title: Text(st.workerDomain),
          subtitle: Text(s.wizardDeployedNote),
        ),
        TextButton.icon(
          onPressed: _busy ? null : _removeWorker,
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          label: Text(s.wizardRemoveWorker),
        ),
      ],
    ];
  }

  List<Widget> _warpSection(S s) {
    return [
      if (st.warpRegistered)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              const Icon(Icons.check_circle_rounded, color: VoidrauColors.cyan),
          title: Text(s.wizardWarpDone),
          subtitle: Text(
            st.warpEndpoints.isEmpty ? '' : st.warpEndpoints.first,
          ),
        ),
      FilledButton.icon(
        onPressed: _busy ? null : _registerWarp,
        icon: const Icon(Icons.key_rounded, size: 18),
        label: Text(
          st.warpRegistered ? s.wizardReRegisterWarp : s.wizardRegisterWarp,
        ),
      ),
      const SizedBox(height: 8),
      Text(s.wizardWarpHelp,
          style: const TextStyle(
              color: VoidrauColors.muted, fontSize: 12, height: 1.5)),
    ];
  }

  List<Widget> _serverlessSection(S s) {
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(s.xrayFragment),
        subtitle: Text(s.xrayFragmentHelp),
        value: st.serverlessFragment,
        onChanged: (v) async {
          st.serverlessFragment = v;
          st.xrayMode = XrayMode.serverless;
          await c.persist();
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(s.xrayNoise),
        subtitle: Text(s.xrayNoiseHelp),
        value: st.serverlessNoise,
        onChanged: (v) async {
          st.serverlessNoise = v;
          st.xrayMode = XrayMode.serverless;
          await c.persist();
        },
      ),
      FilledButton(
        onPressed: () async {
          st.xrayMode = XrayMode.serverless;
          await c.persist();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(s.xrayModeSaved)),
            );
          }
        },
        child: Text(s.xrayUseServerless),
      ),
    ];
  }
}
