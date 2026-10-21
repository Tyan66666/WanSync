import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/services/dedupe_service.dart';

void main() {
  group('buildDedupeKey', () {
    test(
      'matches OneLap Beijing local time with FIT UTC time for the same ride',
      () {
        final String oneLapKey = buildDedupeKey(
          startTime: '2026-10-18T20:33:08',
          distanceM: 42195.4,
        );
        final String fitKey = buildDedupeKey(
          startTime: '2026-10-18T12:33:08Z',
          distanceM: 42195.4,
        );

        expect(oneLapKey, fitKey);
        expect(oneLapKey, '2026-10-18T12:33:08Z_42195');
      },
    );

    test('accepts explicit UTC offsets', () {
      expect(
        buildDedupeKey(startTime: '2026-10-18T20:33:08+08:00', distanceM: 1000),
        buildDedupeKey(startTime: '2026-10-18T12:33:08Z', distanceM: 1000),
      );
    });

    test('rounds distance meters and falls back to na', () {
      expect(
        buildDedupeKey(startTime: '2026-10-18T12:33:08Z', distanceM: 42195.4),
        endsWith('_42195'),
      );
      expect(
        buildDedupeKey(startTime: '2026-10-18T12:33:08Z', distanceM: null),
        endsWith('_na'),
      );
    });

    test('keeps unparseable start times verbatim', () {
      expect(
        buildDedupeKey(startTime: ' unknown ', distanceM: null),
        'unknown_na',
      );
    });
  });
}
