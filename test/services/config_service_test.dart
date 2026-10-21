import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/services/config_service.dart';
import 'package:onelap_strava_sync/services/settings_service.dart';

class _FakeSettingsStore implements SettingsStore {
  final Map<String, String> _values = {};

  @override
  Future<Map<String, String>> readAll() async => Map.from(_values);

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }
}

void main() {
  group('ConfigService', () {
    late _FakeSettingsStore store;
    late SettingsService settingsService;
    late ConfigService configService;

    setUp(() {
      store = _FakeSettingsStore();
      settingsService = SettingsService(store: store);
      configService = ConfigService(settingsService: settingsService);
    });

    test('exportConfig includes all settings keys', () async {
      await settingsService.saveSettings({
        SettingsService.keyOneLapUsername: 'user',
        SettingsService.keyOneLapPassword: 'pass',
        SettingsService.keyStravaClientId: '123',
        SettingsService.keyLookbackDays: '5',
      });

      final jsonStr = await configService.exportConfig(appVersion: '1.0.21');
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(json['version'], 1);
      expect(json['appVersion'], '1.0.21');
      expect(json['exportedAt'], isNotEmpty);

      final settings = json['settings'] as Map<String, dynamic>;
      final onelap = settings['onelap'] as Map<String, dynamic>;
      expect(onelap['username'], 'user');
      expect(onelap['password'], 'pass');

      final strava = settings['strava'] as Map<String, dynamic>;
      expect(strava['clientId'], '123');

      final sync = settings['sync'] as Map<String, dynamic>;
      expect(sync['lookbackDays'], 5);
    });

    test('exportConfig maps storage keys to structured JSON', () async {
      await settingsService.saveSettings({
        SettingsService.keyLookbackDays: '7',
        SettingsService.keyGcjCorrectionEnabled: 'true',
        SettingsService.keyUploadToStrava: 'true',
        SettingsService.keyUploadToXingzhe: 'false',
      });

      final jsonStr = await configService.exportConfig(appVersion: '1.0.0');
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final sync =
          (json['settings'] as Map<String, dynamic>)['sync']
              as Map<String, dynamic>;

      expect(sync['lookbackDays'], 7);
      expect(sync['gcjCorrectionEnabled'], true);
      expect(sync['uploadToStrava'], true);
      expect(sync['uploadToXingzhe'], false);
    });

    test('importConfig writes all settings to store', () async {
      final configJson = jsonEncode({
        'version': 1,
        'appVersion': '1.0.0',
        'exportedAt': '2026-01-01T00:00:00.000Z',
        'settings': {
          'onelap': {'username': 'imported_user', 'password': 'imported_pass'},
          'strava': {
            'uploadMode': 'web',
            'clientId': '456',
            'clientSecret': 'sec',
            'refreshToken': 'rt',
            'accessToken': 'at',
            'expiresAt': '123',
            'webCookies': 'cookies',
          },
          'xingzhe': {
            'username': 'xz_user',
            'password': 'xz_pass',
            'sessionId': 'sid',
          },
          'intervalsIcu': {'athleteId': 'a1', 'apiKey': 'k1'},
          'sync': {
            'lookbackDays': 10,
            'gcjCorrectionEnabled': true,
            'uploadToStrava': true,
            'uploadToXingzhe': true,
            'uploadToIntervalsIcu': true,
          },
        },
      });

      await configService.importConfig(configJson);

      final settings = await settingsService.loadSettings();
      expect(settings[SettingsService.keyOneLapUsername], 'imported_user');
      expect(settings[SettingsService.keyOneLapPassword], 'imported_pass');
      expect(settings[SettingsService.keyStravaClientId], '456');
      expect(settings[SettingsService.keyStravaUploadMode], 'web');
      expect(settings[SettingsService.keyLookbackDays], '10');
      expect(settings[SettingsService.keyGcjCorrectionEnabled], 'true');
      expect(settings[SettingsService.keyGcjCorrectionStrava], 'true');
      expect(settings[SettingsService.keyGcjCorrectionXingzhe], 'false');
      expect(settings[SettingsService.keyGcjCorrectionIntervalsIcu], 'false');
      expect(settings[SettingsService.keyGcjCorrectionOutbase], 'false');
      expect(settings[SettingsService.keyUploadToXingzhe], 'true');
    });

    test('exportConfig writes per-platform GCJ correction switches', () async {
      await settingsService.saveSettings({
        SettingsService.keyGcjCorrectionStrava: 'true',
        SettingsService.keyGcjCorrectionXingzhe: 'false',
        SettingsService.keyGcjCorrectionIntervalsIcu: 'true',
        SettingsService.keyGcjCorrectionOutbase: 'true',
      });

      final jsonStr = await configService.exportConfig(appVersion: '1.0.0');
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final sync =
          (json['settings'] as Map<String, dynamic>)['sync']
              as Map<String, dynamic>;
      final gcj = sync['gcjCorrection'] as Map<String, dynamic>;

      expect(gcj['strava'], isTrue);
      expect(gcj['xingzhe'], isFalse);
      expect(gcj['intervalsIcu'], isTrue);
      expect(gcj['outbase'], isTrue);
      // Legacy flag mirrors Strava for older clients.
      expect(sync['gcjCorrectionEnabled'], isTrue);
    });

    test(
      'importConfig merges a partial GCJ map with the legacy Strava flag',
      () async {
        final configJson = jsonEncode({
          'version': 1,
          'appVersion': '1.0.0',
          'exportedAt': '2026-01-01T00:00:00.000Z',
          'settings': {
            'sync': {
              'gcjCorrectionEnabled': true,
              'gcjCorrection': {'xingzhe': true},
            },
          },
        });

        await configService.importConfig(configJson);

        final settings = await settingsService.loadSettings();
        expect(settings[SettingsService.keyGcjCorrectionStrava], 'true');
        expect(settings[SettingsService.keyGcjCorrectionXingzhe], 'true');
        expect(settings[SettingsService.keyGcjCorrectionIntervalsIcu], 'false');
        expect(settings[SettingsService.keyGcjCorrectionOutbase], 'false');
      },
    );

    test(
      'importConfig restores per-platform GCJ correction switches',
      () async {
        final configJson = jsonEncode({
          'version': 1,
          'appVersion': '1.0.0',
          'exportedAt': '2026-01-01T00:00:00.000Z',
          'settings': {
            'sync': {
              'gcjCorrectionEnabled': false,
              'gcjCorrection': {
                'strava': false,
                'xingzhe': true,
                'intervalsIcu': false,
                'outbase': true,
              },
            },
          },
        });

        await configService.importConfig(configJson);

        final settings = await settingsService.loadSettings();
        expect(settings[SettingsService.keyGcjCorrectionStrava], 'false');
        expect(settings[SettingsService.keyGcjCorrectionXingzhe], 'true');
        expect(settings[SettingsService.keyGcjCorrectionIntervalsIcu], 'false');
        expect(settings[SettingsService.keyGcjCorrectionOutbase], 'true');
        expect(settings[SettingsService.keyGcjCorrectionEnabled], 'false');
      },
    );

    test('importConfig throws on invalid JSON', () {
      expect(
        () => configService.importConfig('not json'),
        throwsFormatException,
      );
    });

    test('importConfig throws on missing version', () {
      final json = jsonEncode({
        'appVersion': '1.0.0',
        'settings': <String, dynamic>{},
      });
      expect(() => configService.importConfig(json), throwsFormatException);
    });
  });
}
