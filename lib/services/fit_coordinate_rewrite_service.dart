import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'isolate_helpers.dart';

/// FIT 文件 session 元数据（距离、爬升、运动类型）
class FitSessionMeta {
  final double? distanceM;
  final int? ascentM;
  final String? sport;
  final String? startTime;
  const FitSessionMeta({
    this.distanceM,
    this.ascentM,
    this.sport,
    this.startTime,
  });
}

/// 从 FIT 文件解析 session metadata（不修改文件）。
/// CPU-bound parsing runs in a background isolate.
Future<FitSessionMeta> parseFitSessionMeta(File fitFile) async {
  return parseFitSessionMetaInIsolate(fitFile.path);
}

typedef CacheDirectoryLoader = Future<Directory> Function();

/// Rewrite options passed to [rewrite].
class RewriteOptions {
  /// The activity's start time in ISO8601 format, used to derive the output filename.
  /// If omitted, falls back to 'rewritten'.
  final String? startTime;

  /// Optional source filename to preserve extension.
  final String? sourceFilename;

  const RewriteOptions({this.startTime, this.sourceFilename});
}

class FitCoordinateRewriteService {
  FitCoordinateRewriteService({CacheDirectoryLoader? loadCacheDirectory})
    : _loadCacheDirectory = loadCacheDirectory ?? getApplicationCacheDirectory;

  final CacheDirectoryLoader _loadCacheDirectory;

  /// Rewrites the FIT file, converting GCJ-02 coordinates to WGS-84.
  ///
  /// [inputFile] - the original FIT file.
  /// [options] - optional rewrite parameters (startTime for naming).
  /// CPU-bound coordinate conversion runs in a background isolate.
  Future<File> rewrite(File inputFile, {RewriteOptions? options}) async {
    final int fileSize = await inputFile.length();
    if (fileSize < 12) {
      throw Exception('File too small to be a valid FIT file: $fileSize bytes');
    }

    // CPU-bound: parse + convert coordinates in background isolate
    final Uint8List rewrittenBytes = await rewriteFitCoordinatesInIsolate(
      inputFile.path,
    );

    // I/O: write output file on main isolate
    final Directory cacheDirectory = await _loadCacheDirectory();
    final File outputFile = await _createOutputFile(
      cacheDirectory,
      startTime: options?.startTime,
      sourceFilename: options?.sourceFilename,
    );
    await outputFile.writeAsBytes(rewrittenBytes);
    return outputFile;
  }

  /// Builds the output filename, preferring the source filename so upload
  /// targets that display the filename keep their original activity name.
  /// Falls back to startTime like '2024-01-15.fit', then 'rewritten.fit'.
  String _deriveOutputFilename({String? startTime, String? sourceFilename}) {
    final String? safeSourceName = _sanitizeFitFilename(sourceFilename);
    if (safeSourceName != null) {
      return safeSourceName;
    }
    if (startTime != null && startTime.length >= 10) {
      final datePart = startTime.substring(0, 10); // 'YYYY-MM-DD'
      return '$datePart.fit';
    }
    return 'rewritten.fit';
  }

  /// Returns a bare `*.fit` filename derived from [value], or null when it has
  /// no usable name. Path separators and filesystem-reserved characters are
  /// replaced so the name is always safe inside the temp directory.
  static String? _sanitizeFitFilename(String? value) {
    final String trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final String bareName = trimmed.split('/').last.split('\\').last;
    final String baseName = bareName.toLowerCase().endsWith('.fit')
        ? bareName.substring(0, bareName.length - 4)
        : bareName;
    final String sanitized = baseName
        .replaceAll(RegExp(r'[<>:"/\\|?*]+'), '_')
        .trim();
    if (sanitized.isEmpty) {
      return null;
    }
    return '$sanitized.fit';
  }

  Future<File> _createOutputFile(
    Directory cacheDirectory, {
    String? startTime,
    String? sourceFilename,
  }) async {
    await cacheDirectory.create(recursive: true);
    final Directory outputDirectory = await cacheDirectory.createTemp(
      'fit-coordinate-rewrite-',
    );
    final filename = _deriveOutputFilename(
      startTime: startTime,
      sourceFilename: sourceFilename,
    );
    return File('${outputDirectory.path}/$filename');
  }
}
