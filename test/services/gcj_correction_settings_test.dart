import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/models/sync_record.dart';
import 'package:onelap_strava_sync/services/gcj_correction_settings.dart';
import 'package:onelap_strava_sync/services/settings_service.dart';

Map<String, String> _settings({String legacy = '', Map<String, String>? per}) {
  return <String, String>{
    SettingsService.keyGcjCorrectionEnabled: legacy,
    if (per != null) ...per,
  };
}

void main() {
  group('GcjCorrectionSettings.fromSettings', () {
    test('reads each per-platform switch independently', () {
      final GcjCorrectionSettings settings = GcjCorrectionSettings.fromSettings(
        _settings(
          per: <String, String>{
            SettingsService.keyGcjCorrectionStrava: 'true',
            SettingsService.keyGcjCorrectionXingzhe: 'false',
            SettingsService.keyGcjCorrectionIntervalsIcu: 'true',
            SettingsService.keyGcjCorrectionOutbase: 'false',
          },
        ),
      );

      expect(settings.strava, isTrue);
      expect(settings.xingzhe, isFalse);
      expect(settings.intervalsIcu, isTrue);
      expect(settings.outbase, isFalse);
      expect(settings.anyEnabled, isTrue);
    });

    test('per-platform switches take precedence over the legacy flag', () {
      final GcjCorrectionSettings settings = GcjCorrectionSettings.fromSettings(
        _settings(
          legacy: 'true',
          per: <String, String>{
            SettingsService.keyGcjCorrectionStrava: 'false',
            SettingsService.keyGcjCorrectionXingzhe: 'true',
          },
        ),
      );

      expect(settings.strava, isFalse);
      expect(settings.xingzhe, isTrue);
      expect(settings.intervalsIcu, isFalse);
      expect(settings.outbase, isFalse);
    });

    test('missing Strava key still falls back to the legacy flag while other '
        'per-platform keys win', () {
      final GcjCorrectionSettings settings = GcjCorrectionSettings.fromSettings(
        _settings(
          legacy: 'true',
          per: <String, String>{
            SettingsService.keyGcjCorrectionXingzhe: 'false',
          },
        ),
      );

      expect(settings.strava, isTrue);
      expect(settings.xingzhe, isFalse);
      expect(settings.intervalsIcu, isFalse);
      expect(settings.outbase, isFalse);
    });

    test('falls back to the legacy flag as Strava-only correction', () {
      final GcjCorrectionSettings settings = GcjCorrectionSettings.fromSettings(
        _settings(legacy: 'true'),
      );

      expect(settings.strava, isTrue);
      expect(settings.xingzhe, isFalse);
      expect(settings.intervalsIcu, isFalse);
      expect(settings.outbase, isFalse);
    });

    test('treats empty values as disabled', () {
      final GcjCorrectionSettings settings = GcjCorrectionSettings.fromSettings(
        <String, String>{},
      );

      expect(settings.anyEnabled, isFalse);
      for (final SyncPlatform platform in SyncPlatform.values) {
        expect(settings.forSyncPlatform(platform), isFalse);
      }
    });
  });

  group('GcjCorrectionSettings.forSyncPlatform', () {
    test('maps each platform to its own switch', () {
      const GcjCorrectionSettings settings = GcjCorrectionSettings(
        strava: true,
        xingzhe: false,
        intervalsIcu: true,
        outbase: false,
      );

      expect(settings.forSyncPlatform(SyncPlatform.strava), isTrue);
      expect(settings.forSyncPlatform(SyncPlatform.xingzhe), isFalse);
      expect(settings.forSyncPlatform(SyncPlatform.intervalsIcu), isTrue);
      expect(settings.forSyncPlatform(SyncPlatform.outbase), isFalse);
    });
  });

  group('GcjCorrectionSettings.toSettingsMap', () {
    test('round-trips through fromSettings', () {
      const GcjCorrectionSettings original = GcjCorrectionSettings(
        strava: true,
        xingzhe: true,
        intervalsIcu: false,
        outbase: true,
      );

      final Map<String, String> stored = original.toSettingsMap();
      expect(stored[SettingsService.keyGcjCorrectionStrava], 'true');
      expect(stored[SettingsService.keyGcjCorrectionXingzhe], 'true');
      expect(stored[SettingsService.keyGcjCorrectionIntervalsIcu], 'false');
      expect(stored[SettingsService.keyGcjCorrectionOutbase], 'true');

      final GcjCorrectionSettings restored = GcjCorrectionSettings.fromSettings(
        stored,
      );
      expect(restored.strava, isTrue);
      expect(restored.xingzhe, isTrue);
      expect(restored.intervalsIcu, isFalse);
      expect(restored.outbase, isTrue);
    });
  });
}
