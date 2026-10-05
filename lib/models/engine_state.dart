enum EnginePhase {
  disconnected,
  preparing,
  scanning,
  connecting,
  connected,
  reconnecting,
  disconnecting,
  error,
}

class EngineSnapshot {
  const EngineSnapshot({
    this.phase = EnginePhase.disconnected,
    this.message = '',
    this.protocol = '',
    this.endpoint = '',
    this.downloadBytes = 0,
    this.uploadBytes = 0,
    this.pingMs,
    this.location = '',
    this.ip = '',
    this.country = '',
    this.connectedAt,
  });

  final EnginePhase phase;
  final String message;
  final String protocol;
  final String endpoint;
  final int downloadBytes;
  final int uploadBytes;
  final int? pingMs;
  final String location;

  /// Public IP of the tunnel exit — the IP a website sees while connected.
  final String ip;

  /// ISO-3166 alpha-2 code of [ip], used to draw the exit country flag.
  final String country;

  final DateTime? connectedAt;

  bool get isActive =>
      phase == EnginePhase.connected ||
      phase == EnginePhase.connecting ||
      phase == EnginePhase.scanning ||
      phase == EnginePhase.reconnecting ||
      phase == EnginePhase.preparing;

  bool get canToggle =>
      phase == EnginePhase.disconnected ||
      phase == EnginePhase.connected ||
      phase == EnginePhase.error;

  EngineSnapshot copyWith({
    EnginePhase? phase,
    String? message,
    String? protocol,
    String? endpoint,
    int? downloadBytes,
    int? uploadBytes,
    int? pingMs,
    String? location,
    String? ip,
    String? country,
    DateTime? connectedAt,
    bool clearConnectedAt = false,

    /// Drops the exit facts (IP, country, colo) of a tunnel that has just been
    /// rejected or torn down, so the card never shows the *previous* exit while
    /// the app is still looking for a country the user accepts.
    bool clearExit = false,
  }) {
    return EngineSnapshot(
      phase: phase ?? this.phase,
      message: message ?? this.message,
      protocol: protocol ?? this.protocol,
      endpoint: endpoint ?? this.endpoint,
      downloadBytes: downloadBytes ?? this.downloadBytes,
      uploadBytes: uploadBytes ?? this.uploadBytes,
      pingMs: pingMs ?? this.pingMs,
      location: clearExit ? '' : (location ?? this.location),
      ip: clearExit ? '' : (ip ?? this.ip),
      country: clearExit ? '' : (country ?? this.country),
      connectedAt:
          clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
    );
  }
}

class LogLine {
  LogLine(this.text, {DateTime? at}) : at = at ?? DateTime.now();
  final DateTime at;
  final String text;
}

class UpdateInfo {
  const UpdateInfo({
    required this.current,
    this.latest,
    this.notes = '',
    this.apkUrl,
    this.exeUrl,
    this.apkSha256,
    this.exeSha256,
    this.htmlUrl,
    this.available = false,
    this.checkFailed = false,
  });

  final String current;
  final String? latest;
  final String notes;
  final String? apkUrl;
  final String? exeUrl;
  final String? apkSha256;
  final String? exeSha256;
  final String? htmlUrl;
  final bool available;

  /// True when the release feed could not be reached. A failed check never
  /// un-blocks an app that already knows it is outdated.
  final bool checkFailed;

  String? get platformUrl {
    // Resolved by callers that know the OS.
    return apkUrl ?? exeUrl;
  }
}
