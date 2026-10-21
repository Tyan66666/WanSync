import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/sync_record.dart';
import '../models/sync_result_banner.dart';
import 'dedupe_service.dart';

class StateStore {
  String _fallbackHistoryIdentity(SyncRecord record) {
    return 'fallback:${record.startTime}:${record.sourceFilename}';
  }

  Map<String, dynamic>? _cache;
  DateTime? _cacheTime;
  static const Duration _cacheTtl = Duration(seconds: 30);

  void invalidateCache() {
    _cache = null;
    _cacheTime = null;
  }

  String _historyIdentity(SyncRecord record) {
    if (record.fingerprint.isNotEmpty) return 'fp:${record.fingerprint}';
    return _fallbackHistoryIdentity(record);
  }

  bool _historyMatches(SyncRecord left, SyncRecord right) {
    return _historyIdentity(left) == _historyIdentity(right) ||
        _fallbackHistoryIdentity(left) == _fallbackHistoryIdentity(right);
  }

  Future<File> _stateFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/state.json');
  }

  Future<Map<String, dynamic>> _load() async {
    if (_cache != null && _cacheTime != null) {
      if (DateTime.now().difference(_cacheTime!) < _cacheTtl) {
        return _cache!;
      }
    }

    final file = await _stateFile();
    if (!await file.exists()) {
      final empty = {
        'synced': {},
        'history': <Map<String, dynamic>>[],
        'dedupeKeys': <String, dynamic>{},
      };
      _cache = empty;
      _cacheTime = DateTime.now();
      return empty;
    }
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      data.putIfAbsent('synced', () => <String, dynamic>{});
      data.putIfAbsent('history', () => <Map<String, dynamic>>[]);
      data.putIfAbsent('dedupeKeys', () => <String, dynamic>{});
      _cache = data;
      _cacheTime = DateTime.now();
      return data;
    } catch (_) {
      final fallback = {
        'synced': {},
        'history': <Map<String, dynamic>>[],
        'dedupeKeys': <String, dynamic>{},
      };
      _cache = fallback;
      _cacheTime = DateTime.now();
      return fallback;
    }
  }

  Future<void> _save(Map<String, dynamic> data) async {
    invalidateCache();
    final file = await _stateFile();
    await file.writeAsString(jsonEncode(data));
  }

  // ---- dedupe ----

  Future<bool> isSynced(String fingerprint) async {
    final data = await _load();
    return (data['synced'] as Map).containsKey(fingerprint);
  }

  /// Canonical platform storage key for `state.json`.
  ///
  /// Share-intake uploads wrote Intervals.icu as `intervalsIcu` while automatic
  /// sync uses `intervals_icu`; both spellings must resolve to the same state.
  static String _canonicalPlatform(String platform) {
    return platform == 'intervalsIcu' ? 'intervals_icu' : platform;
  }

  /// All storage keys a platform may have been stored under (legacy aliases
  /// included). The canonical key comes first.
  static List<String> _platformAliases(String platform) {
    return _canonicalPlatform(platform) == 'intervals_icu'
        ? const <String>['intervals_icu', 'intervalsIcu']
        : <String>[_canonicalPlatform(platform)];
  }

  /// 检查某 fingerprint 是否已成功上传到指定平台。
  /// 优先用 dedupeKey 查（稳定 key）；fallback 到 synced 指纹表。
  Future<bool> isAlreadyUploaded(String fingerprint, String platform) async {
    final data = await _load();
    final aliases = _platformAliases(platform);
    // 1. 优先查 dedupeKeys（稳定的，按 startTime+distance 生成）
    final dedupeKeys = data['dedupeKeys'] as Map?;
    if (dedupeKeys != null) {
      for (final entry in dedupeKeys.entries) {
        final v = entry.value;
        if (v is Map && (v['fingerprint'] as String?) == fingerprint) {
          final platforms = v['platforms'] as Map?;
          if (aliases.any((alias) => platforms?[alias] == 'success')) {
            return true;
          }
        }
      }
    }
    // 2. fallback：查 synced 指纹表（老格式兼容）
    final synced = (data['synced'] as Map)[fingerprint] as Map?;
    if (synced != null) {
      final platforms = synced['platforms'] as Map?;
      return aliases.any((alias) => platforms?[alias] == 'success');
    }
    return false;
  }

  Future<int?> getRemoteActivityId(String fingerprint, String platform) async {
    final data = await _load();
    final synced = (data['synced'] as Map)[fingerprint] as Map?;
    if (synced == null) return null;
    for (final alias in _platformAliases(platform)) {
      final id = synced['${alias}_activity_id'];
      if (id is int) return id;
      if (id is num) return id.toInt();
    }
    return null;
  }

  Future<void> clearPlatformStatus(String fingerprint, String platform) async {
    final data = await _load();
    final aliases = _platformAliases(platform);

    // 1. Clear synced table
    final synced = (data['synced'] as Map)[fingerprint] as Map?;
    if (synced != null) {
      final platforms = synced['platforms'] as Map?;
      for (final alias in aliases) {
        platforms?.remove(alias);
        synced.remove('${alias}_activity_id');
      }
    }

    // 2. Clear dedupeKeys
    final dedupeKeys = data['dedupeKeys'] as Map?;
    if (dedupeKeys != null) {
      for (final entry in dedupeKeys.entries) {
        final v = entry.value;
        if (v is Map && (v['fingerprint'] as String?) == fingerprint) {
          final platforms = v['platforms'] as Map?;
          for (final alias in aliases) {
            platforms?.remove(alias);
          }
          break;
        }
      }
    }
    await _save(data);
  }

  /// 标记 fingerprint 已成功上传到指定平台（记录 remoteActivityId）。
  /// 支持同一 fingerprint 标记多个平台，互不影响。
  Future<void> markSynced(String fingerprint, int? stravaActivityId) async {
    final data = await _load();
    final synced = (data['synced'] as Map)[fingerprint] as Map? ?? {};
    synced['strava_activity_id'] = stravaActivityId;
    synced['synced_at'] = DateTime.now().toUtc().toIso8601String();
    (data['synced'] as Map)[fingerprint] = synced;
    await _save(data);
  }

  /// 按平台标记已同步（记录该平台的成功状态）。
  /// 同时更新 dedupeKeys 中对应 entry 的 platforms 状态（保持一致性）。
  Future<void> markPlatformSynced(
    String fingerprint,
    String platform,
    int? remoteActivityId,
  ) async {
    final data = await _load();
    final canonicalPlatform = _canonicalPlatform(platform);
    final synced = (data['synced'] as Map)[fingerprint] as Map? ?? {};
    synced['platforms'] ??= {};
    (synced['platforms'] as Map)[canonicalPlatform] = 'success';
    synced['synced_at'] = DateTime.now().toUtc().toIso8601String();
    if (remoteActivityId != null) {
      synced['${canonicalPlatform}_activity_id'] = remoteActivityId;
    }
    (data['synced'] as Map)[fingerprint] = synced;

    // 同步更新 dedupeKeys 中对应 fingerprint 的 platforms 状态
    final dedupeKeys = data['dedupeKeys'] as Map?;
    if (dedupeKeys != null) {
      for (final entry in dedupeKeys.entries) {
        final v = entry.value;
        if (v is Map && (v['fingerprint'] as String?) == fingerprint) {
          (v['platforms'] as Map? ?? {})[canonicalPlatform] = 'success';
          break;
        }
      }
    }
    await _save(data);
  }

  /// Clears every platform's synced marker and dedupe keys.
  ///
  /// Sync history is intentionally kept so the user can still see what was
  /// uploaded before the reset. The next sync run treats every activity as
  /// not-yet-synced and uploads it again to all enabled platforms.
  Future<void> resetSyncState() async {
    final data = await _load();
    data['synced'] = <String, dynamic>{};
    data['dedupeKeys'] = <String, dynamic>{};
    await _save(data);
  }

  Future<String?> lastSuccessSyncTime() async {
    final data = await _load();
    final synced = data['synced'] as Map;
    if (synced.isEmpty) return null;
    return synced.values
        .map((e) => (e as Map)['synced_at'] as String)
        .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  }

  // ---- dedupeKey 持久化（时间+距离兜底判重） ----

  /// dedupeKey = "{startTime}_{distanceM}"，用于指纹不稳定时的兜底判重。
  /// dedupeKey 存在 → 说明该活动已完整同步过（所有平台），跳过下载。
  /// 同时存 fingerprint 用于后续运行按平台判断（`isAlreadyUploaded` 查询 synced 指纹表）。
  Future<bool> isDedupeKey(String dedupeKey) async {
    final data = await _load();
    final dedupeKeys = (data['dedupeKeys'] as Map?) ?? {};
    return _matchDedupeKey(dedupeKeys, dedupeKey) != null;
  }

  /// 获取 dedupeKey 对应的指纹（用于按平台跳过判断）
  Future<String?> getDedupeKeyFingerprint(String dedupeKey) async {
    final data = await _load();
    final dedupeKeys = (data['dedupeKeys'] as Map?) ?? {};
    final matchedKey = _matchDedupeKey(dedupeKeys, dedupeKey);
    if (matchedKey == null) return null;
    final entry = dedupeKeys[matchedKey];
    if (entry is! Map) return null;
    return entry['fingerprint'] as String?;
  }

  /// Matches a canonical dedupe key against stored keys.
  ///
  /// Legacy keys append the old `_timeSeconds` suffix and may embed an
  /// un-normalized start time (OneLap local ISO instead of UTC), so keys are
  /// compared by normalized start time plus distance rather than by string.
  static String? _matchDedupeKey(Map dedupeKeys, String dedupeKey) {
    if (dedupeKeys.containsKey(dedupeKey)) {
      return dedupeKey;
    }
    final (String, String)? candidates = _splitDedupeKey(dedupeKey);
    if (candidates == null) {
      return null;
    }
    for (final key in dedupeKeys.keys) {
      final (String, String)? stored = _splitDedupeKey('$key');
      if (stored == null) {
        continue;
      }
      if (stored.$1 == candidates.$1 && stored.$2 == candidates.$2) {
        return '$key';
      }
    }
    return null;
  }

  /// Splits `{startTime}_{distance}[_{duration}]` into normalized start time
  /// and distance. Returns null for keys that do not follow the format.
  static (String, String)? _splitDedupeKey(String key) {
    final List<String> parts = key.split('_');
    if (parts.length < 2 || parts[0].isEmpty) {
      return null;
    }
    return (normalizeDedupeStartTime(parts[0]), parts[1]);
  }

  /// 同步成功后保存 dedupeKey（防止指纹变化导致的重复上传）。
  /// 只在至少有一个平台成功时才调用。
  /// 若 dedupeKey 已存在（之前已同步过），不覆盖旧指纹（保持稳定性）。
  Future<void> markDedupeKey(String dedupeKey, String fingerprint) async {
    final data = await _load();
    final existing = (data['dedupeKeys'] as Map?)?[dedupeKey];
    if (existing != null) return; // 已有则不覆盖，保持首次成功的指纹稳定
    (data['dedupeKeys'] as Map? ?? {})[dedupeKey] = {
      'fingerprint': fingerprint,
      'synced_at': DateTime.now().toUtc().toIso8601String(),
      'platforms':
          <String, String>{}, // 初始化 platforms，后续 markPlatformSynced 会填充
    };
    await _save(data);
  }

  // ---- sync history ----

  /// Save a batch of sync records (one per activity synced this run)
  Future<void> saveSyncRecords(List<SyncRecord> records) async {
    final data = await _load();
    final history = (data['history'] as List).cast<Map<String, dynamic>>();

    for (final record in records) {
      // Update existing record when the same history identity already exists.
      final existingIdx = history.indexWhere(
        (r) => _historyMatches(SyncRecord.fromJson(r), record),
      );
      if (existingIdx >= 0) {
        final existingRecord = SyncRecord.fromJson(history[existingIdx]);
        history[existingIdx] = existingRecord.mergeWith(record).toJson();
      } else {
        history.insert(0, record.toJson());
      }
    }

    // Keep last 500 records
    if (history.length > 500) {
      data['history'] = history.sublist(0, 500);
    } else {
      data['history'] = history;
    }

    await _save(data);
  }

  /// Load all sync records, optionally filtered by date range.
  /// Records are deduplicated by fingerprint and merged.
  /// Sorted by activity startTime descending (newest activity first).
  Future<List<SyncRecord>> loadSyncRecords({
    DateTime? from,
    DateTime? to,
    int limit = 100,
  }) async {
    final data = await _load();
    final history = (data['history'] as List).cast<Map<String, dynamic>>();

    // Filter by sync date range (not activity date)
    final filtered = history.where((r) {
      final syncedAt = DateTime.tryParse(r['syncedAt'] ?? '');
      if (syncedAt == null) return false;
      if (from != null && syncedAt.isBefore(from)) return false;
      if (to != null && syncedAt.isAfter(to)) return false;
      return true;
    }).toList();

    // Parse and deduplicate by fingerprint: keep latest synced record for each,
    // then merge platform results across all records of the same fingerprint
    final Map<String, SyncRecord> merged = {};
    for (final r in filtered) {
      final record = SyncRecord.fromJson(r);
      final existingKey = merged.keys.cast<String?>().firstWhere(
        (key) => key != null && _historyMatches(merged[key]!, record),
        orElse: () => null,
      );
      if (existingKey != null) {
        merged[existingKey] = merged[existingKey]!.mergeWith(record);
      } else {
        merged[_historyIdentity(record)] = record;
      }
    }

    final result = merged.values.toList();

    // Sort by activity startTime descending (newest activity first)
    result.sort((a, b) {
      final ta = DateTime.tryParse(a.startTime) ?? DateTime(1970);
      final tb = DateTime.tryParse(b.startTime) ?? DateTime(1970);
      return tb.compareTo(ta);
    });

    return result.take(limit).toList();
  }

  /// Delete all sync records
  Future<void> clearHistory() async {
    final data = await _load();
    data['history'] = <Map<String, dynamic>>[];
    await _save(data);
  }

  // ---- sync result banners ----

  static const int _bannerKeepLimit = 7;

  /// 保存一次同步结果 banner（自动清理超出的旧记录）
  Future<void> saveSyncResultBanner(SyncResultBanner banner) async {
    final data = await _load();
    final banners =
        (data['banners'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    banners.insert(0, banner.toJson());

    // 超出上限时截断（保留最新的）
    if (banners.length > _bannerKeepLimit) {
      data['banners'] = banners.sublist(0, _bannerKeepLimit);
    } else {
      data['banners'] = banners;
    }
    await _save(data);
  }

  /// 加载最近 N 条同步结果 banner
  Future<List<SyncResultBanner>> loadSyncResultBanners({int? limit}) async {
    final data = await _load();
    final banners =
        (data['banners'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final result = banners.map((b) => SyncResultBanner.fromJson(b)).toList()
      ..sort((a, b) => b.syncedAt.compareTo(a.syncedAt)); // 最新的在前
    return limit != null ? result.take(limit).toList() : result;
  }

  /// 删除指定 id 的 banner
  Future<void> deleteSyncResultBanner(String bannerId) async {
    final data = await _load();
    final banners =
        (data['banners'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    banners.removeWhere((b) => b['id'] == bannerId);
    data['banners'] = banners;
    await _save(data);
  }

  /// 清空所有 banner
  Future<void> clearSyncResultBanners() async {
    final data = await _load();
    data['banners'] = <Map<String, dynamic>>[];
    await _save(data);
  }
}
