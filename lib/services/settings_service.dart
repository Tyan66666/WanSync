import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SettingsStore {
  Future<Map<String, String>> readAll();

  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});
}

class SecureSettingsStore implements SettingsStore {
  const SecureSettingsStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  @override
  Future<Map<String, String>> readAll() {
    return _storage.readAll();
  }

  @override
  Future<String?> read({required String key}) {
    return _storage.read(key: key);
  }

  @override
  Future<void> write({required String key, required String value}) {
    return _storage.write(key: key, value: value);
  }
}

class SettingsService {
  SettingsService({SettingsStore? store})
    : _store = store ?? const SecureSettingsStore();

  final SettingsStore _store;

  static const keyOneLapUsername = 'ONELAP_USERNAME';
  static const keyOneLapPassword = 'ONELAP_PASSWORD';
  static const keyStravaClientId = 'STRAVA_CLIENT_ID';
  static const keyStravaClientSecret = 'STRAVA_CLIENT_SECRET';
  static const keyStravaRefreshToken = 'STRAVA_REFRESH_TOKEN';
  static const keyStravaAccessToken = 'STRAVA_ACCESS_TOKEN';
  static const keyStravaExpiresAt = 'STRAVA_EXPIRES_AT';
  static const keyStravaUploadMode = 'STRAVA_UPLOAD_MODE';
  static const keyStravaWebCookies = 'STRAVA_WEB_COOKIES';
  static const keyXingzheUsername = 'XINGZHE_USERNAME';
  static const keyXingzhePassword = 'XINGZHE_PASSWORD';
  static const keyXingzheSessionId = 'XINGZHE_SESSION_ID';
  static const keyLookbackDays = 'LOOKBACK_DAYS';

  /// Legacy switch, applied to Strava only on builds before per-platform
  /// correction. Kept for backward-compatible settings/config migration.
  static const keyGcjCorrectionEnabled = 'GCJ_CORRECTION_ENABLED';
  static const keyGcjCorrectionStrava = 'GCJ_CORRECTION_STRAVA';
  static const keyGcjCorrectionXingzhe = 'GCJ_CORRECTION_XINGZHE';
  static const keyGcjCorrectionIntervalsIcu = 'GCJ_CORRECTION_INTERVALSUCU';
  static const keyGcjCorrectionOutbase = 'GCJ_CORRECTION_OUTBASE';

  /// Per-platform GCJ-02 → WGS-84 correction switches, in UI order.
  static const gcjCorrectionKeys = [
    keyGcjCorrectionStrava,
    keyGcjCorrectionXingzhe,
    keyGcjCorrectionIntervalsIcu,
    keyGcjCorrectionOutbase,
  ];

  static const keyUploadToStrava = 'UPLOAD_TO_STRAVA';
  static const keyUploadToXingzhe = 'UPLOAD_TO_XINGZHE';
  static const keyIntervalsIcuAthleteId = 'INTERVALS_ICU_ATHLETE_ID';
  static const keyIntervalsIcuApiKey = 'INTERVALS_ICU_API_KEY';
  static const keyUploadToIntervalsIcu = 'UPLOAD_TO_INTERVALS_ICU';
  static const keyOutbaseSessionId = 'OUTBASE_SESSION_ID';
  static const keyUploadToOutbase = 'UPLOAD_TO_OUTBASE';
  static const keyOutbaseLoginTime = 'OUTBASE_LOGIN_TIME';

  static const allKeys = [
    keyOneLapUsername,
    keyOneLapPassword,
    keyStravaClientId,
    keyStravaClientSecret,
    keyStravaRefreshToken,
    keyStravaAccessToken,
    keyStravaExpiresAt,
    keyStravaUploadMode,
    keyStravaWebCookies,
    keyXingzheUsername,
    keyXingzhePassword,
    keyXingzheSessionId,
    keyLookbackDays,
    keyGcjCorrectionEnabled,
    keyGcjCorrectionStrava,
    keyGcjCorrectionXingzhe,
    keyGcjCorrectionIntervalsIcu,
    keyGcjCorrectionOutbase,
    keyUploadToStrava,
    keyUploadToXingzhe,
    keyIntervalsIcuAthleteId,
    keyIntervalsIcuApiKey,
    keyUploadToIntervalsIcu,
    keyOutbaseSessionId,
    keyUploadToOutbase,
    keyOutbaseLoginTime,
  ];

  Future<Map<String, String>> loadSettings() async {
    Map<String, String> storedValues;
    try {
      storedValues = await _store.readAll();
    } on PlatformException {
      if (!Platform.isMacOS) {
        rethrow;
      }
      storedValues = <String, String>{
        for (final String key in allKeys)
          key: (await _store.read(key: key)) ?? '',
      };
    }

    return <String, String>{
      for (final key in allKeys) key: storedValues[key] ?? '',
    };
  }

  Future<void> saveSettings(Map<String, String> values) async {
    for (final entry in values.entries) {
      await _store.write(key: entry.key, value: entry.value);
    }
  }
}
