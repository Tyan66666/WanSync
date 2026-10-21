enum SyncPlatform {
  strava('strava'),
  xingzhe('xingzhe'),
  intervalsIcu('intervals_icu'),
  outbase('outbase');

  const SyncPlatform(this.storageKey);

  /// Key used for per-platform entries in `state.json`.
  ///
  /// Share-intake uploads used to store Intervals.icu as `intervalsIcu`; the
  /// value here matches the automatic sync engine and must stay stable.
  final String storageKey;
}

enum SyncStatus { pending, success, failed, deduped }

class PlatformSyncResult {
  final SyncPlatform platform;
  final SyncStatus status;
  final int? remoteActivityId;
  final String? errorMessage;
  final String? syncedAt; // ISO8601

  const PlatformSyncResult({
    required this.platform,
    required this.status,
    this.remoteActivityId,
    this.errorMessage,
    this.syncedAt,
  });

  Map<String, dynamic> toJson() => {
    'platform': platform.name,
    'status': status.name,
    'remoteActivityId': remoteActivityId,
    'errorMessage': errorMessage,
    'syncedAt': syncedAt,
  };

  factory PlatformSyncResult.fromJson(Map<String, dynamic> json) {
    return PlatformSyncResult(
      platform: SyncPlatform.values.firstWhere(
        (p) => p.name == json['platform'],
        orElse: () => SyncPlatform.strava,
      ),
      status: SyncStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => SyncStatus.pending,
      ),
      remoteActivityId: json['remoteActivityId'] as int?,
      errorMessage: json['errorMessage'] as String?,
      syncedAt: json['syncedAt'] as String?,
    );
  }

  PlatformSyncResult copyWith({
    SyncPlatform? platform,
    SyncStatus? status,
    int? remoteActivityId,
    String? errorMessage,
    String? syncedAt,
  }) {
    return PlatformSyncResult(
      platform: platform ?? this.platform,
      status: status ?? this.status,
      remoteActivityId: remoteActivityId ?? this.remoteActivityId,
      errorMessage: errorMessage ?? this.errorMessage,
      syncedAt: syncedAt ?? this.syncedAt,
    );
  }
}

class SyncRecord {
  final String fingerprint;
  final String sourceFilename;
  final String startTime; // ISO8601 date string
  final DateTime syncedAt; // full timestamp

  /// Distance in meters (from FIT session)
  final double? distanceM;

  /// Total ascent in meters (from FIT session)
  final int? ascentM;

  /// Sport type from FIT session (e.g. cycling, running)
  final String? sport;

  final bool uploadedToStrava;
  final bool uploadedToXingzhe;
  final bool uploadedToIntervalsIcu;
  final bool uploadedToOutbase;
  final List<PlatformSyncResult> platformResults;

  const SyncRecord({
    required this.fingerprint,
    required this.sourceFilename,
    required this.startTime,
    required this.syncedAt,
    this.distanceM,
    this.ascentM,
    this.sport,
    this.uploadedToStrava = false,
    this.uploadedToXingzhe = false,
    this.uploadedToIntervalsIcu = false,
    this.uploadedToOutbase = false,
    this.platformResults = const [],
  });

  /// Display-friendly date (YYYY-MM-DD) from startTime
  String get displayDate {
    if (startTime.length >= 10) {
      return startTime.substring(0, 10);
    }
    return startTime;
  }

  /// Distance in km, rounded to 1 decimal place
  String get displayDistance {
    if (distanceM == null) return '--';
    final km = distanceM! / 1000;
    return '${km.toStringAsFixed(1)}km';
  }

  /// Ascent in m, formatted
  String get displayAscent {
    if (ascentM == null) return '--';
    return '${ascentM}m';
  }

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'sourceFilename': sourceFilename,
    'startTime': startTime,
    'syncedAt': syncedAt.toIso8601String(),
    'distanceM': distanceM,
    'ascentM': ascentM,
    'sport': sport,
    'uploadedToStrava': uploadedToStrava,
    'uploadedToXingzhe': uploadedToXingzhe,
    'uploadedToIntervalsIcu': uploadedToIntervalsIcu,
    'uploadedToOutbase': uploadedToOutbase,
    'platformResults': platformResults.map((r) => r.toJson()).toList(),
  };

  factory SyncRecord.fromJson(Map<String, dynamic> json) {
    return SyncRecord(
      fingerprint: json['fingerprint'] as String? ?? '',
      sourceFilename: json['sourceFilename'] as String? ?? '',
      startTime: json['startTime'] as String? ?? '',
      syncedAt: json['syncedAt'] != null
          ? DateTime.parse(json['syncedAt'] as String)
          : DateTime.now(),
      distanceM: (json['distanceM'] as num?)?.toDouble(),
      ascentM: json['ascentM'] as int?,
      sport: json['sport'] as String?,
      uploadedToStrava: json['uploadedToStrava'] as bool? ?? false,
      uploadedToXingzhe: json['uploadedToXingzhe'] as bool? ?? false,
      uploadedToIntervalsIcu: json['uploadedToIntervalsIcu'] as bool? ?? false,
      uploadedToOutbase: json['uploadedToOutbase'] as bool? ?? false,
      platformResults:
          (json['platformResults'] as List<dynamic>?)
              ?.map(
                (e) => PlatformSyncResult.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
    );
  }

  SyncRecord copyWith({
    String? fingerprint,
    String? sourceFilename,
    String? startTime,
    DateTime? syncedAt,
    double? distanceM,
    int? ascentM,
    String? sport,
    bool? uploadedToStrava,
    bool? uploadedToXingzhe,
    bool? uploadedToIntervalsIcu,
    bool? uploadedToOutbase,
    List<PlatformSyncResult>? platformResults,
  }) {
    return SyncRecord(
      fingerprint: fingerprint ?? this.fingerprint,
      sourceFilename: sourceFilename ?? this.sourceFilename,
      startTime: startTime ?? this.startTime,
      syncedAt: syncedAt ?? this.syncedAt,
      distanceM: distanceM ?? this.distanceM,
      ascentM: ascentM ?? this.ascentM,
      sport: sport ?? this.sport,
      uploadedToStrava: uploadedToStrava ?? this.uploadedToStrava,
      uploadedToXingzhe: uploadedToXingzhe ?? this.uploadedToXingzhe,
      uploadedToIntervalsIcu:
          uploadedToIntervalsIcu ?? this.uploadedToIntervalsIcu,
      uploadedToOutbase: uploadedToOutbase ?? this.uploadedToOutbase,
      platformResults: platformResults ?? this.platformResults,
    );
  }

  /// 合并另一条同 fingerprint 的记录。
  /// 同平台结果取 syncedAt 最新的那个，覆盖旧结果。
  SyncRecord mergeWith(SyncRecord other) {
    if (fingerprint.isNotEmpty &&
        other.fingerprint.isNotEmpty &&
        fingerprint != other.fingerprint) {
      return this;
    }
    final mergedResults = <SyncPlatform, PlatformSyncResult>{};
    for (final r in [...platformResults, ...other.platformResults]) {
      final existing = mergedResults[r.platform];
      if (existing == null) {
        mergedResults[r.platform] = r;
      } else {
        // 取 syncedAt 较新的那个
        final existingTime =
            DateTime.tryParse(existing.syncedAt ?? '') ?? DateTime(1970);
        final otherTime = DateTime.tryParse(r.syncedAt ?? '') ?? DateTime(1970);
        mergedResults[r.platform] = otherTime.isAfter(existingTime)
            ? r
            : existing;
      }
    }

    final allResults = mergedResults.values.toList()
      ..sort((a, b) => a.platform.name.compareTo(b.platform.name));

    // 以 syncedAt 最新那条为主要记录
    final thisTime = syncedAt;
    final otherTime = other.syncedAt;
    final base = otherTime.isAfter(thisTime) ? other : this;

    return SyncRecord(
      fingerprint: base.fingerprint.isNotEmpty
          ? base.fingerprint
          : (other.fingerprint.isNotEmpty ? other.fingerprint : fingerprint),
      sourceFilename: base.sourceFilename,
      startTime: base.startTime,
      syncedAt: base.syncedAt,
      distanceM: base.distanceM ?? distanceM,
      ascentM: base.ascentM ?? ascentM,
      sport: base.sport ?? sport,
      uploadedToStrava: base.uploadedToStrava || uploadedToStrava,
      uploadedToXingzhe: base.uploadedToXingzhe || uploadedToXingzhe,
      uploadedToIntervalsIcu:
          base.uploadedToIntervalsIcu || uploadedToIntervalsIcu,
      uploadedToOutbase: base.uploadedToOutbase || uploadedToOutbase,
      platformResults: allResults,
    );
  }
}
