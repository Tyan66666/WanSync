import 'sync_summary.dart';

/// 单次同步运行的完整结果摘要（用于 HomeScreen 按钮下方列表展示）
class SyncResultBanner {
  final String id; // unique id for key/dismiss
  final DateTime syncedAt;

  // 整体概览
  final int fetched;
  final int deduped;
  final int pending; // fetched - deduped
  final int success;
  final int failed;

  // 取数诊断：区分「OneLap 没有记录」和「有记录但被过滤」
  final int serverReturned;
  final int outOfRange;
  final int invalidRecords;
  final String rangeStart;
  final String rangeEnd;

  // 取数诊断：OTM 预导入的状态（失败会让列表永远为空）
  final int otmImported;
  final String otmImportError;

  // 行者
  final int xingzheSuccess;
  final int xingzheFailed;
  final int xingzheDeduped;
  final List<FailedActivitySummary> xingzheFailures;

  // Strava
  final int stravaSuccess;
  final int stravaFailed;
  final int stravaDeduped;
  final List<FailedActivitySummary> stravaFailures;

  // Intervals.icu
  final int intervalsIcuSuccess;
  final int intervalsIcuFailed;
  final int intervalsIcuDeduped;
  final List<FailedActivitySummary> intervalsIcuFailures;

  // Outbase
  final int outbaseSuccess;
  final int outbaseFailed;
  final int outbaseDeduped;
  final List<FailedActivitySummary> outbaseFailures;

  const SyncResultBanner({
    required this.id,
    required this.syncedAt,
    required this.fetched,
    required this.deduped,
    required this.pending,
    required this.success,
    required this.failed,
    required this.xingzheSuccess,
    required this.xingzheFailed,
    required this.xingzheDeduped,
    required this.xingzheFailures,
    required this.stravaSuccess,
    required this.stravaFailed,
    required this.stravaDeduped,
    required this.stravaFailures,
    required this.intervalsIcuSuccess,
    required this.intervalsIcuFailed,
    required this.intervalsIcuDeduped,
    required this.intervalsIcuFailures,
    this.outbaseSuccess = 0,
    this.outbaseFailed = 0,
    this.outbaseDeduped = 0,
    this.outbaseFailures = const [],
    this.serverReturned = 0,
    this.outOfRange = 0,
    this.invalidRecords = 0,
    this.rangeStart = '',
    this.rangeEnd = '',
    this.otmImported = 0,
    this.otmImportError = '',
  });

  factory SyncResultBanner.fromSyncSummary(SyncSummary s) {
    final ts = DateTime.now();
    return SyncResultBanner(
      id: '${ts.millisecondsSinceEpoch}_${s.fetched}_${s.deduped}',
      syncedAt: s.syncedAt ?? DateTime.now(),
      fetched: s.fetched,
      deduped: s.deduped,
      pending: s.pending,
      success: s.success,
      failed: s.failed,
      serverReturned: s.serverReturned,
      outOfRange: s.outOfRange,
      invalidRecords: s.invalidRecords,
      rangeStart: s.rangeStart,
      rangeEnd: s.rangeEnd,
      otmImported: s.otmImported,
      otmImportError: s.otmImportError,
      xingzheSuccess: s.xingzheSuccess,
      xingzheFailed: s.xingzheFailed,
      xingzheDeduped: s.xingzheDeduped,
      xingzheFailures: s.xingzheFailures,
      stravaSuccess: s.stravaSuccess,
      stravaFailed: s.stravaFailed,
      stravaDeduped: s.stravaDeduped,
      stravaFailures: s.stravaFailures,
      intervalsIcuSuccess: s.intervalsIcuSuccess,
      intervalsIcuFailed: s.intervalsIcuFailed,
      intervalsIcuDeduped: s.intervalsIcuDeduped,
      intervalsIcuFailures: s.intervalsIcuFailures,
      outbaseSuccess: s.outbaseSuccess,
      outbaseFailed: s.outbaseFailed,
      outbaseDeduped: s.outbaseDeduped,
      outbaseFailures: s.outbaseFailures,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'syncedAt': syncedAt.toIso8601String(),
    'fetched': fetched,
    'deduped': deduped,
    'pending': pending,
    'success': success,
    'failed': failed,
    'serverReturned': serverReturned,
    'outOfRange': outOfRange,
    'invalidRecords': invalidRecords,
    'rangeStart': rangeStart,
    'rangeEnd': rangeEnd,
    'otmImported': otmImported,
    'otmImportError': otmImportError,
    'xingzheSuccess': xingzheSuccess,
    'xingzheFailed': xingzheFailed,
    'xingzheDeduped': xingzheDeduped,
    'xingzheFailures': xingzheFailures.map((f) => f.toJson()).toList(),
    'stravaSuccess': stravaSuccess,
    'stravaFailed': stravaFailed,
    'stravaDeduped': stravaDeduped,
    'stravaFailures': stravaFailures.map((f) => f.toJson()).toList(),
    'intervalsIcuSuccess': intervalsIcuSuccess,
    'intervalsIcuFailed': intervalsIcuFailed,
    'intervalsIcuDeduped': intervalsIcuDeduped,
    'intervalsIcuFailures': intervalsIcuFailures
        .map((f) => f.toJson())
        .toList(),
    'outbaseSuccess': outbaseSuccess,
    'outbaseFailed': outbaseFailed,
    'outbaseDeduped': outbaseDeduped,
    'outbaseFailures': outbaseFailures.map((f) => f.toJson()).toList(),
  };

  factory SyncResultBanner.fromJson(Map<String, dynamic> json) {
    return SyncResultBanner(
      id: json['id'] as String,
      syncedAt: DateTime.parse(json['syncedAt'] as String),
      fetched: json['fetched'] as int? ?? 0,
      deduped: json['deduped'] as int? ?? 0,
      pending: json['pending'] as int? ?? 0,
      success: json['success'] as int? ?? 0,
      failed: json['failed'] as int? ?? 0,
      serverReturned: json['serverReturned'] as int? ?? 0,
      outOfRange: json['outOfRange'] as int? ?? 0,
      invalidRecords: json['invalidRecords'] as int? ?? 0,
      rangeStart: json['rangeStart'] as String? ?? '',
      rangeEnd: json['rangeEnd'] as String? ?? '',
      otmImported: json['otmImported'] as int? ?? 0,
      otmImportError: json['otmImportError'] as String? ?? '',
      xingzheSuccess: json['xingzheSuccess'] as int? ?? 0,
      xingzheFailed: json['xingzheFailed'] as int? ?? 0,
      xingzheDeduped: json['xingzheDeduped'] as int? ?? 0,
      xingzheFailures:
          (json['xingzheFailures'] as List?)
              ?.map(
                (e) =>
                    FailedActivitySummary.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
      stravaSuccess: json['stravaSuccess'] as int? ?? 0,
      stravaFailed: json['stravaFailed'] as int? ?? 0,
      stravaDeduped: json['stravaDeduped'] as int? ?? 0,
      stravaFailures:
          (json['stravaFailures'] as List?)
              ?.map(
                (e) =>
                    FailedActivitySummary.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
      intervalsIcuSuccess: json['intervalsIcuSuccess'] as int? ?? 0,
      intervalsIcuFailed: json['intervalsIcuFailed'] as int? ?? 0,
      intervalsIcuDeduped: json['intervalsIcuDeduped'] as int? ?? 0,
      intervalsIcuFailures:
          (json['intervalsIcuFailures'] as List?)
              ?.map(
                (e) =>
                    FailedActivitySummary.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
      outbaseSuccess: json['outbaseSuccess'] as int? ?? 0,
      outbaseFailed: json['outbaseFailed'] as int? ?? 0,
      outbaseDeduped: json['outbaseDeduped'] as int? ?? 0,
      outbaseFailures:
          (json['outbaseFailures'] as List?)
              ?.map(
                (e) =>
                    FailedActivitySummary.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
    );
  }

  /// 概览行文案
  String get summaryLine {
    if (fetched == 0 && serverReturned > 0) {
      return '共获取$serverReturned条，均未进入同步';
    }
    final StringBuffer buffer = StringBuffer(
      '共获取$fetched条，$deduped条已跳过，$pending条需同步',
    );
    if (outOfRange > 0) buffer.write('，$outOfRange条早于范围');
    if (invalidRecords > 0) buffer.write('，$invalidRecords条时间无效');
    final String? note = otmImportNote;
    if (note != null) buffer.write('，$note');
    return buffer.toString();
  }

  /// OTM 预导入的补充说明（与 [SyncSummary.otmImportNote] 同一口径：
  /// 失败优先，失败时不再报计数）。
  String? get otmImportNote {
    if (otmImportError.isNotEmpty) return 'OTM 导入失败：$otmImportError';
    if (otmImported > 0) return 'OTM 导入$otmImported条';
    return null;
  }

  /// 简要时间标签（用于列表显示）
  String get timeLabel {
    final now = DateTime.now();
    final diff = now.difference(syncedAt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    return '${syncedAt.month}-${syncedAt.day} ${syncedAt.hour.toString().padLeft(2, '0')}:${syncedAt.minute.toString().padLeft(2, '0')}';
  }

  /// SyncSummary 重建（兼容现有 _showSyncResult dialog）
  SyncSummary toSyncSummary() => SyncSummary(
    fetched: fetched,
    deduped: deduped,
    success: success,
    failed: failed,
    serverReturned: serverReturned,
    outOfRange: outOfRange,
    invalidRecords: invalidRecords,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    otmImported: otmImported,
    otmImportError: otmImportError,
    failureReasons: [
      ...xingzheFailures.map((f) => '行者失败: ${f.displayText} ${f.error ?? ''}'),
      ...stravaFailures.map(
        (f) => 'Strava失败: ${f.displayText} ${f.error ?? ''}',
      ),
      ...intervalsIcuFailures.map(
        (f) => 'Intervals.icu失败: ${f.displayText} ${f.error ?? ''}',
      ),
      ...outbaseFailures.map(
        (f) => 'Outbase失败: ${f.displayText} ${f.error ?? ''}',
      ),
    ],
    xingzheSuccess: xingzheSuccess,
    xingzheFailed: xingzheFailed,
    xingzheDeduped: xingzheDeduped,
    xingzheFailures: xingzheFailures,
    stravaSuccess: stravaSuccess,
    stravaFailed: stravaFailed,
    stravaDeduped: stravaDeduped,
    stravaFailures: stravaFailures,
    intervalsIcuSuccess: intervalsIcuSuccess,
    intervalsIcuFailed: intervalsIcuFailed,
    intervalsIcuDeduped: intervalsIcuDeduped,
    intervalsIcuFailures: intervalsIcuFailures,
    outbaseSuccess: outbaseSuccess,
    outbaseFailed: outbaseFailed,
    outbaseDeduped: outbaseDeduped,
    outbaseFailures: outbaseFailures,
  );
}
