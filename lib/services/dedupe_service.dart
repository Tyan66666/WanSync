import 'dart:io';
import 'isolate_helpers.dart';

Future<String> makeFingerprint(
  File file,
  String startTime,
  String recordKey,
) async {
  return computeFingerprintInIsolate(file.path, startTime, recordKey);
}

/// Builds the stable fallback dedupe key shared by automatic sync and
/// share-intake uploads: `{UTC start time}_{distance in meters}`.
///
/// Both paths parse the distance from the same FIT session, but their start
/// time sources differ (OneLap returns a local ISO string, FIT stores UTC), so
/// the start time is normalized to UTC. Duration is intentionally not part of
/// the key: only automatic sync knows it from the OneLap API, and using it
/// would make the two paths produce different keys for the same activity.
String buildDedupeKey({required String startTime, required double? distanceM}) {
  final String normalizedStart = normalizeDedupeStartTime(startTime);
  final String distance = distanceM != null ? '${distanceM.round()}' : 'na';
  return '${normalizedStart}_$distance';
}

/// Normalizes an activity start time for [buildDedupeKey].
///
/// OneLap returns local time without a timezone (`2026-10-18T20:33:08`), which
/// is Beijing time, while FIT stores UTC. Naive values are therefore read as
/// UTC+8 so both sources resolve to the same instant even when the device
/// timezone is not Asia/Shanghai. Unparseable values are kept verbatim so the
/// key still degrades gracefully.
String normalizeDedupeStartTime(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  final DateTime? parsed = DateTime.tryParse(trimmed);
  if (parsed == null) {
    return trimmed;
  }

  final DateTime utcInstant = parsed.isUtc
      ? parsed
      : DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour - 8,
          parsed.minute,
          parsed.second,
          parsed.millisecond,
          parsed.microsecond,
        );
  return utcInstant.toIso8601String().replaceFirst(RegExp(r'\.\d+'), '');
}
