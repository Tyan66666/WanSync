/// 单个失败活动的简要摘要（用于列表展示）
class FailedActivitySummary {
  final String fingerprint;
  final String date; // displayDate: 2026-04-22
  final String distance; // displayDistance: 32.5km
  final String ascent; // displayAscent: 186m
  final String? error; // 简短错误描述

  const FailedActivitySummary({
    required this.fingerprint,
    required this.date,
    required this.distance,
    required this.ascent,
    this.error,
  });

  /// 列表展示文本：时间-距离-爬升
  String get displayText {
    final parts = <String>[date, distance];
    if (ascent != '--') parts.add(ascent);
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'date': date,
    'distance': distance,
    'ascent': ascent,
    'error': error,
  };

  factory FailedActivitySummary.fromJson(Map<String, dynamic> json) {
    return FailedActivitySummary(
      fingerprint: json['fingerprint'] as String? ?? '',
      date: json['date'] as String? ?? '',
      distance: json['distance'] as String? ?? '--',
      ascent: json['ascent'] as String? ?? '--',
      error: json['error'] as String?,
    );
  }
}

class SyncSummary {
  final int fetched;
  final int deduped; // 本地判重跳过的（不计入成功/失败）
  final int success; // 本次实际同步成功（不含 deduped 跳过）
  final int failed; // 本次实际失败（不含 deduped 跳过）
  final String? abortedReason;
  final List<String> failureReasons;

  // === 按平台统计 ===
  final int xingzheSuccess;
  final int xingzheFailed;
  final int xingzheDeduped;
  final List<FailedActivitySummary> xingzheFailures;
  final int stravaSuccess;
  final int stravaFailed;
  final int stravaDeduped;
  final List<FailedActivitySummary> stravaFailures;

  final int intervalsIcuSuccess;
  final int intervalsIcuFailed;
  final int intervalsIcuDeduped;
  final List<FailedActivitySummary> intervalsIcuFailures;

  final int outbaseSuccess;
  final int outbaseFailed;
  final int outbaseDeduped;
  final List<FailedActivitySummary> outbaseFailures;

  /// 服务端实际返回的原始条数（跨页累计）。
  ///
  /// 用于区分「OneLap 确实没有记录」和「有记录但都被本地过滤掉了」——
  /// 这两种情况以前共用同一句提示，用户无法分辨。
  final int serverReturned;

  /// 早于查询起始日被跳过的条数。
  final int outOfRange;

  /// 缺少 id 或无法解析起始时间被跳过的条数。
  final int invalidRecords;

  /// 本次查询的日期范围（`yyyy-MM-dd`）。
  final String rangeStart;
  final String rangeEnd;

  /// 本次同步运行时间戳（用于 banner 记录）
  final DateTime? syncedAt;

  const SyncSummary({
    required this.fetched,
    required this.deduped,
    required this.success,
    required this.failed,
    this.abortedReason,
    this.failureReasons = const [],
    this.serverReturned = 0,
    this.outOfRange = 0,
    this.invalidRecords = 0,
    this.rangeStart = '',
    this.rangeEnd = '',
    this.xingzheSuccess = 0,
    this.xingzheFailed = 0,
    this.xingzheDeduped = 0,
    this.xingzheFailures = const [],
    this.stravaSuccess = 0,
    this.stravaFailed = 0,
    this.stravaDeduped = 0,
    this.stravaFailures = const [],
    this.intervalsIcuSuccess = 0,
    this.intervalsIcuFailed = 0,
    this.intervalsIcuDeduped = 0,
    this.intervalsIcuFailures = const [],
    this.outbaseSuccess = 0,
    this.outbaseFailed = 0,
    this.outbaseDeduped = 0,
    this.outbaseFailures = const [],
    this.syncedAt,
  });

  /// 本次需同步的记录数（去除已去重的）
  int get pending => fetched - deduped;

  /// 本次实际处理的记录数（成功+失败，不含 deduped 跳过）
  int get newCount => success + failed;

  /// 服务端有数据、但没能进入同步的条数（范围外 + 无效时间）。
  int get filteredOut => outOfRange + invalidRecords;

  /// 生成用于 HomeScreen banner 显示的汇总文案
  String get bannerTitle {
    if (abortedReason == 'risk-control') return '同步中止（风控）';
    if (fetched > 0) {
      return '已同步$success条${failed > 0 ? '，失败$failed条' : ''}';
    }
    if (serverReturned > 0) {
      return '服务端返回$serverReturned条，均未进入同步';
    }
    return '本次未获取到记录';
  }
}
