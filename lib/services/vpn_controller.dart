import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_info.dart';
import '../data/countries.dart';
import '../l10n/strings.dart';
import '../models/engine_state.dart';
import '../models/settings.dart';
import 'core_args.dart';
import 'exit_pin.dart';
import 'ios_policy.dart';
import 'platform_engine.dart';
import 'socks_probe.dart';
import 'speed.dart';
import 'update_service.dart';
import 'windows_proxy.dart';

/// A gateway to redial: the peer address the core should use plus the protocol
/// that produced it. A named shape (rather than an inline record) so that
/// `_fallback ?? _lastExit` has a real type to unify to — two *different*
/// record shapes would collapse to plain `Record` and lose their fields.
typedef Dial = ({String endpoint, String protocol});

class VpnController extends ChangeNotifier {
  VpnController();

  final engine = PlatformEngine();
  final updates = UpdateService();

  VpnSettings settings = VpnSettings();
  EngineSnapshot snapshot = const EngineSnapshot();
  UpdateInfo? update;
  final logs = <LogLine>[];
  final apps = <Map<String, String>>[];
  bool busy = false;
  bool downloading = false;
  double downloadProgress = 0;
  String? downloadedPath;
  String? toast;
  String? lanEndpoint;
  String? lanUser;
  String? lanPass;

  /// Windows only: is this instance elevated, and which TUN bridge is carrying
  /// the device VPN. Both feed the Diagnostics page and the "run as
  /// Administrator" affordance, so the user can see *why* a full device VPN is
  /// or is not up instead of guessing from one sentence.
  bool elevated = false;
  String windowsLabel = '';

  // ── exit-country search ───────────────────────────────────────────────────
  // The tunnel core chooses its own gateway, so the exit country cannot be
  // requested up front. Instead the app dials, looks the exit IP up and — when
  // it lands somewhere the user does not want (Iran, by default) — tears the
  // tunnel down and dials again on a different carrier. [_exitTries] counts
  // those re-dials, [_rejectedExits] remembers what has already been seen so
  // the status line says something useful, and [_fallback] keeps the last
  // rejected-but-working tunnel so "connect with the Iran IP" is one tap
  // instead of a fresh scan.

  /// Exit facts of the most recent tunnel, kept across a re-dial.
  ({String ip, String country, String endpoint, String protocol})? _lastExit;

  int _exitTries = 0;
  final Map<String, int> _rejectedExits = {};
  DateTime? _exitSearchSince;
  Dial? _fallback;

  /// "Connect with the Iran IP" was chosen while a search was still in flight.
  /// The running attempt is left alone (stopping it mid-dial would fight the
  /// engine); the next pass dials the gateway that already produced that exit.
  Dial? _pendingDial;

  /// Set while the app is waiting for the user to answer the "keep looking or
  /// take the Iran IP?" question. The UI shows the dialog from this flag.
  bool exitPrompt = false;
  String exitPromptBody = '';
  Timer? _promptTimer;
  int _promptAsks = 0;

  /// True when the exit rule is actually in force: on, and not paused by the
  /// one-tap "connect with the Iran IP" answer.
  bool get exitRuleEnforced =>
      !settings.exitRulePaused && settings.exitFilter != ExitFilter.off;

  /// True while the user's rule is remembered but deliberately not enforced.
  bool get exitRulePaused => settings.exitRulePaused;

  /// True when a matching exit country is required before a tunnel is accepted.
  bool get exitFilterActive =>
      exitRuleEnforced && _wantUp && !_userDisconnect;

  /// Human-readable rule, e.g. "Germany → any country except Iran".
  String get exitFilterLabel {
    final f = settings.exitFilter;
    if (f == ExitFilter.off) return s.exitAny;
    String names(List<String> codes) => codes
        .map((c) => countryLabel(c, fa: s.isFa))
        .join(s.isFa ? '، ' : ', ');
    final want = names(settings.exitPreferred);
    final blocked = names(settings.exitBlocked);
    if (f == ExitFilter.nonIran) {
      return blocked.isEmpty ? s.exitAny : '${s.exitAnyExcept} $blocked';
    }
    return blocked.isEmpty ? want : '$want → ${s.exitAnyExcept} $blocked';
  }

  /// Status line shown while the search runs.
  String get exitSearchStatus {
    final seen = _rejectedExits.entries
        .map((e) =>
            '${countryLabel(e.key, fa: s.isFa)}${e.value > 1 ? ' ×${e.value}' : ''}')
        .join(s.isFa ? '، ' : ', ');
    return s.exitSearching(
      exitFilterLabel,
      seen,
      _exitTries,
      settings.exitMaxTries,
    );
  }

  /// Mandatory-update state. When a release newer than this build is
  /// published, the tunnel is refused and the UI switches to the update
  /// screen — an old build must not keep carrying traffic after the new one
  /// ships. The state is persisted, so starting the app offline cannot
  /// resurrect a version that has already been retired.
  bool _outdated = false;
  String _outdatedVersion = '';
  String _outdatedNotes = '';
  String? _outdatedUrl;
  DateTime? _lastReleaseCheck;

  /// The release feed is polled this often while the app runs.
  static const _updateInterval = Duration(minutes: 5);

  /// Minimum gap between two *network* release checks.
  static const _minCheckGap = Duration(seconds: 45);
  static const _forceUpdateKey = 'forceUpdate';

  /// How long the core gets to relocate itself when it already knows the exit
  /// rule (`AETHER_EXIT_LOC`). Waiting is cheaper than a teardown + rescan.
  static const exitCoreGrace = Duration(seconds: 20);

  /// Live throughput, computed from whatever byte counters the engine has:
  /// Android publishes the bridge's own through JNI, Windows parses the core's
  /// `--stats` line. See [RateMeter].
  final rate = RateMeter();

  Timer? _updateTimer;
  Timer? _statsTimer;
  Timer? _clock;
  Timer? _watchdogTimer;
  // Set while the watchdog (not the user) re-enters connect(): the exit search
  // must resume with its counter intact or exitMaxTries is never reached.
  bool _watchdogResume = false;
  StreamSubscription? _events;
  StreamSubscription? _winLogs;
  bool _wantUp = false;
  bool _userDisconnect = false;
  int _watchdogTries = 0;
  DateTime? _lastHealthy;

  S get s {
    final sys = PlatformDispatcher.instance.locale.languageCode;
    final code = settings.language == LanguageChoice.system
        ? sys
        : settings.language.name;
    return S(code == 'fa' ? 'fa' : 'en');
  }

  bool get rtl => s.isFa;

  Future<void> boot() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('settings');
    if (raw != null) {
      settings = VpnSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    if (Platform.isIOS) IosPolicy.normalize(settings);
    _events = engine.events().listen(_onEvent, onError: (_) {});
    if (Platform.isWindows) {
      _winLogs = WindowsEngine.instance.logs.listen((line) => _log(line));
      unawaited(_refreshWindowsFacts());
      // Self-heal: a run that ended hard (window closed, crash) cannot
      // clean up after itself, so it may leave the system proxy pointing at
      // our dead listener. Undo any leftover that is unambiguously ours.
      unawaited(WindowsSystemProxy.instance.restore(
          ourPort: settings.socksPort));
    }
    unawaited(engine.installedApps().then((list) {
      apps
        ..clear()
        ..addAll(list);
      notifyListeners();
    }));
    if (!Platform.isIOS) await _restoreForceUpdate(prefs);
    // Hand the native side the retired flag before anything can start a
    // tunnel behind the UI's back (Quick Settings tile, boot receiver).
    await engine.saveNativePrefs(settings, blocked: _outdated);
    notifyListeners();
    // The mandatory gate runs regardless of the "automatic checks" preference:
    // a published release has to reach every running app.
    unawaited(refreshUpdate(force: true));
    _updateTimer = Timer.periodic(_updateInterval, (_) {
      if (settings.autoUpdate) unawaited(refreshUpdate());
    });
    if (Platform.isIOS) await syncNativeState();
    if (settings.autoConnect && !blocked && !snapshot.isActive) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await toggle();
    }
  }

  /// A packet tunnel outlives the Flutter process. Reattach on launch/resume
  /// instead of automatically starting a second tunnel or showing a stale orb.
  Future<void> syncNativeState() async {
    if (!Platform.isIOS || busy) return;
    try {
      final status = await engine.status();
      _onEvent({...status, 'type': 'status'});
      if (status['phase'] == 'connected') {
        final port = status['socksPort'];
        if (port is int && port >= 1024 && port <= 65535) {
          settings.socksPort = port;
        }
        _wantUp = true;
        _userDisconnect = false;
        _startStats();
        _clock?.cancel();
        _clock = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
      }
    } catch (e) {
      _log('iOS status: $e');
    }
  }

  Future<void> persist() async {
    if (Platform.isIOS) IosPolicy.normalize(settings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('settings', jsonEncode(settings.toJson()));
    await engine.saveNativePrefs(settings);
    notifyListeners();
  }

  /// True while this build must not be used: a newer release exists.
  bool get blocked => _outdated;

  /// Version the user has to install (falls back to the running version so the
  /// screen always has something to show).
  String get blockedVersion =>
      _outdatedVersion.isNotEmpty ? _outdatedVersion : (update?.latest ?? '');

  String get runningVersion => update?.current ?? AppInfo.version;

  String get blockedNotes =>
      _outdatedNotes.isNotEmpty ? _outdatedNotes : (update?.notes ?? '');

  String? get blockedUrl => _outdatedUrl ?? update?.htmlUrl;

  /// The release feed could not be reached on the last attempt.
  bool get releaseCheckFailed => update?.checkFailed == true;

  /// Checks the release feed and, when a newer build exists, takes this one out
  /// of service immediately: the tunnel is torn down and connecting is refused
  /// until the new version is installed.
  Future<void> refreshUpdate({bool force = false}) async {
    // Android/Windows releases must never retire a TestFlight build.
    if (Platform.isIOS) return;
    final now = DateTime.now();
    final last = _lastReleaseCheck;
    if (!force && last != null && now.difference(last) < _minCheckGap) {
      return; // never hammer the update check
    }
    _lastReleaseCheck = now;
    final info = await updates.check();
    update = info;
    if (!info.checkFailed) {
      if (info.available) {
        _outdated = true;
        _outdatedVersion = info.latest ?? '';
        _outdatedNotes = info.notes;
        _outdatedUrl = info.htmlUrl;
      } else {
        _outdated = false;
        _outdatedVersion = '';
        _outdatedNotes = '';
        _outdatedUrl = null;
      }
      await _persistForceUpdate();
      await engine.saveNativePrefs(settings, blocked: _outdated);
    }
    notifyListeners();
    if (!blocked) return;
    _log('release ${blockedVersion.isEmpty ? '?' : blockedVersion} published — '
        'version ${update?.current ?? AppInfo.version} is out of date');
    if (snapshot.isActive || busy) await disconnect();
    if (settings.autoDownload && !downloading && update?.available == true) {
      final wifi = await engine.isWifi();
      if (wifi) unawaited(downloadUpdate());
    }
  }

  /// Blocks a connect attempt while a newer release exists.
  Future<bool> _releaseGate() async {
    await refreshUpdate();
    return blocked;
  }

  Future<void> _restoreForceUpdate(SharedPreferences prefs) async {
    final raw = prefs.getString(_forceUpdateKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      // The notice only applies while this build is older than the release it
      // points at. Once the user installs that release, the stale note must not
      // block the very version it announced (first run after the update, even
      // offline, must already be usable).
      final target = '${json['version'] ?? ''}';
      if (target.isNotEmpty && !UpdateService.isNewer(target, AppInfo.version)) {
        await prefs.remove(_forceUpdateKey);
        return;
      }
      _outdated = true;
      _outdatedVersion = target;
      _outdatedNotes = '${json['notes'] ?? ''}';
      final url = '${json['url'] ?? ''}';
      _outdatedUrl = url.isEmpty ? null : url;
      _log('stored update notice: v${_outdatedVersion.isEmpty ? '?' : _outdatedVersion}');
    } catch (_) {
      await prefs.remove(_forceUpdateKey);
    }
  }

  Future<void> _persistForceUpdate() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_outdated) {
      await prefs.remove(_forceUpdateKey);
      return;
    }
    await prefs.setString(
      _forceUpdateKey,
      jsonEncode({
        'version': _outdatedVersion,
        'notes': _outdatedNotes,
        'url': _outdatedUrl ?? AppInfo.telegramUrl,
        'running': AppInfo.version,
      }),
    );
  }

  Future<void> openUpdate() async {
    // All user-facing update links point to Telegram — even though version check is from GitHub.
    final info = update;
    if (info == null) {
      final fallback = _outdatedUrl ?? AppInfo.telegramUrl;
      await launchUrl(Uri.parse(fallback), mode: LaunchMode.externalApplication);
      return;
    }
    await downloadUpdate();
    if (downloadedPath == null) {
      // htmlUrl is now Telegram URL (see UpdateService), so this opens Telegram channel.
      final target = info.htmlUrl ?? _outdatedUrl ?? AppInfo.telegramUrl;
      await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
    }
  }

  Future<void> downloadUpdate() async {
    if (Platform.isIOS) return;
    final info = update;
    if (info == null || downloading) return;
    final url = Platform.isAndroid ? info.apkUrl : info.exeUrl;
    final sha = Platform.isAndroid ? info.apkSha256 : info.exeSha256;
    if (url == null) {
      // No direct asset — open Telegram channel where new build is published.
      final target = info.htmlUrl ?? _outdatedUrl ?? AppInfo.telegramUrl;
      await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
      return;
    }
    downloading = true;
    downloadProgress = 0;
    notifyListeners();
    try {
      final file = await updates.download(
        url: url,
        expectedSha256: sha,
        onProgress: (p) {
          downloadProgress = p;
          notifyListeners();
        },
      );
      downloadedPath = file.path;
      if (Platform.isAndroid) {
        final same = await engine.verifyApk(file.path);
        if (!same) {
          await file.delete();
          throw const FileSystemException('APK signing certificate mismatch');
        }
      }
      await engine.installUpdate(file.path);
    } catch (e) {
      _log('update download failed: $e — opening Telegram channel ${AppInfo.telegramHandle}');
      toast = '$e';
      // On failure, fall back to Telegram channel — the only link shown to user.
      try {
        final target = info.htmlUrl ?? AppInfo.telegramUrl;
        await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
      } catch (_) {}
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    if (blocked) {
      toast = s.updateRequiredHeadline;
      notifyListeners();
      unawaited(refreshUpdate());
      return;
    }
    if (snapshot.phase == EnginePhase.connected ||
        snapshot.phase == EnginePhase.error ||
        snapshot.phase == EnginePhase.disconnecting) {
      await disconnect();
      return;
    }
    // Any mid-flight state cancels the in-flight attempt so the orb never
    // becomes a dead spinner: the native/engine stop unwinds the pipeline.
    if (snapshot.isActive || busy) {
      _wantUp = false;
      _userDisconnect = true;
      _watchdogTimer?.cancel();
      _clearExitPrompt();
      _exitSearchSince = null;
      _set(snapshot.copyWith(
          phase: EnginePhase.disconnecting, message: s.disconnecting));
      unawaited(engine.stop().whenComplete(() {
        _set(const EngineSnapshot());
      }));
      return;
    }
    await connect();
  }

  /// True when the exit rule is enforced inside the core as well, which is the
  /// only case where waiting can replace re-dialling.
  bool get _coreEnforcesExit =>
      settings.coreExitLoc && CoreLaunch.exitLoc(settings) != null;

  /// Waits for the core to relocate the tunnel to an acceptable exit.
  ///
  /// `AETHER_EXIT_LOC` is checked by the core before the SOCKS listener opens
  /// and every minute after, so a tunnel that came up in the wrong country is a
  /// tunnel the core is already about to replace. Polling the exit through the
  /// proxy costs one HTTPS request; a teardown plus a fresh scan costs seconds.
  Future<({String ip, String country, String colo, int pingMs})?>
      _awaitCoreRelocation(VpnSettings st) async {
    if (!_coreEnforcesExit) return null;
    final deadline = DateTime.now().add(exitCoreGrace);
    while (DateTime.now().isBefore(deadline) && _wantUp) {
      await Future<void>.delayed(const Duration(seconds: 5));
      if (!_wantUp) return null;
      final exit = await _probeExit();
      final cc = exit?.country ?? '';
      if (matchesExitFilter(cc, st)) return exit;
      _rememberRejected(cc);
      _log('core is relocating the exit (saw ${cc.isEmpty ? '?' : cc})');
    }
    return null;
  }

  /// Top-level so it is unit-testable without a controller (or a tunnel).
  ///
  /// An exit whose country could not be determined is *accepted*: a broken geo
  /// lookup must not turn into an endless re-dial loop.
  static bool matchesExitFilter(String? exitCountry, VpnSettings st) {
    final f = st.exitFilter;
    if (f == ExitFilter.off || st.exitRulePaused) return true;
    final c = SocksProbe.countryCode(exitCountry ?? '');
    if (c.isEmpty) return true;
    bool blocked() =>
        st.exitBlocked.map((e) => e.toUpperCase()).contains(c);
    if (f == ExitFilter.nonIran) return !blocked();
    // Preferred: the wanted countries are accepted explicitly, everything else
    // still has to clear the blocked list (so clearing the preferred list can
    // never let Iran back in).
    final want = st.exitPreferred.map((e) => e.toUpperCase());
    if (want.contains(c)) return true;
    return !blocked();
  }

  /// First dial of a search: the verified pin from the last accepted tunnel,
  /// so a gateway that reached a good exit once is tried again before any
  /// scanning. A pin never shortens validation — the attempt runs the same
  /// exit probe as a fresh scan, and a bad pin is invalidated on the spot.
  Future<Dial?> _pinnedDial() async {
    if (!exitRuleEnforced) return null;
    if (settings.endpoint.trim().isNotEmpty) return null; // manual pin wins
    final pin = await loadExitPin('');
    if (pin == null) return null;
    _log('exit pin: reusing ${pin.protocol} gateway that gave ${pin.country}');
    return (endpoint: pin.endpoint, protocol: pin.protocol);
  }

  /// After a tunnel is accepted with a dialable peer address, remember it so
  /// the next search starts there (see [ExitPin]).
  Future<void> _savePin(Dial dial, String country) async {
    if (dial.endpoint.isEmpty || !usablePeer(dial.endpoint)) return;
    await storeExitPin(ExitPin(
      endpoint: dial.endpoint,
      protocol: dial.protocol,
      country: country,
      network: await currentNetworkKind(),
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Brings the tunnel up and — while [ExitFilter] is on — keeps re-dialling
  /// until the exit IP belongs to a country the user accepts.
  Future<void> connect() async {
    if (busy) return;
    if (Platform.isIOS) IosPolicy.normalize(settings);
    // Never open a tunnel on a build that has been retired.
    if (await _releaseGate()) return;
    _wantUp = true;
    _userDisconnect = false;
    _clearExitPrompt();
    if (!_watchdogResume) {
      _exitSearchSince = null;
    }
    _fallback = null;
    busy = true;
    _set(snapshot.copyWith(
      phase: EnginePhase.preparing,
      message: s.preparing,
      clearExit: true,
    ));
    try {
      if (settings.mode == ConnectionMode.vpn &&
          (Platform.isAndroid || Platform.isIOS)) {
        final ok = await engine.prepareVpn();
        if (!ok) {
          _set(snapshot.copyWith(
            phase: EnginePhase.error,
            message: s.needVpnPerm,
          ));
          return;
        }
      }
      if (settings.mode == ConnectionMode.vpn && Platform.isWindows) {
        await _refreshWindowsFacts();
        if (!elevated) _log('$needAdminText ($windowsLabel)');
      }
      final dial = _pendingDial;
      _pendingDial = null;
      if (!exitRuleEnforced) {
        await _runAttempt(endpoint: dial?.endpoint);
        return;
      }
      // A watchdog-triggered reconnect resumes the same exit search instead of
      // restarting it, otherwise the retry loop resets the counter forever and
      // `exitMaxTries` can never be reached (infinite re-dial churn).
      final isWatchdogResume = _watchdogResume && _exitSearchSince != null;
      if (!isWatchdogResume) {
        _exitTries = 0;
        _rejectedExits.clear();
        _exitSearchSince = DateTime.now();
      }
      _log('exit filter: $exitFilterLabel');
      _armPromptTimer();
      var next = dial ?? await _pinnedDial();
      // How many times the whole ladder has been walked. Every pass after the
      // first hands the escalation a different rung, which is what makes the
      // MASQUE carrier (and with it the gateway pool) alternate.
      var epoch = 0;
      while (_wantUp) {
        // A decision taken while this loop was dialling ("connect with the Iran
        // IP", a rule changed on the Config page) lands in _pendingDial and is
        // picked up here, so the very next pass honours it.
        final requested = _pendingDial;
        if (requested != null) {
          _pendingDial = null;
          next = requested;
        }
        // Hoisted into fresh finals: a closure sees the *declared* type of a
        // captured local, never its promoted one, so the protocol name has to
        // be unwrapped before firstWhere is built.
        final hop = next;
        final hopProtocol = hop?.protocol;
        final outcome = await _runAttempt(
          endpoint: hop?.endpoint,
          epoch: epoch,
          only: hopProtocol == null
              ? null
              : Protocol.values.firstWhere((p) => p.name == hopProtocol,
                  orElse: () => settings.protocol),
        );
        epoch++;
        next = null;
        if (outcome == AttemptOutcome.accepted || !_wantUp) return;
        if (!exitRuleEnforced) {
          // The rule was switched off mid-search (usually by choosing "connect
          // with the Iran IP"): keep going, but now every exit is acceptable.
          if (outcome == AttemptOutcome.rejected) {
            final last = _lastExit;
            final Dial? fb = _pendingDial ??
                _fallback ??
                (last == null
                    ? null
                    : (endpoint: last.endpoint, protocol: last.protocol));
            _pendingDial = null;
            next = fb;
          }
          continue;
        }
        if (outcome == AttemptOutcome.rejected) _exitTries++;
        if (outcome == AttemptOutcome.rejected &&
            _exitTries >= settings.exitMaxTries) {
          _promptTimer?.cancel();
          _log('exit filter: $_exitTries tunnels rejected');
          _set(snapshot.copyWith(
            phase: EnginePhase.error,
            message: s.exitNotFound(exitFilterLabel),
            clearConnectedAt: true,
            clearExit: true,
          ));
          _scheduleWatchdog();
          return;
        }
        if (outcome == AttemptOutcome.failed) {
          // Nothing came up at all: that is a network problem, not an exit
          // problem. _runAttempt already reported it and armed the watchdog,
          // so retrying here would only churn.
          _pendingDial = null;
          return;
        }
        if (!_userDisconnect) _armPromptTimer();
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// One pass over the protocol ladder:
  ///   [AttemptOutcome.accepted] — a tunnel is up and its exit is acceptable,
  ///   [AttemptOutcome.rejected] — tunnels came up but only in countries the
  ///       user does not want, so the search should continue,
  ///   [AttemptOutcome.failed]   — no tunnel at all (this is a network error,
  ///       not an exit-country problem).
  Future<AttemptOutcome> _runAttempt({
    String? endpoint,
    Protocol? only,
    int epoch = 0,
  }) async {
    final ladder = only != null
        ? <Protocol>[only]
        : CoreLaunch.smartLadder(settings);
    var lastError = 'connect failed';
    for (var i = 0; i < ladder.length; i++) {
      if (!_wantUp) return AttemptOutcome.failed;
      final proto = ladder[i];
      // Smart Connect escalates here: the second rung takes the TCP carrier with
      // a fragmented ClientHello and ECH, and later passes alternate the carrier
      // (see [CoreLaunch.smartVariant]). The index is global across passes, so a
      // repeated search does not replay the same rung forever.
      final attempt = _variant(epoch * ladder.length + i, ladder, proto,
          endpoint: endpoint);
      _set(snapshot.copyWith(
        phase: EnginePhase.scanning,
        protocol: proto.name,
        message: _rejectedExits.isEmpty
            ? '${s.protocol}: ${proto.name}'
            : exitSearchStatus,
      ));
      try {
        await engine.start(attempt, protocol: proto);
      } catch (e) {
        lastError = '$e';
        _log('start ${proto.name}: $e');
        // The very first rung of a pass is the pinned gateway when one exists;
        // if it cannot even start, the pin is dead — drop it so the remaining
        // rungs scan fresh instead of retrying the stale peer every pass.
        if (i == 0 && epoch == 0 && endpoint != null && endpoint.isNotEmpty) {
          unawaited(invalidateExitPin());
        }
        await engine.stop();
        continue;
      }
      var up = await _waitConnected(proto);
      if (up && Platform.isIOS && _wantUp) {
        try {
          // Native readiness proves SOCKS; also prove the actual device route.
          await SocksProbe.proveDevice();
        } catch (e) {
          up = false;
          _set(snapshot.copyWith(phase: EnginePhase.error, message: '$e'));
        }
      }
      if (!_wantUp) return AttemptOutcome.failed;
      if (up) {
        final exit = await _probeExit();
        final cc = exit?.country ?? '';
        // Only a real peer address is worth remembering: the colo code from a
        // trace (`FRA`, `IAD`) is not something the core can dial.
        final ep = usablePeer(snapshot.endpoint)
            ? snapshot.endpoint
            : (usablePeer(exit?.colo) ? exit!.colo : '');
        _lastExit = (
          ip: exit?.ip ?? '',
          country: cc,
          endpoint: ep,
          protocol: proto.name,
        );
        if (matchesExitFilter(cc, settings)) {
          _finalizeConnected(proto);
          unawaited(_savePin(
            (endpoint: ep, protocol: proto.name),
            cc,
          ));
          return AttemptOutcome.accepted;
        }
        _rememberRejected(cc);
        // This gateway just produced a blocked exit: if it came from the pin,
        // the pin is stale — drop it so the next pass scans fresh.
        unawaited(invalidateExitPin());
        _log('exit ${cc.isEmpty ? '?' : cc} rejected — looking for '
            '$exitFilterLabel');
        // Remember a working tunnel that only has the wrong country: it is the
        // one-tap fallback offered when the search runs long.
        if (cc.isNotEmpty &&
            settings.exitBlocked.map((e) => e.toUpperCase()).contains(cc)) {
          _fallback = (endpoint: ep, protocol: proto.name);
        }
        // The core was handed the same rule and re-dials the gateway on its
        // own when the exit sits in a blocked country; tearing the tunnel down
        // at the first wrong answer fights that mechanism and is what makes a
        // filtered connect slow. Give it one grace window first.
        final moved = await _awaitCoreRelocation(attempt);
        if (moved != null) {
          _lastExit = (
            ip: moved.ip,
            country: moved.country,
            endpoint: ep,
            protocol: proto.name,
          );
          _finalizeConnected(proto);
          unawaited(_savePin(
            (endpoint: ep, protocol: proto.name),
            moved.country,
          ));
          return AttemptOutcome.accepted;
        }
        await engine.stop();
        _set(snapshot.copyWith(
          phase: EnginePhase.scanning,
          message: exitSearchStatus,
          clearConnectedAt: true,
          clearExit: true,
        ));
        continue;
      }
      lastError = snapshot.phase == EnginePhase.error &&
              snapshot.message.isNotEmpty
          ? snapshot.message
          : (Platform.isWindows && WindowsEngine.instance.lastError.isNotEmpty
              ? WindowsEngine.instance.lastError
              : 'timeout');
      _log('${proto.name}: $lastError');
      await engine.stop();
    }
    if (!_wantUp) return AttemptOutcome.failed;
    if (_rejectedExits.isNotEmpty && exitRuleEnforced) {
      // Tunnels came up, just not where the user wants to land: keep the
      // search honest instead of reporting a dead network. (Once the filter
      // has been switched off mid-search this branch is skipped, so a real
      // failure is still reported as a failure.)
      _set(snapshot.copyWith(
        phase: EnginePhase.scanning,
        message: exitSearchStatus,
        clearConnectedAt: true,
        clearExit: true,
      ));
      return AttemptOutcome.rejected;
    }
    _promptTimer?.cancel();
    _set(snapshot.copyWith(
      phase: EnginePhase.error,
      message: lastError,
      clearConnectedAt: true,
    ));
    _scheduleWatchdog();
    return AttemptOutcome.failed;
  }

  /// The tunnel is up *and* its exit is acceptable: publish the connected state.
  void _finalizeConnected(Protocol proto) {
    _watchdogTries = 0;
    _lastHealthy = DateTime.now();
    _promptTimer?.cancel();
    exitPrompt = false;
    _fallback = null;
    _exitSearchSince = null;
    _set(snapshot.copyWith(
      phase: EnginePhase.connected,
      protocol: snapshot.protocol.isEmpty ? proto.name : snapshot.protocol,
      message: snapshot.message.isEmpty ? s.active : snapshot.message,
      connectedAt: DateTime.now(),
    ));
    rate.reset();
    _log('exit accepted: ${snapshot.country.isEmpty ? '?' : snapshot.country} '
        '${snapshot.ip}');
    _statsTimer?.cancel();
    _startStats();
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });
  }

  /// Fresh exit lookup straight through the tunnel's own SOCKS listener. The
  /// dashboard poller has not started yet at this point, so without this the
  /// filter would judge the *previous* tunnel's country.
  Future<({String ip, String country, String colo, int pingMs})?> _probeExit() async {
    ({String ip, String country, String colo, int pingMs})? last;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline) && _wantUp) {
      try {
        final exit = await SocksProbe.exitInfo(port: settings.socksPort);
        final cc = SocksProbe.countryCode(exit.country);
        last = (
          ip: exit.ip,
          country: cc,
          colo: exit.colo,
          pingMs: exit.pingMs,
        );
        if (cc.isNotEmpty) break;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    if (last == null) return null;
    _set(snapshot.copyWith(
      ip: last.ip.isEmpty ? snapshot.ip : last.ip,
      country: last.country.isEmpty ? snapshot.country : last.country,
      location: last.colo.isEmpty ? snapshot.location : last.colo,
      pingMs: last.pingMs,
    ));
    return last;
  }

  void _rememberRejected(String cc) {
    final key = cc.isEmpty ? '??' : cc.toUpperCase();
    _rejectedExits[key] = (_rejectedExits[key] ?? 0) + 1;
    notifyListeners();
  }

  /// Ladder entry [i] as settings the core can be started with — the protocol
  /// plus whatever Smart Connect escalation that pass calls for
  /// ([CoreLaunch.smartVariant] keeps the rules in one testable place).
  VpnSettings _variant(int i, List<Protocol> ladder, Protocol proto,
          {String? endpoint}) =>
      CoreLaunch.smartVariant(settings,
          index: i, ladder: ladder, proto: proto, endpoint: endpoint);

  // ── the "still looking?" question ────────────────────────────────────────

  void _armPromptTimer() {
    _promptTimer?.cancel();
    if (!exitRuleEnforced) return;
    _exitSearchSince ??= DateTime.now();
    final wait = settings.exitAskAfter <= 0 ? 180 : settings.exitAskAfter;
    _promptTimer = Timer(Duration(seconds: wait), _maybeAsk);
  }

  /// Fires only while the search really is still running: a tunnel that came
  /// up on an accepted exit, or a user who gave up, must never be interrupted
  /// by a stale question.
  void _maybeAsk() {
    if (!_wantUp || _userDisconnect || exitPrompt) return;
    if (!exitRuleEnforced) return;
    if (snapshot.phase == EnginePhase.connected) return;
    final since = _exitSearchSince;
    if (since == null) return;
    if (DateTime.now().difference(since).inSeconds < settings.exitAskAfter) {
      _armPromptTimer();
      return;
    }
    _promptAsks++;
    // Only ever *set* the one-tap fallback here; a tunnel that came up in a
    // country other than the blocked one is not a fallback worth offering.
    final last = _lastExit;
    final cc = last?.country ?? '';
    if (last != null &&
        cc.isNotEmpty &&
        settings.exitBlocked.map((e) => e.toUpperCase()).contains(cc)) {
      _fallback = (endpoint: last.endpoint, protocol: last.protocol);
    }
    exitPromptBody = s.exitPromptBody(
      _promptAsks * (settings.exitAskAfter <= 0 ? 180 : settings.exitAskAfter) ~/
          60,
      exitFilterLabel,
      _exitTries,
    );
    exitPrompt = true;
    _log('exit search: ${settings.exitAskAfter}s elapsed — asking the user');
    notifyListeners();
  }

  void _clearExitPrompt() {
    exitPrompt = false;
    exitPromptBody = '';
    _promptTimer?.cancel();
  }

  /// "Keep scanning": the search continues and the question comes back after
  /// another [VpnSettings.exitAskAfter]. When the search had already given up
  /// (max tries reached), it is restarted from scratch.
  /// The way back from the one-tap answer: the rule was never lost, so this
  /// just stops pausing it and re-dials until an exit matches again.
  Future<void> resumeExitRule() async {
    if (!settings.exitRulePaused) return;
    settings.exitRulePaused = false;
    // acceptBlockedExit() disabled quick reconnect because it would have kept
    // the last *foreign* gateway; with the rule back on that no longer
    // applies, so restore the user's preference.
    settings.quickReconnect = true;
    await persist();
    notifyListeners();
    _log('exit rule back on: $exitFilterLabel');
    if (snapshot.isActive || busy) {
      await disconnect();
    }
    await connect();
  }

  Future<void> keepSearchingForExit() async {
    final restart = !busy && !_wantUp;
    _clearExitPrompt();
    _exitSearchSince = DateTime.now();
    _log('exit search: continuing');
    if (restart) {
      _exitTries = 0;
      _rejectedExits.clear();
      await connect();
      return;
    }
    _armPromptTimer();
    notifyListeners();
  }

  /// "Connect with the Iran IP": the rule is **paused**, not deleted. When a
  /// search is still in flight the running attempt is left alone — stopping it
  /// mid-dial would fight the engine — and the next pass dials the gateway that
  /// already produced that exit. With nothing running, a connection is started
  /// straight away on that same gateway.
  ///
  /// Pausing instead of switching the rule off is what keeps "only the local IP
  /// connects" from becoming permanent: the very next press of [resumeExitRule]
  /// puts the user's countries back, and so does a new search after the pause.
  Future<void> acceptBlockedExit() async {
    final fb = _fallback;
    final wasSearching = busy || _wantUp;
    _clearExitPrompt();
    _exitTries = 0;
    _rejectedExits.clear();
    _exitSearchSince = null;
    settings.exitRulePaused = true;
    // Quick reconnect would hand the core the last *foreign* gateway it liked;
    // the user just asked for the Iranian exit instead.
    settings.quickReconnect = false;
    _pendingDial = fb;
    await persist();
    _log(fb == null
        ? 'exit rule paused — connecting with whatever exit comes up'
        : 'exit rule paused — redialling ${fb.endpoint.isEmpty ? 'the last gateway' : fb.endpoint}');
    if (wasSearching) return; // the in-flight loop picks _pendingDial up
    if (snapshot.phase == EnginePhase.connected) return; // already up
    _pendingDial = null;
    _wantUp = true;
    _userDisconnect = false;
    await connect();
  }

  Future<void> disconnect() async {
    _wantUp = false;
    _userDisconnect = true;
    _watchdogTries = 0;
    _watchdogTimer?.cancel();
    _clearExitPrompt();
    _exitSearchSince = null;
    _exitTries = 0;
    _rejectedExits.clear();
    _fallback = null;
    _pendingDial = null;
    lanEndpoint = lanUser = lanPass = null;
    busy = true;
    _statsTimer?.cancel();
    _clock?.cancel();
    rate.reset();
    _set(snapshot.copyWith(
        phase: EnginePhase.disconnecting, message: s.disconnecting));
    try {
      await engine.stop();
    } finally {
      busy = false;
      _set(const EngineSnapshot());
    }
  }

  /// Waits for the engine (native Android service or Windows process runner)
  /// to publish `connected`. On Android that state already includes the
  /// native data-plane proof; on Windows the engine proves traffic itself
  /// before flipping the phase.
  Future<bool> _waitConnected(Protocol proto) async {
    // Generous budget: the gateway scan on a filtered network is the slow
    // part (the reference client gives MASQUE 60s, then races the h2 carrier). Cutting
    // at 60s while the core is still mid-scan is what produced the endless
    // spinner and ladder churn.
    final budget = (Platform.isAndroid || Platform.isIOS)
        ? const Duration(seconds: 210)
        : const Duration(seconds: 150);
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (!_wantUp) return false;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // Native events already flow into _onEvent; polling keeps Windows and
      // missed broadcasts honest.
      if (snapshot.phase == EnginePhase.connected) return true;
      if (snapshot.phase == EnginePhase.error) return false;
      try {
        final st = await engine.status();
        final phase = st['phase']?.toString() ?? '';
        if (phase == 'connected') {
          _set(snapshot.copyWith(
            phase: EnginePhase.connected,
            endpoint: st['endpoint']?.toString() ?? snapshot.endpoint,
            protocol: st['protocol']?.toString() ?? proto.name,
            message:
                st['message']?.toString() ?? snapshot.message,
          ));
          return true;
        }
        if (phase == 'error') {
          final msg = st['message']?.toString() ?? '';
          _set(snapshot.copyWith(
            phase: EnginePhase.error,
            message: msg.isEmpty ? snapshot.message : msg,
          ));
          return false;
        }
        // A transient 'disconnected' (restart teardown between attempts) is
        // not terminal: 'error' ends the attempt, '_wantUp' handles cancel.
        // Progress details for the spinner subtitle.
        final msg = st['message']?.toString() ?? '';
        if (msg.isNotEmpty && msg != snapshot.message) {
          _set(snapshot.copyWith(message: msg));
        }
      } catch (_) {}
      if (Platform.isWindows) {
        final win = WindowsEngine.instance;
        if (win.phase == EnginePhase.connected) {
          _set(snapshot.copyWith(
            phase: EnginePhase.connected,
            endpoint: win.endpoint,
            protocol: win.protocol,
            message: win.message,
          ));
          return true;
        }
        if (win.phase == EnginePhase.error) {
          _set(snapshot.copyWith(
            phase: EnginePhase.error,
            message: win.message,
          ));
          return false;
        }
      }
    }
    _log('connect attempt timed out after ${budget.inSeconds}s');
    return false;
  }

  /// Dashboard poller.
  ///
  /// Two different jobs, at two different costs. Every tick does one cheap
  /// plain-HTTP request through SOCKS: it is the liveness proof the watchdog
  /// judges and it refreshes the round-trip time. The full exit lookup (a DNS
  /// name plus a TLS/geo request) runs every [exitRefreshTicks] ticks instead of
  /// on every tick — it used to be a request through the tunnel every three
  /// seconds, which is traffic the user's own downloads then pay for.
  static const int exitRefreshTicks = 10;

  void _startStats() {
    _statsTimer?.cancel();
    var tick = 0;
    var inFlight = false;
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      // Reentrancy guard: when the tunnel stalls, prove() can block for its
      // full 8 s timeout and unguarded ticks would pile up concurrently.
      if (inFlight || snapshot.phase != EnginePhase.connected) return;
      inFlight = true;
      tick++;
      try {
        final ping = await SocksProbe.prove(
          port: settings.socksPort,
          attempts: 1,
          timeout: const Duration(seconds: 8),
        );
        final refreshExit = tick % exitRefreshTicks == 1;
        if (!refreshExit) {
          _set(snapshot.copyWith(pingMs: ping));
        } else {
          final exit = await SocksProbe.exitInfo(port: settings.socksPort);
          _set(snapshot.copyWith(
            pingMs: exit.pingMs,
            ip: exit.ip.isEmpty ? snapshot.ip : exit.ip,
            country: exit.country.isEmpty ? snapshot.country : exit.country,
            location: exit.colo.isEmpty ? snapshot.location : exit.colo,
          ));
        }
        _lastHealthy = DateTime.now();
      } catch (_) {
        final last = _lastHealthy;
        if (settings.watchdog &&
            last != null &&
            DateTime.now().difference(last).inSeconds >=
                settings.stallTimeout) {
          _log('watchdog: stall ${settings.stallTimeout}s');
          _set(snapshot.copyWith(phase: EnginePhase.error, message: 'stalled'));
          _scheduleWatchdog(forceReconnect: true);
        }
      } finally {
        inFlight = false;
      }
      await _readCounters();
    });
  }

  /// Pulls the byte counters out of the engine and feeds the rate meter.
  Future<void> _readCounters() async {
    try {
      final st = await engine.status();
      // Android publishes its counters through both the event stream and the
      // status poll; a platform that answers with neither keeps the last values
      // the events delivered, and the meter is fed either way.
      final down = int.tryParse('${st['download'] ?? ''}') ??
          snapshot.downloadBytes;
      final up =
          int.tryParse('${st['upload'] ?? ''}') ?? snapshot.uploadBytes;
      final endpoint = '${st['endpoint'] ?? ''}';
      _set(snapshot.copyWith(
        downloadBytes: down,
        uploadBytes: up,
        endpoint:
            endpoint.isEmpty ? snapshot.endpoint : endpoint,
      ));
      rate.update(down, up);
    } catch (_) {
      // Status is best-effort: a single failed poll never stops the meter.
    }
  }

  /// What the raw line shows, versus what the tunnel shows.
  ///
  /// The two addresses are the whole point: a user whose "exit IP" never
  /// changes (and always looks local) needs one answer to "is the VPN carrying
  /// my traffic at all?" before any theory about carriers or exits. The raw
  /// lookup deliberately bypasses every proxy, the tunnelled one goes through
  /// the core's SOCKS listener — the same path the apps use.
  String leakRawIp = '';
  String leakRawCountry = '';
  String leakTunnelIp = '';
  String leakTunnelCountry = '';
  String leakError = '';
  bool leakChecking = false;

  /// True when both lookups answered with the same public address, i.e. the
  /// traffic the phone sends is not going through the tunnel.
  bool get leakBypassed =>
      leakRawIp.isNotEmpty &&
      leakTunnelIp.isNotEmpty &&
      leakRawIp == leakTunnelIp;

  Future<void> runLeakCheck() async {
    if (leakChecking) return;
    leakChecking = true;
    leakError = '';
    notifyListeners();
    try {
      final raw = await SocksProbe.rawInfo();
      leakRawIp = raw.ip;
      leakRawCountry = raw.country;
      _log('raw line: ${raw.ip} (${raw.country.isEmpty ? '??' : raw.country})');
      if (snapshot.phase == EnginePhase.connected) {
        final exit = await SocksProbe.exitInfo(port: settings.socksPort);
        leakTunnelIp = exit.ip;
        leakTunnelCountry = exit.country;
        _log('through the tunnel: ${exit.ip} '
            '(${exit.country.isEmpty ? '??' : exit.country})');
      } else {
        leakTunnelIp = '';
        leakTunnelCountry = '';
      }
    } catch (e) {
      leakError = '$e';
      _log('leak check failed: $e');
    } finally {
      leakChecking = false;
      notifyListeners();
    }
  }

  /// Applies a new performance profile. It only takes effect on the next dial,
  /// so a running tunnel is offered the reconnect right away.
  Future<void> setPerf(PerfProfile profile) async {
    settings.perf = profile;
    settings.perfRxKb = 0;
    settings.perfTxKb = 0;
    await persist();
    _log('performance profile: ${profile.name}');
    notifyListeners();
  }

  /// True when the current split-tunnel choices are already in the running
  /// tunnel. Per-app rules are baked into the TUN device and the core's routing
  /// rules into its own process, so a change needs a re-dial — this is what the
  /// UI's "apply now" button checks.
  bool get splitNeedsRedial => snapshot.phase == EnginePhase.connected;

  /// Re-dials so the split rules (or the performance profile) take effect.
  Future<void> applyAndReconnect() async {
    if (!snapshot.isActive && !busy) return;
    _log('applying the new settings — reconnecting');
    await disconnect();
    await connect();
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    if (type == 'log') {
      _log('${event['line'] ?? event['message'] ?? ''}');
      return;
    }
    if (type == 'lan') {
      final raw = event['message']?.toString() ?? '';
      final parts = raw.split('|');
      if (parts.length >= 3) {
        lanEndpoint = parts[0];
        lanUser = parts[1];
        lanPass = parts[2];
        notifyListeners();
      }
      return;
    }
    if (type == 'status') {
      final phase = EnginePhase.values.firstWhere(
        (e) => e.name == event['phase'],
        orElse: () => snapshot.phase,
      );
      final connectedAt = int.tryParse('${event['connectedAt'] ?? 0}') ?? 0;
      _set(snapshot.copyWith(
        phase: phase,
        connectedAt: Platform.isIOS && connectedAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(connectedAt)
            : null,
        clearConnectedAt: Platform.isIOS && phase == EnginePhase.disconnected,
        clearExit: Platform.isIOS && phase == EnginePhase.disconnected,
        message: event['message']?.toString() ?? snapshot.message,
        endpoint: event['endpoint']?.toString() ?? snapshot.endpoint,
        protocol: event['protocol']?.toString() ?? snapshot.protocol,
        downloadBytes: int.tryParse('${event['download'] ?? ''}') ??
            snapshot.downloadBytes,
        uploadBytes:
            int.tryParse('${event['upload'] ?? ''}') ?? snapshot.uploadBytes,
      ));
      if (Platform.isIOS && phase == EnginePhase.disconnected && !busy) {
        _wantUp = false;
        _statsTimer?.cancel();
        _clock?.cancel();
      }
      if (phase == EnginePhase.connected) {
        _watchdogTries = 0;
        _lastHealthy = DateTime.now();
      }
      if (phase == EnginePhase.error && !_userDisconnect) {
        _scheduleWatchdog();
      }
    }
  }

  void _scheduleWatchdog({bool forceReconnect = false}) {
    if (!_wantUp || !settings.watchdog || _watchdogTries >= 5) return;
    _watchdogTries++;
    _watchdogTimer?.cancel();
    final delay = Duration(seconds: 2 * _watchdogTries);
    _watchdogTimer = Timer(delay, () {
      if (_wantUp &&
          snapshot.phase != EnginePhase.connected &&
          snapshot.phase != EnginePhase.connecting &&
          snapshot.phase != EnginePhase.scanning &&
          snapshot.phase != EnginePhase.preparing) {
        unawaited((() async {
          _watchdogResume = true;
          try {
            await connect();
          } finally {
            _watchdogResume = false;
          }
        })());
      }
    });
    if (forceReconnect) _log('watchdog: reconnect scheduled in ${delay.inSeconds}s');
  }

  /// Elevation and OS build never change for a running process, but they are
  /// only known after the first probe — and the UI shows them from the start.
  Future<void> _refreshWindowsFacts() async {
    if (!Platform.isWindows) return;
    final win = WindowsEngine.instance;
    elevated = await win.isAdmin();
    windowsLabel = (await win.windowsBuild()).label;
    notifyListeners();
  }

  /// Everything the Diagnostics page shows about the device VPN.
  Map<String, String> get tunInfo {
    if (!Platform.isWindows) return const {};
    return WindowsEngine.instance.tunInfo();
  }

  /// True when a device VPN was asked for but this instance cannot deliver it
  /// because it is not running as Administrator.
  bool get needsElevation =>
      Platform.isWindows &&
      settings.mode == ConnectionMode.vpn &&
      !elevated;

  String get needAdminText => s.needAdmin;

  /// One-tap UAC relaunch: closes this instance and reopens it elevated, so
  /// "restart as Administrator" is not a four-step manual dance.
  Future<void> restartAsAdmin() async {
    if (!Platform.isWindows) return;
    _log('restarting as Administrator…');
    final ok = await WindowsEngine.instance.restartElevated();
    if (!ok) {
      toast = s.elevationRefused;
      notifyListeners();
    }
  }

  void log(String line) => _log(line);

  /// Shows a message now. The pages use it for settings that only take effect
  /// on the next dial ("saved — reconnect to apply it"): the change is stored
  /// immediately, and pretending the running tunnel changed would be a lie.
  void notifyToast(String message) {
    toast = message;
    notifyListeners();
  }

  void _log(String line) {
    // The core's own counters arrive as log lines on Windows (AETHER_STATS),
    // and they are the only byte source there.
    final counters = CoreStats.parse(line);
    if (counters != null) {
      rate.update(counters.downBytes, counters.upBytes);
      _set(snapshot.copyWith(
        downloadBytes: counters.downBytes,
        uploadBytes: counters.upBytes,
      ));
    }
    logs.add(LogLine(line));
    if (logs.length > 800) logs.removeRange(0, logs.length - 800);
    notifyListeners();
  }

  void _set(EngineSnapshot next) {
    if (_disposed) return;
    snapshot = next;
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  Future<void> recover() async {
    await engine.recoverNetwork();
    _log('network recovery requested');
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _events?.cancel();
    _winLogs?.cancel();
    _updateTimer?.cancel();
    _statsTimer?.cancel();
    _clock?.cancel();
    _watchdogTimer?.cancel();
    _promptTimer?.cancel();
    // Windows: if the app goes away while the tunnel is still up, stop the
    // engine too — kills the tunnel core, restores the routes and hands the
    // system proxy back the way we found it.
    if (Platform.isWindows && (snapshot.isActive || busy)) {
      unawaited(WindowsEngine.instance.stop());
    }
    super.dispose();
  }
}

/// What one pass over the protocol ladder produced — see [_runAttempt].
enum AttemptOutcome { accepted, rejected, failed }

/// True when [v] can be handed to the core as a peer address. A trace's colo
/// code (`FRA`, `IAD`) looks like a hostname but is not dialable, so it must
/// never end up in the custom-endpoint field.
bool usablePeer(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return false;
  if (RegExp(r'^[A-Za-z]{2,4}$').hasMatch(s)) return false;
  return s.contains('.') || s.contains(':');
}
