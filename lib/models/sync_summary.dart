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

  /// 本次同步前 OTM 实际导入的记录数。
  ///
  /// 用于区分「OTM 确实没新记录」和「导入没跑成」：后者会让列表永远为空。
  final int otmImported;

  /// OTM 导入失败原因（成功时为空串）。
  final String otmImportError;

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
    this.otmImported = 0,
    this.otmImportError = '',
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

  /// OTM 预导入的补充说明；失败优先（失败时只报失败、不报计数：多轮导入可能
  /// 「先导入若干条、下一轮失败」，两个结论同屏会自相矛盾）。
  ///
  /// 单实现：[SyncResultBanner] 也走这里，避免两份复制实现将来漂移。
  static String? otmImportNoteOf({
    required int imported,
    required String error,
  }) {
    if (error.isNotEmpty) return 'OTM 导入失败：$error';
    if (imported > 0) return 'OTM 已导入$imported条';
    return null;
  }

  String? get otmImportNote =>
      otmImportNoteOf(imported: otmImported, error: otmImportError);

  /// 一条记录都没取到时弹窗的标题。
  ///
  /// 只有服务端真的返回 0 条时，空列表才可能是导入失败造成的；
  /// 若服务端返回过记录（全被范围/解析过滤），归因于导入就是错的。
  String get emptyResultTitle {
    final String? note = otmImportNote;
    if (serverReturned == 0 && note != null) {
      return '本次未获取到记录（$note）';
    }
    return 'OneLap 暂无该时段的记录';
  }

  /// 空结果弹窗的说明文案：标题放结论，这里放细节和下一步动作。
  ///
  /// 与 [emptyResultTitle] 分工 — 标题在 `serverReturned == 0` 时已带
  /// [otmImportNote]，所以这里只在服务端确实返回过记录时才写 note，
  /// 否则同一句话会在一个弹窗里出现两次。
  String get emptyResultHint {
    final String range = rangeStart.isEmpty
        ? ''
        : '（查询范围 $rangeStart ~ $rangeEnd）';
    final List<String> lines = <String>['服务端返回 $serverReturned 条$range。'];
    if (serverReturned == 0) {
      if (otmImportError.isNotEmpty) {
        // 标题已点明失败，这里只给下一步，不重复错误串。
        lines.add('OTM 预导入没成功，请检查网络后重新同步；也可以先在浏览器打开一次 OTM 日历页唤醒导入。');
      } else {
        lines.add('骑行结束后码表/手机回传 OneLap 有延迟，稍后重新同步即可。');
      }
    } else {
      // 服务端返回过记录 ⇒ 标题保持中性，导入状态必须由这里承载。
      final String? note = otmImportNote;
      if (note != null) lines.add('$note。');
    }
    return lines.join('\n');
  }
}
