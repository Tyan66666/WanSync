import '../models/sync_record.dart';
import 'settings_service.dart';

/// Per-platform switches for rewriting GCJ-02 coordinates into WGS-84 before
/// uploading a FIT file.
///
/// Each upload target can be corrected independently, so a platform that
/// already expects GCJ-02 coordinates keeps receiving the original file.
class GcjCorrectionSettings {
  const GcjCorrectionSettings({
    this.strava = false,
    this.xingzhe = false,
    this.intervalsIcu = false,
    this.outbase = false,
  });

  /// Reads the per-platform switches from a stored settings map.
  ///
  /// Before per-platform switches existed, `GCJ_CORRECTION_ENABLED` only
  /// corrected Strava. A missing Strava key still falls back to that legacy
  /// value, and the fallback is applied per key so a partially written
  /// per-platform state never discards the legacy Strava setting.
  factory GcjCorrectionSettings.fromSettings(Map<String, String> settings) {
    const String legacyKey = SettingsService.keyGcjCorrectionEnabled;

    bool isOn(String key) {
      return (settings[key] ?? '').trim().toLowerCase() == 'true';
    }

    bool isSet(String key) => (settings[key] ?? '').trim().isNotEmpty;

    bool resolve(String key, {bool legacyFallback = false}) {
      if (isSet(key)) {
        return isOn(key);
      }
      return legacyFallback && isOn(legacyKey);
    }

    return GcjCorrectionSettings(
      strava: resolve(
        SettingsService.keyGcjCorrectionStrava,
        legacyFallback: true,
      ),
      xingzhe: resolve(SettingsService.keyGcjCorrectionXingzhe),
      intervalsIcu: resolve(SettingsService.keyGcjCorrectionIntervalsIcu),
      outbase: resolve(SettingsService.keyGcjCorrectionOutbase),
    );
  }

  final bool strava;
  final bool xingzhe;
  final bool intervalsIcu;
  final bool outbase;

  /// Whether at least one platform needs a rewritten file.
  bool get anyEnabled => strava || xingzhe || intervalsIcu || outbase;

  bool forSyncPlatform(SyncPlatform platform) {
    return switch (platform) {
      SyncPlatform.strava => strava,
      SyncPlatform.xingzhe => xingzhe,
      SyncPlatform.intervalsIcu => intervalsIcu,
      SyncPlatform.outbase => outbase,
    };
  }

  /// Explicit per-platform values, suitable for persisting after a migration
  /// from [SettingsService.keyGcjCorrectionEnabled].
  Map<String, String> toSettingsMap() {
    return <String, String>{
      SettingsService.keyGcjCorrectionStrava: strava.toString(),
      SettingsService.keyGcjCorrectionXingzhe: xingzhe.toString(),
      SettingsService.keyGcjCorrectionIntervalsIcu: intervalsIcu.toString(),
      SettingsService.keyGcjCorrectionOutbase: outbase.toString(),
    };
  }
}
