import '../models/sync_summary.dart';

class SyncFailureFormatter {
  /// 失败原因形如：
  /// - `下载失败 (demo.fit): HTTP 404`
  /// - `Strava 上传失败 (demo.fit): StravaPermanentError: HTTP 403`
  /// - `行者 上传失败 (demo.fit): XingzhePermanentError: ...`
  ///
  /// 平台前缀可选（`sync_engine` 的平台上传失败会带 `Strava`/`行者` 等前缀）。
  static final RegExp _failurePattern = RegExp(
    r'^(([^\s(]+)\s+)?(下载失败|上传失败|坐标转换失败) \((.+?)\):\s*(.*)$',
  );
  static const String _downloadFitShareHint =
      '可以试试先从 OneLap/顽鹿导出 FIT，再分享到顽爪爪进行同步。';

  static String toUserMessage(String raw) {
    final Match? match = _failurePattern.firstMatch(raw.trim());
    if (match == null) return '同步失败：请稍后重试。';

    final String platform = (match.group(2) ?? '').trim();
    final String kind = match.group(3)!;
    final String filename = match.group(4)!;
    final String detail = (match.group(5) ?? '').toLowerCase();
    final String label = platform.isEmpty ? '' : '$platform ';

    if (kind == '下载失败') {
      if (detail.contains('http 404')) {
        return '下载失败（$filename）：OneLap 源文件可能已过期或已删除，请在顽鹿 App 内确认该活动是否仍可导出。$_downloadFitShareHint';
      }
      if (detail.contains('timeout') || detail.contains('timed out')) {
        return '下载失败（$filename）：OneLap 下载超时，请检查网络后重试。$_downloadFitShareHint';
      }
      return '下载失败（$filename）：OneLap 文件下载失败，请稍后重试。$_downloadFitShareHint';
    }

    if (kind == '坐标转换失败') {
      return '坐标转换失败（$filename）：FIT 文件在上传前转换失败，请稍后重试。';
    }

    return '$label上传失败（$filename）：${_uploadFailureHint(platform: platform, detail: detail)}';
  }

  /// 按平台给出上传失败的可用提示。
  static String _uploadFailureHint({
    required String platform,
    required String detail,
  }) {
    final bool isServerError =
        detail.contains('5xx') ||
        detail.contains('http 5') ||
        detail.contains('503');
    final bool isAuthError =
        detail.contains('401') ||
        detail.contains('403') ||
        detail.contains('session expired') ||
        detail.contains('登录') ||
        detail.contains('会话') ||
        detail.contains('未认证') ||
        detail.contains('authentication credentials');

    if (platform.contains('行者')) {
      if (isAuthError) {
        return '行者登录已失效，自动重新登录没能恢复，请在“设置 → 行者”中重新登录后重试。';
      }
      if (isServerError) return '行者服务暂时不可用，请稍后重试。';
      return '行者上传失败，请稍后重试。';
    }

    if (platform.contains('Intervals')) {
      if (isAuthError) {
        return 'Intervals.icu 的 API Key 可能已失效，请在设置中更新后重试。';
      }
      if (isServerError) return 'Intervals.icu 服务暂时不可用，请稍后重试。';
      return 'Intervals.icu 上传失败，请稍后重试。';
    }

    if (platform.contains('Outbase')) {
      if (isAuthError) {
        return 'Outbase 登录已失效，请在“设置 → Outbase”中重新登录后重试。';
      }
      if (isServerError) return 'Outbase 服务暂时不可用，请稍后重试。';
      return 'Outbase 上传失败，请稍后重试。';
    }

    if (isServerError) {
      return 'Strava 服务暂时不可用，请稍后重试。';
    }
    if (isAuthError) {
      return 'Strava 授权可能已失效，请在设置中重新授权后重试。';
    }
    return 'Strava 上传失败，请稍后重试。';
  }

  static String buildClipboardText(SyncSummary summary) {
    return buildClipboardTextWithMeta(summary: summary);
  }

  static String buildClipboardTextWithMeta({
    required SyncSummary summary,
    String? appVersion,
    DateTime? generatedAt,
  }) {
    final DateTime timestamp = generatedAt ?? DateTime.now().toUtc();
    final List<String> lines = <String>[
      'WanSync 同步失败详细信息',
      if (appVersion != null && appVersion.trim().isNotEmpty)
        'app_version=${appVersion.trim()}',
      'generated_at_utc=${timestamp.toIso8601String()}',
      'fetched=${summary.fetched}, deduped=${summary.deduped}, success=${summary.success}, failed=${summary.failed}',
      'failure_reasons:',
    ];

    for (var i = 0; i < summary.failureReasons.length; i++) {
      lines.add('${i + 1}. ${summary.failureReasons[i]}');
    }
    return lines.join('\n');
  }
}
