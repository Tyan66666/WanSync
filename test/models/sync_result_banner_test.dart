import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/models/sync_result_banner.dart';
import 'package:onelap_strava_sync/models/sync_summary.dart';

void main() {
  group('SyncResultBanner', () {
    test('preserves per-platform deduped counts from summary', () {
      final SyncSummary summary = SyncSummary(
        fetched: 1,
        deduped: 0,
        success: 0,
        failed: 1,
        stravaSuccess: 0,
        stravaFailed: 0,
        stravaDeduped: 1,
        xingzheSuccess: 0,
        xingzheFailed: 1,
        xingzheDeduped: 0,
      );

      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(summary);
      final SyncResultBanner restored = SyncResultBanner.fromJson(
        banner.toJson(),
      );

      expect(restored.stravaDeduped, 1);
      expect(restored.xingzheDeduped, 0);
      expect(restored.stravaFailed, 0);
      expect(restored.xingzheFailed, 1);
    });

    test('keeps a platform visible when it only has deduped results', () {
      final SyncSummary summary = SyncSummary(
        fetched: 1,
        deduped: 0,
        success: 0,
        failed: 1,
        stravaDeduped: 1,
        xingzheFailed: 1,
      );

      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(summary);

      expect(
        banner.stravaSuccess > 0 ||
            banner.stravaFailed > 0 ||
            banner.stravaDeduped > 0,
        isTrue,
      );
    });

    test('intervalsIcu fields survive round-trip', () {
      final SyncSummary summary = SyncSummary(
        fetched: 2,
        deduped: 0,
        success: 1,
        failed: 1,
        stravaSuccess: 1,
        stravaFailed: 0,
        stravaDeduped: 0,
        stravaFailures: [],
        xingzheSuccess: 0,
        xingzheFailed: 1,
        xingzheDeduped: 0,
        xingzheFailures: [
          FailedActivitySummary(
            fingerprint: 'fp-1',
            date: '2026-04-20',
            distance: '10.0km',
            ascent: '100m',
            error: 'timeout',
          ),
        ],
        intervalsIcuSuccess: 2,
        intervalsIcuFailed: 0,
        intervalsIcuDeduped: 1,
        intervalsIcuFailures: [
          FailedActivitySummary(
            fingerprint: 'fp-2',
            date: '2026-04-21',
            distance: '20.0km',
            ascent: '200m',
          ),
        ],
      );

      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(summary);
      final SyncResultBanner restored = SyncResultBanner.fromJson(
        banner.toJson(),
      );

      expect(restored.intervalsIcuSuccess, 2);
      expect(restored.intervalsIcuFailed, 0);
      expect(restored.intervalsIcuDeduped, 1);
      expect(restored.intervalsIcuFailures, hasLength(1));
      expect(restored.intervalsIcuFailures.first.fingerprint, 'fp-2');
      expect(restored.intervalsIcuFailures.first.distance, '20.0km');
    });

    test('toSyncSummary preserves intervalsIcu fields', () {
      final SyncSummary original = SyncSummary(
        fetched: 3,
        deduped: 1,
        success: 1,
        failed: 1,
        intervalsIcuSuccess: 1,
        intervalsIcuFailed: 1,
        intervalsIcuDeduped: 0,
        intervalsIcuFailures: [
          FailedActivitySummary(
            fingerprint: 'fp-3',
            date: '2026-04-22',
            distance: '30.0km',
            ascent: '300m',
            error: 'API Key 无效',
          ),
        ],
      );

      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(
        original,
      );
      final SyncSummary restored = banner.toSyncSummary();

      expect(restored.intervalsIcuSuccess, 1);
      expect(restored.intervalsIcuFailed, 1);
      expect(restored.intervalsIcuDeduped, 0);
      expect(restored.intervalsIcuFailures, hasLength(1));
      expect(restored.intervalsIcuFailures.first.error, 'API Key 无效');
    });

    test('OTM import diagnostics survive round-trip', () {
      final SyncSummary summary = SyncSummary(
        fetched: 2,
        deduped: 0,
        success: 2,
        failed: 0,
        otmImported: 2,
        otmImportError: '',
      );

      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(summary);
      final SyncResultBanner restored = SyncResultBanner.fromJson(
        banner.toJson(),
      );

      expect(restored.otmImported, 2);
      expect(restored.otmImportError, '');
      expect(banner.toSyncSummary().otmImported, 2);
      expect(banner.toSyncSummary().otmImportError, '');
    });

    test('failure reason survives toSyncSummary', () {
      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(
        const SyncSummary(
          fetched: 0,
          deduped: 0,
          success: 0,
          failed: 0,
          otmImportError: 'HTTP 500',
        ),
      );

      expect(banner.toSyncSummary().otmImportError, 'HTTP 500');
    });

    test('a failed round hides the partial import count', () {
      // 多轮导入可能「先导入若干条、下一轮失败」，两个结论不能同屏。
      const SyncSummary summary = SyncSummary(
        fetched: 0,
        deduped: 0,
        success: 0,
        failed: 0,
        otmImported: 20,
        otmImportError: 'HTTP 500',
      );
      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(summary);

      expect(banner.summaryLine, contains('OTM 导入失败：HTTP 500'));
      expect(banner.summaryLine, isNot(contains('OTM 导入20条')));
      expect(summary.otmImportNote, 'OTM 导入失败：HTTP 500');
      expect(summary.emptyResultTitle, '本次未获取到记录（OTM 导入失败：HTTP 500）');
    });

    test('old persisted JSON without OTM import fields still parses', () {
      // 旧版本 state.json 里没有这个诊断字段，不能因此解析失败或数值錯位。
      final SyncResultBanner restored =
          SyncResultBanner.fromJson(<String, dynamic>{
            'id': 'legacy-1',
            'syncedAt': '2026-10-20T08:00:00.000',
            'fetched': 0,
            'deduped': 0,
            'pending': 0,
            'success': 0,
            'failed': 0,
            'serverReturned': 0,
            'outOfRange': 0,
            'invalidRecords': 0,
            'rangeStart': '2026-10-20',
            'rangeEnd': '2026-10-23',
          });

      expect(restored.otmImported, 0);
      expect(restored.otmImportError, '');
      expect(restored.summaryLine, isNot(contains('OTM')));
    });

    test('summaryLine shows how many records OTM imported', () {
      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(
        const SyncSummary(
          fetched: 2,
          deduped: 0,
          success: 2,
          failed: 0,
          otmImported: 2,
        ),
      );

      expect(banner.summaryLine, contains('OTM 导入2条'));
    });

    test('summaryLine and otmImportNote expose OTM import failure', () {
      final SyncSummary summary = const SyncSummary(
        fetched: 0,
        deduped: 0,
        success: 0,
        failed: 0,
        otmImportError: 'HTTP 500',
      );

      expect(summary.otmImportNote, 'OTM 导入失败：HTTP 500');
      expect(summary.emptyResultTitle, '本次未获取到记录（OTM 导入失败：HTTP 500）');

      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(summary);
      expect(banner.summaryLine, contains('OTM 导入失败：HTTP 500'));
    });

    test(
      'emptyResultTitle carries the note only when the server sent nothing',
      () {
        const SyncSummary imported = SyncSummary(
          fetched: 0,
          deduped: 0,
          success: 0,
          failed: 0,
          otmImported: 3,
        );

        expect(imported.otmImportNote, 'OTM 导入3条');
        expect(imported.emptyResultTitle, '本次未获取到记录（OTM 导入3条）');

        // 服务端返回过记录（全被过滤）：空列表不是导入造成的，不能归因于导入。
        const SyncSummary filtered = SyncSummary(
          fetched: 0,
          deduped: 0,
          success: 0,
          failed: 0,
          serverReturned: 3,
          outOfRange: 3,
          otmImportError: 'HTTP 500',
        );

        expect(filtered.emptyResultTitle, 'OneLap 暂无该时段的记录');
      },
    );

    test('banner and summary never disagree about the import note', () {
      const List<SyncSummary> cases = <SyncSummary>[
        SyncSummary(
          fetched: 0,
          deduped: 0,
          success: 0,
          failed: 0,
          otmImportError: 'HTTP 500',
        ),
        SyncSummary(
          fetched: 0,
          deduped: 0,
          success: 0,
          failed: 0,
          otmImported: 20,
        ),
        SyncSummary(fetched: 0, deduped: 0, success: 0, failed: 0),
      ];

      for (final SyncSummary summary in cases) {
        final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(
          summary,
        );
        expect(banner.otmImportNote, summary.otmImportNote);
      }
    });

    test('the all-filtered summary line keeps the import note', () {
      final SyncSummary summary = const SyncSummary(
        fetched: 0,
        deduped: 0,
        success: 0,
        failed: 0,
        serverReturned: 3,
        outOfRange: 3,
        otmImportError: 'HTTP 500',
      );

      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(summary);

      expect(banner.summaryLine, contains('共获取3条'));
      expect(banner.summaryLine, contains('OTM 导入失败：HTTP 500'));
    });
  });
}
