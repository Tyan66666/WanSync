import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../models/onelap_activity.dart';
import '../models/sync_progress.dart';
import '../models/sync_summary.dart';
import '../models/sync_record.dart';
import 'concurrency_pool.dart';
import 'dedupe_service.dart';
import 'fit_coordinate_rewrite_service.dart';
import 'gcj_correction_settings.dart';
import 'intervals_icu_client.dart';
import 'onelap_client.dart';
import 'outbase_client.dart';
import 'strava_upload_client.dart';
import 'state_store.dart';
import 'xingzhe_client.dart';

class _PlatformUploadResult {
  final List<PlatformSyncResult> platformResults;
  final int uploaded;
  final int failed;
  final int success;
  final int deduped;
  final List<FailedActivitySummary> failures;
  final List<String> failureReasons;

  const _PlatformUploadResult({
    this.platformResults = const [],
    this.uploaded = 0,
    this.failed = 0,
    this.success = 0,
    this.deduped = 0,
    this.failures = const [],
    this.failureReasons = const [],
  });
}

class _DownloadResult {
  final OneLapActivity item;
  final File file;
  final FitSessionMeta meta;
  final Object? error;

  _DownloadResult({
    required this.item,
    File? file,
    this.meta = const FitSessionMeta(),
    this.error,
  }) : file = file ?? File('');
}

class SyncEngine {
  final OneLapClient oneLapClient;
  final StravaUploadClient? stravaClient;
  final XingzheClient? xingzheClient;
  final IntervalsIcuClient? intervalsIcuClient;
  final OutbaseClient? outbaseClient;
  final StateStore stateStore;
  final GcjCorrectionSettings gcjCorrection;
  final FitCoordinateRewriteService? rewriteService;
  final bool uploadToStrava;
  final bool uploadToXingzhe;
  final bool uploadToIntervalsIcu;
  final bool uploadToOutbase;
  final int downloadConcurrency;

  SyncEngine({
    required this.oneLapClient,
    required this.stravaClient,
    this.xingzheClient,
    this.intervalsIcuClient,
    this.outbaseClient,
    required this.stateStore,
    this.gcjCorrection = const GcjCorrectionSettings(),
    this.rewriteService,
    this.uploadToStrava = true,
    this.uploadToXingzhe = false,
    this.uploadToIntervalsIcu = false,
    this.uploadToOutbase = false,
    this.downloadConcurrency = 3,
  });

  Future<SyncSummary> runOnce({
    DateTime? sinceDate,
    int lookbackDays = 3,
    void Function(SyncProgress)? onProgress,
  }) async {
    final since =
        sinceDate ?? DateTime.now().subtract(Duration(days: lookbackDays));
    final cacheDir = await getApplicationCacheDirectory();
    final downloadDir = Directory('${cacheDir.path}/fit_downloads');
    if (!downloadDir.existsSync()) downloadDir.createSync(recursive: true);

    final OneLapActivityQuery activityQuery;
    try {
      activityQuery = await oneLapClient.fetchActivities(
        since: since,
        until: DateTime.now(),
      );
    } on OnelapRiskControlError {
      return const SyncSummary(
        fetched: 0,
        deduped: 0,
        success: 0,
        failed: 0,
        abortedReason: 'risk-control',
      );
    }
    final List<OneLapActivity> activities = activityQuery.activities;

    var progress = SyncProgress(
      totalActivities: activities.length,
      stravaEnabled: uploadToStrava,
      xingzheEnabled: uploadToXingzhe,
      intervalsIcuEnabled: uploadToIntervalsIcu,
      outbaseEnabled: uploadToOutbase,
    );
    onProgress?.call(progress);

    int deduped = 0, success = 0, failed = 0;
    final List<String> failureReasons = [];
    final List<SyncRecord> syncRecords = [];

    // === 按平台统计 ===
    int xingzheSuccess = 0, xingzheFailed = 0, xingzheDeduped = 0;
    int stravaSuccess = 0, stravaFailed = 0, stravaDeduped = 0;
    int intervalsIcuSuccess = 0,
        intervalsIcuFailed = 0,
        intervalsIcuDeduped = 0;
    int outbaseSuccess = 0, outbaseFailed = 0, outbaseDeduped = 0;
    final List<FailedActivitySummary> xingzheFailures = [];
    final List<FailedActivitySummary> stravaFailures = [];
    final List<FailedActivitySummary> intervalsIcuFailures = [];
    final List<FailedActivitySummary> outbaseFailures = [];

    // Phase 1: Download all FIT files concurrently
    final pool = ConcurrencyPool<_DownloadResult>(
      maxConcurrent: downloadConcurrency,
    );
    final downloadTasks = activities
        .map(
          (item) => () async {
            try {
              final file = await oneLapClient.downloadFit(
                item.fitUrl,
                item.sourceFilename,
                downloadDir,
                activity: item,
              );
              final meta = await parseFitSessionMeta(file);
              return _DownloadResult(item: item, file: file, meta: meta);
            } catch (e) {
              return _DownloadResult(item: item, error: e);
            }
          },
        )
        .toList();
    final downloadResults = await pool.runAll(downloadTasks);

    // Phase 2: Process each downloaded activity sequentially
    int processedCount = 0;
    for (final dlResult in downloadResults) {
      if (dlResult is! _DownloadResult) continue;
      final item = dlResult.item;

      if (dlResult.error != null) {
        final e = dlResult.error!;
        failed++;
        if (e is DioException) {
          final statusCode = e.response?.statusCode;
          final msg = e.message?.trim() ?? '';
          failureReasons.add(
            '下载失败 (${item.sourceFilename}): ${[if (statusCode != null) 'HTTP $statusCode', if (msg.isNotEmpty) msg].join(' | ')}',
          );
          syncRecords.add(
            _failedRecord(
              '',
              item,
              const FitSessionMeta(),
              'download',
              '下载失败: $msg',
            ),
          );
        } else {
          failureReasons.add('下载失败 (${item.sourceFilename}): $e');
          syncRecords.add(
            _failedRecord(
              '',
              item,
              const FitSessionMeta(),
              'download',
              '下载失败: $e',
            ),
          );
        }
        processedCount++;
        progress = progress.copyWith(processed: processedCount);
        onProgress?.call(progress);
        continue;
      }

      String? currentFingerprint;
      final sessionMeta = dlResult.meta;
      final fitFile = dlResult.file;

      // ---- 2. 生成 dedupeKey（归一化起始时间 + 距离），检查是否命中 ----
      final distM = sessionMeta.distanceM;
      final dedupeKey = buildDedupeKey(
        startTime: item.startTime,
        distanceM: distM,
      );
      final alreadyDeduped = await stateStore.isDedupeKey(dedupeKey);

      if (alreadyDeduped) {
        // 该活动已完整同步过（dedupeKey 命中），跳过下载，用存储指纹判断 per-platform
        final storedFp = await stateStore.getDedupeKeyFingerprint(dedupeKey);
        currentFingerprint = storedFp;

        if (storedFp != null) {
          bool skipStrava = false;
          bool skipXingzhe = false;
          final List<PlatformSyncResult> preSkipped = [];

          if (uploadToStrava) {
            final already = await stateStore.isAlreadyUploaded(
              storedFp,
              SyncPlatform.strava.storageKey,
            );
            if (already) {
              final remoteId = await stateStore.getRemoteActivityId(
                storedFp,
                SyncPlatform.strava.storageKey,
              );
              bool verified = true;
              if (remoteId != null && stravaClient != null) {
                verified = await stravaClient!.activityExists(remoteId);
              } else if (remoteId == null) {
                verified = false;
              }
              if (verified) {
                skipStrava = true;
                preSkipped.add(
                  PlatformSyncResult(
                    platform: SyncPlatform.strava,
                    status: SyncStatus.deduped,
                    syncedAt: DateTime.now().toIso8601String(),
                  ),
                );
              } else {
                await stateStore.clearPlatformStatus(
                  storedFp,
                  SyncPlatform.strava.storageKey,
                );
              }
            }
          }
          if (uploadToXingzhe) {
            final already = await stateStore.isAlreadyUploaded(
              storedFp,
              SyncPlatform.xingzhe.storageKey,
            );
            if (already) {
              skipXingzhe = true;
              preSkipped.add(
                PlatformSyncResult(
                  platform: SyncPlatform.xingzhe,
                  status: SyncStatus.deduped,
                  syncedAt: DateTime.now().toIso8601String(),
                ),
              );
            }
          }

          bool skipIntervalsIcu = false;
          if (uploadToIntervalsIcu) {
            final already = await stateStore.isAlreadyUploaded(
              storedFp,
              SyncPlatform.intervalsIcu.storageKey,
            );
            if (already) {
              skipIntervalsIcu = true;
              preSkipped.add(
                PlatformSyncResult(
                  platform: SyncPlatform.intervalsIcu,
                  status: SyncStatus.deduped,
                  syncedAt: DateTime.now().toIso8601String(),
                ),
              );
            }
          }

          bool skipOutbase = false;
          if (uploadToOutbase) {
            final already = await stateStore.isAlreadyUploaded(
              storedFp,
              SyncPlatform.outbase.storageKey,
            );
            if (already) {
              skipOutbase = true;
              preSkipped.add(
                PlatformSyncResult(
                  platform: SyncPlatform.outbase,
                  status: SyncStatus.deduped,
                  syncedAt: DateTime.now().toIso8601String(),
                ),
              );
            }
          }

          if ((!uploadToStrava || skipStrava) &&
              (!uploadToXingzhe || skipXingzhe) &&
              (!uploadToIntervalsIcu || skipIntervalsIcu) &&
              (!uploadToOutbase || skipOutbase)) {
            // 两个平台都已在之前同步完，本次完全跳过，不计入任何计数
            deduped++;
            syncRecords.add(
              SyncRecord(
                fingerprint: storedFp,
                sourceFilename: item.sourceFilename,
                startTime: item.startTime,
                syncedAt: DateTime.now(),
                distanceM: sessionMeta.distanceM,
                ascentM: sessionMeta.ascentM,
                sport: sessionMeta.sport,
                uploadedToStrava: uploadToStrava,
                uploadedToXingzhe: uploadToXingzhe,
                uploadedToIntervalsIcu: uploadToIntervalsIcu,
                uploadedToOutbase: uploadToOutbase,
                platformResults: preSkipped,
              ),
            );
            processedCount++;
            progress = progress.copyWith(processed: processedCount);
            onProgress?.call(progress);
            continue;
          }
        }
        // 有平台未完成，继续正常上传流程（dedupeKey 命中但部分平台之前失败）
      }

      // ---- 3. 计算指纹（dedupeKey 未命中时执行；dedupeKey 命中但部分平台未完成时也执行） ----
      if (currentFingerprint == null) {
        currentFingerprint = await _makeFingerprint(
          fitFile,
          item.startTime,
          item.recordKey,
        );
        if (currentFingerprint == null) {
          failed++;
          failureReasons.add('无法生成指纹 (${item.sourceFilename})');
          syncRecords.add(
            _failedRecord('', item, sessionMeta, 'fingerprint', '无法生成指纹'),
          );
          processedCount++;
          progress = progress.copyWith(processed: processedCount);
          onProgress?.call(progress);
          continue;
        }

        // ---- 4. 按平台指纹检查：是否已成功上传过？ ----
        bool skipStrava = false;
        bool skipXingzhe = false;
        final List<PlatformSyncResult> preSkipped = [];

        if (uploadToStrava) {
          final already = await stateStore.isAlreadyUploaded(
            currentFingerprint,
            SyncPlatform.strava.storageKey,
          );
          if (already) {
            final remoteId = await stateStore.getRemoteActivityId(
              currentFingerprint,
              SyncPlatform.strava.storageKey,
            );
            bool verified = true;
            if (remoteId != null && stravaClient != null) {
              verified = await stravaClient!.activityExists(remoteId);
            } else if (remoteId == null) {
              verified = false;
            }
            if (verified) {
              skipStrava = true;
              preSkipped.add(
                PlatformSyncResult(
                  platform: SyncPlatform.strava,
                  status: SyncStatus.deduped,
                  syncedAt: DateTime.now().toIso8601String(),
                ),
              );
            } else {
              await stateStore.clearPlatformStatus(
                currentFingerprint,
                SyncPlatform.strava.storageKey,
              );
            }
          }
        }
        if (uploadToXingzhe) {
          final already = await stateStore.isAlreadyUploaded(
            currentFingerprint,
            SyncPlatform.xingzhe.storageKey,
          );
          if (already) {
            skipXingzhe = true;
            preSkipped.add(
              PlatformSyncResult(
                platform: SyncPlatform.xingzhe,
                status: SyncStatus.deduped,
                syncedAt: DateTime.now().toIso8601String(),
              ),
            );
          }
        }

        bool skipIntervalsIcu = false;
        if (uploadToIntervalsIcu) {
          final already = await stateStore.isAlreadyUploaded(
            currentFingerprint,
            SyncPlatform.intervalsIcu.storageKey,
          );
          if (already) {
            skipIntervalsIcu = true;
            preSkipped.add(
              PlatformSyncResult(
                platform: SyncPlatform.intervalsIcu,
                status: SyncStatus.deduped,
                syncedAt: DateTime.now().toIso8601String(),
              ),
            );
          }
        }

        bool skipOutbase = false;
        if (uploadToOutbase) {
          final already = await stateStore.isAlreadyUploaded(
            currentFingerprint,
            SyncPlatform.outbase.storageKey,
          );
          if (already) {
            skipOutbase = true;
            preSkipped.add(
              PlatformSyncResult(
                platform: SyncPlatform.outbase,
                status: SyncStatus.deduped,
                syncedAt: DateTime.now().toIso8601String(),
              ),
            );
          }
        }

        // 两个平台都已在之前同步完
        if ((!uploadToStrava || skipStrava) &&
            (!uploadToXingzhe || skipXingzhe) &&
            (!uploadToIntervalsIcu || skipIntervalsIcu) &&
            (!uploadToOutbase || skipOutbase)) {
          deduped++;
          syncRecords.add(
            SyncRecord(
              fingerprint: currentFingerprint,
              sourceFilename: item.sourceFilename,
              startTime: item.startTime,
              syncedAt: DateTime.now(),
              distanceM: sessionMeta.distanceM,
              ascentM: sessionMeta.ascentM,
              sport: sessionMeta.sport,
              uploadedToStrava: uploadToStrava,
              uploadedToXingzhe: uploadToXingzhe,
              uploadedToIntervalsIcu: uploadToIntervalsIcu,
              uploadedToOutbase: uploadToOutbase,
              platformResults: preSkipped,
            ),
          );
          processedCount++;
          progress = progress.copyWith(processed: processedCount);
          onProgress?.call(progress);
          continue;
        }
      }

      // ---- 5. 上传文件准备 ----
      // 坐标转换按平台独立开关；需要纠偏的平台共用同一份改写后的文件。
      final File uploadFile = fitFile;
      final bool needsCorrection =
          (uploadToStrava && stravaClient != null && gcjCorrection.strava) ||
          (uploadToXingzhe && xingzheClient != null && gcjCorrection.xingzhe) ||
          (uploadToIntervalsIcu &&
              intervalsIcuClient != null &&
              gcjCorrection.intervalsIcu) ||
          (uploadToOutbase && outbaseClient != null && gcjCorrection.outbase);
      File? correctedFile;
      String? correctionError;
      if (needsCorrection) {
        try {
          final FitCoordinateRewriteService svc =
              rewriteService ?? FitCoordinateRewriteService();
          correctedFile = await svc.rewrite(
            uploadFile,
            options: RewriteOptions(
              startTime: item.startTime,
              sourceFilename: item.sourceFilename,
            ),
          );
        } catch (e) {
          correctionError = '坐标转换失败: $e';
        }
      }

      final List<PlatformSyncResult> platformResults = [];
      int platformsUploaded = 0;
      int platformsFailed = 0;
      final now = DateTime.now().toIso8601String();

      progress = progress.copyWith(uploadTotal: progress.uploadTotal + 1);
      onProgress?.call(progress);

      // ---- upload to all enabled platforms in parallel ----
      final List<_PlatformUploadResult> stravaResults = [];
      final List<_PlatformUploadResult> xingzheResults = [];
      final List<_PlatformUploadResult> intervalsIcuResults = [];
      final List<_PlatformUploadResult> outbaseResults = [];

      final List<Future<void>> uploadFutures = [];

      try {
        if (uploadToStrava && stravaClient != null) {
          uploadFutures.add(
            _uploadToStrava(
              fingerprint: currentFingerprint,
              sourceFilename: item.sourceFilename,
              startTime: item.startTime,
              sessionMeta: sessionMeta,
              uploadFile: uploadFile,
              correctedFile: gcjCorrection.strava ? correctedFile : null,
              correctionError: gcjCorrection.strava ? correctionError : null,
              now: now,
            ).then((r) => stravaResults.add(r)),
          );
        }

        if (uploadToXingzhe && xingzheClient != null) {
          uploadFutures.add(
            _uploadToXingzhe(
              fingerprint: currentFingerprint,
              sourceFilename: item.sourceFilename,
              startTime: item.startTime,
              sessionMeta: sessionMeta,
              uploadFile: uploadFile,
              correctedFile: gcjCorrection.xingzhe ? correctedFile : null,
              correctionError: gcjCorrection.xingzhe ? correctionError : null,
              now: now,
            ).then((r) => xingzheResults.add(r)),
          );
        }

        if (uploadToIntervalsIcu && intervalsIcuClient != null) {
          uploadFutures.add(
            _uploadToIntervalsIcu(
              fingerprint: currentFingerprint,
              sourceFilename: item.sourceFilename,
              startTime: item.startTime,
              sessionMeta: sessionMeta,
              uploadFile: uploadFile,
              correctedFile: gcjCorrection.intervalsIcu ? correctedFile : null,
              correctionError: gcjCorrection.intervalsIcu
                  ? correctionError
                  : null,
              now: now,
            ).then((r) => intervalsIcuResults.add(r)),
          );
        }

        if (uploadToOutbase && outbaseClient != null) {
          uploadFutures.add(
            _uploadToOutbase(
              fingerprint: currentFingerprint,
              sourceFilename: item.sourceFilename,
              startTime: item.startTime,
              sessionMeta: sessionMeta,
              uploadFile: uploadFile,
              correctedFile: gcjCorrection.outbase ? correctedFile : null,
              correctionError: gcjCorrection.outbase ? correctionError : null,
              now: now,
            ).then((r) => outbaseResults.add(r)),
          );
        }

        // Run all platform uploads in parallel.
        // Each helper catches all exceptions internally, so Future.wait
        // never sees a rejected future — this is critical: if one helper
        // let an exception escape, Future.wait would cancel the other.
        await Future.wait(uploadFutures);
      } finally {
        await _deleteRewrittenFile(correctedFile, uploadFile);
      }

      // Aggregate Strava results
      for (final r in stravaResults) {
        platformResults.addAll(r.platformResults);
        platformsUploaded += r.uploaded;
        platformsFailed += r.failed;
        stravaSuccess += r.success;
        stravaFailed += r.failed;
        stravaDeduped += r.deduped;
        stravaFailures.addAll(r.failures);
        failureReasons.addAll(r.failureReasons);
      }

      // Aggregate Xingzhe results
      for (final r in xingzheResults) {
        platformResults.addAll(r.platformResults);
        platformsUploaded += r.uploaded;
        platformsFailed += r.failed;
        xingzheSuccess += r.success;
        xingzheFailed += r.failed;
        xingzheDeduped += r.deduped;
        xingzheFailures.addAll(r.failures);
        failureReasons.addAll(r.failureReasons);
      }

      // Aggregate Intervals.icu results
      for (final r in intervalsIcuResults) {
        platformResults.addAll(r.platformResults);
        platformsUploaded += r.uploaded;
        platformsFailed += r.failed;
        intervalsIcuSuccess += r.success;
        intervalsIcuFailed += r.failed;
        intervalsIcuDeduped += r.deduped;
        intervalsIcuFailures.addAll(r.failures);
        failureReasons.addAll(r.failureReasons);
      }

      // Aggregate Outbase results
      for (final r in outbaseResults) {
        platformResults.addAll(r.platformResults);
        platformsUploaded += r.uploaded;
        platformsFailed += r.failed;
        outbaseSuccess += r.success;
        outbaseFailed += r.failed;
        outbaseDeduped += r.deduped;
        outbaseFailures.addAll(r.failures);
        failureReasons.addAll(r.failureReasons);
      }

      final stravaInc = stravaResults.fold<int>(
        0,
        (sum, r) => sum + r.success + r.deduped,
      );
      final xingzheInc = xingzheResults.fold<int>(
        0,
        (sum, r) => sum + r.success + r.deduped,
      );
      final intervalsIcuInc = intervalsIcuResults.fold<int>(
        0,
        (sum, r) => sum + r.success + r.deduped,
      );
      final outbaseInc = outbaseResults.fold<int>(
        0,
        (sum, r) => sum + r.success + r.deduped,
      );
      progress = progress.copyWith(
        stravaUploaded: progress.stravaUploaded + stravaInc,
        xingzheUploaded: progress.xingzheUploaded + xingzheInc,
        intervalsIcuUploaded: progress.intervalsIcuUploaded + intervalsIcuInc,
        outbaseUploaded: progress.outbaseUploaded + outbaseInc,
      );
      processedCount++;
      progress = progress.copyWith(processed: processedCount);
      onProgress?.call(progress);

      // ---- 6. 更新计数 ----
      if (platformsUploaded > 0) {
        success++;
        // 成功后保存 dedupeKey（稳定 key，兜底后续指纹变化情况）
        await stateStore.markDedupeKey(dedupeKey, currentFingerprint);
      }
      if (platformsFailed > 0 && platformsUploaded == 0) {
        failed++;
      }

      // ---- 7. 保存记录 ----
      syncRecords.add(
        SyncRecord(
          fingerprint: currentFingerprint,
          sourceFilename: item.sourceFilename,
          startTime: item.startTime,
          syncedAt: DateTime.now(),
          distanceM: sessionMeta.distanceM,
          ascentM: sessionMeta.ascentM,
          sport: sessionMeta.sport,
          uploadedToStrava: uploadToStrava,
          uploadedToXingzhe: uploadToXingzhe,
          uploadedToIntervalsIcu: uploadToIntervalsIcu,
          uploadedToOutbase: uploadToOutbase,
          platformResults: platformResults,
        ),
      );
    }

    if (syncRecords.isNotEmpty) {
      await stateStore.saveSyncRecords(syncRecords);
    }

    try {
      if (downloadDir.existsSync()) {
        await downloadDir.delete(recursive: true);
      }
    } catch (_) {}

    return SyncSummary(
      fetched: activities.length,
      deduped: deduped,
      success: success,
      failed: failed,
      failureReasons: failureReasons,
      serverReturned: activityQuery.serverReturned,
      outOfRange: activityQuery.outOfRange,
      invalidRecords: activityQuery.invalid,
      rangeStart: activityQuery.rangeStart,
      rangeEnd: activityQuery.rangeEnd,
      otmImported: activityQuery.otmImported,
      otmImportError: activityQuery.otmImportError,
      xingzheSuccess: xingzheSuccess,
      xingzheFailed: xingzheFailed,
      xingzheDeduped: xingzheDeduped,
      xingzheFailures: xingzheFailures,
      stravaSuccess: stravaSuccess,
      stravaFailed: stravaFailed,
      stravaDeduped: stravaDeduped,
      stravaFailures: stravaFailures,
      intervalsIcuSuccess: intervalsIcuSuccess,
      intervalsIcuFailed: intervalsIcuFailed,
      intervalsIcuDeduped: intervalsIcuDeduped,
      intervalsIcuFailures: intervalsIcuFailures,
      outbaseSuccess: outbaseSuccess,
      outbaseFailed: outbaseFailed,
      outbaseDeduped: outbaseDeduped,
      outbaseFailures: outbaseFailures,
      syncedAt: DateTime.now(),
    );
  }

  Future<String?> _makeFingerprint(
    File fitFile,
    String startTime,
    String recordKey,
  ) async {
    try {
      return makeFingerprint(fitFile, startTime, recordKey);
    } catch (_) {
      return null;
    }
  }

  bool _isIdempotentSuccess(dynamic e) {
    final s = '$e'.toLowerCase();
    if (s.contains('9006') ||
        s.contains('文件已上传') ||
        s.contains('already') ||
        s.contains('duplicate') ||
        s.contains('dedupe') ||
        s.contains('already exists') ||
        s.contains('duplicate of')) {
      return true;
    }
    return false;
  }

  SyncRecord _failedRecord(
    String fp,
    OneLapActivity item,
    FitSessionMeta sm,
    String phase,
    String err,
  ) {
    final now = DateTime.now().toIso8601String();
    return SyncRecord(
      fingerprint: fp,
      sourceFilename: item.sourceFilename,
      startTime: item.startTime,
      syncedAt: DateTime.now(),
      distanceM: sm.distanceM,
      ascentM: sm.ascentM,
      sport: sm.sport,
      uploadedToStrava: uploadToStrava,
      uploadedToXingzhe: uploadToXingzhe,
      uploadedToIntervalsIcu: uploadToIntervalsIcu,
      uploadedToOutbase: uploadToOutbase,
      platformResults: [
        if (uploadToStrava)
          PlatformSyncResult(
            platform: SyncPlatform.strava,
            status: SyncStatus.failed,
            errorMessage: '[$phase] $err',
            syncedAt: now,
          ),
        if (uploadToXingzhe)
          PlatformSyncResult(
            platform: SyncPlatform.xingzhe,
            status: SyncStatus.failed,
            errorMessage: '[$phase] $err',
            syncedAt: now,
          ),
        if (uploadToIntervalsIcu)
          PlatformSyncResult(
            platform: SyncPlatform.intervalsIcu,
            status: SyncStatus.failed,
            errorMessage: '[$phase] $err',
            syncedAt: now,
          ),
        if (uploadToOutbase)
          PlatformSyncResult(
            platform: SyncPlatform.outbase,
            status: SyncStatus.failed,
            errorMessage: '[$phase] $err',
            syncedAt: now,
          ),
      ],
    );
  }

  // === Parallel upload helpers ===
  // Each helper catches ALL exceptions internally — never let an exception
  // escape, because Future.wait in the caller would cancel other uploads.

  FailedActivitySummary _failSummary(
    String fingerprint,
    String startTime,
    FitSessionMeta sm,
    String err,
  ) {
    String fmtDate(String s) => s.length >= 10 ? s.substring(0, 10) : s;
    String fmtDist(double? m) =>
        m == null ? '--' : '${(m / 1000).toStringAsFixed(1)}km';
    String fmtAscent(int? m) => m == null ? '--' : '${m}m';
    return FailedActivitySummary(
      fingerprint: fingerprint,
      date: fmtDate(startTime),
      distance: fmtDist(sm.distanceM),
      ascent: fmtAscent(sm.ascentM),
      error: err,
    );
  }

  Future<void> _deleteRewrittenFile(File? file, File originalFile) async {
    if (file == null || file.path == originalFile.path) {
      return;
    }
    try {
      await file.delete();
    } catch (_) {}
    try {
      await file.parent.delete();
    } catch (_) {}
  }

  Future<_PlatformUploadResult> _uploadToStrava({
    required String fingerprint,
    required String sourceFilename,
    required String startTime,
    required FitSessionMeta sessionMeta,
    required File uploadFile,
    required File? correctedFile,
    required String? correctionError,
    required String now,
  }) async {
    final platformResults = <PlatformSyncResult>[];
    int uploaded = 0, failed = 0;
    int sSuccess = 0, sDeduped = 0;
    final List<FailedActivitySummary> sFailures = [];
    final List<String> sFailureReasons = [];

    final alreadySynced = await stateStore.isAlreadyUploaded(
      fingerprint,
      SyncPlatform.strava.storageKey,
    );
    bool shouldSkip = false;

    if (alreadySynced) {
      final remoteId = await stateStore.getRemoteActivityId(
        fingerprint,
        SyncPlatform.strava.storageKey,
      );
      bool verified = true;
      if (remoteId != null && stravaClient != null) {
        verified = await stravaClient!.activityExists(remoteId);
      } else if (remoteId == null) {
        verified = false;
      }
      if (verified) {
        shouldSkip = true;
      } else {
        await stateStore.clearPlatformStatus(
          fingerprint,
          SyncPlatform.strava.storageKey,
        );
      }
    }

    if (shouldSkip) {
      platformResults.add(
        PlatformSyncResult(
          platform: SyncPlatform.strava,
          status: SyncStatus.deduped,
          syncedAt: now,
        ),
      );
      sDeduped++;
    } else if (correctionError != null) {
      platformResults.add(
        PlatformSyncResult(
          platform: SyncPlatform.strava,
          status: SyncStatus.failed,
          errorMessage: correctionError,
          syncedAt: now,
        ),
      );
      failed++;
      sFailures.add(
        _failSummary(fingerprint, startTime, sessionMeta, '坐标转换失败'),
      );
      sFailureReasons.add('Strava 上传失败 ($sourceFilename): $correctionError');
    } else {
      final File effectiveUploadFile = correctedFile ?? uploadFile;

      try {
        final uploadId = await stravaClient!.uploadFit(effectiveUploadFile);
        final result = await stravaClient!.pollUpload(uploadId);
        final activityId = result['activity_id'];
        final error = result['error'];

        if (activityId == null && error != null) {
          final errorStr = '$error'.toLowerCase();
          if (errorStr.contains('duplicate of')) {
            // Safe to call concurrently — Dart is single-threaded, so both
            // platform helpers mutate the same cached Map reference.
            await stateStore.markPlatformSynced(
              fingerprint,
              SyncPlatform.strava.storageKey,
              null,
            );
            platformResults.add(
              PlatformSyncResult(
                platform: SyncPlatform.strava,
                status: SyncStatus.deduped,
                syncedAt: now,
              ),
            );
            sDeduped++;
          } else {
            platformResults.add(
              PlatformSyncResult(
                platform: SyncPlatform.strava,
                status: SyncStatus.failed,
                errorMessage: '$error',
                syncedAt: now,
              ),
            );
            failed++;

            sFailures.add(
              _failSummary(fingerprint, startTime, sessionMeta, error),
            );
            sFailureReasons.add('Strava 上传失败 ($sourceFilename): $error');
          }
        } else {
          final aid = (activityId as num).toInt();
          await stateStore.markPlatformSynced(
            fingerprint,
            SyncPlatform.strava.storageKey,
            aid,
          );
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.strava,
              status: SyncStatus.success,
              remoteActivityId: aid,
              syncedAt: now,
            ),
          );
          uploaded++;
          sSuccess++;
        }
      } catch (e) {
        if (_isIdempotentSuccess(e)) {
          await stateStore.markPlatformSynced(
            fingerprint,
            SyncPlatform.strava.storageKey,
            null,
          );
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.strava,
              status: SyncStatus.success,
              syncedAt: now,
            ),
          );
          uploaded++;
          sSuccess++;
        } else {
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.strava,
              status: SyncStatus.failed,
              errorMessage: '$e',
              syncedAt: now,
            ),
          );
          failed++;
          sFailures.add(
            _failSummary(fingerprint, startTime, sessionMeta, '$e'),
          );
          sFailureReasons.add('Strava 上传失败 ($sourceFilename): $e');
        }
      }
    }

    return _PlatformUploadResult(
      platformResults: platformResults,
      uploaded: uploaded,
      failed: failed,
      success: sSuccess,
      deduped: sDeduped,
      failures: sFailures,
      failureReasons: sFailureReasons,
    );
  }

  Future<_PlatformUploadResult> _uploadToXingzhe({
    required String fingerprint,
    required String sourceFilename,
    required String startTime,
    required FitSessionMeta sessionMeta,
    required File uploadFile,
    required File? correctedFile,
    required String? correctionError,
    required String now,
  }) async {
    final platformResults = <PlatformSyncResult>[];
    int uploaded = 0, failed = 0;
    int xSuccess = 0, xDeduped = 0;
    final List<FailedActivitySummary> xFailures = [];
    final List<String> xFailureReasons = [];

    final skip = await stateStore.isAlreadyUploaded(
      fingerprint,
      SyncPlatform.xingzhe.storageKey,
    );
    if (skip) {
      platformResults.add(
        PlatformSyncResult(
          platform: SyncPlatform.xingzhe,
          status: SyncStatus.deduped,
          syncedAt: now,
        ),
      );
      xDeduped++;
    } else if (correctionError != null) {
      platformResults.add(
        PlatformSyncResult(
          platform: SyncPlatform.xingzhe,
          status: SyncStatus.failed,
          errorMessage: correctionError,
          syncedAt: now,
        ),
      );
      failed++;
      xFailures.add(
        _failSummary(fingerprint, startTime, sessionMeta, '坐标转换失败'),
      );
      xFailureReasons.add('行者 上传失败 ($sourceFilename): $correctionError');
    } else {
      try {
        final uploadId = await xingzheClient!.uploadFit(
          correctedFile ?? uploadFile,
        );
        final result = await xingzheClient!.pollUpload(uploadId);
        final activityId = result['activity_id'];
        final error = result['error'];

        if (activityId == null || (activityId is num && activityId == 0)) {
          final isIdempotent = _isIdempotentSuccess(error ?? '');
          if (error != null && !isIdempotent) {
            platformResults.add(
              PlatformSyncResult(
                platform: SyncPlatform.xingzhe,
                status: SyncStatus.failed,
                errorMessage: '$error',
                syncedAt: now,
              ),
            );
            failed++;
            xFailures.add(
              _failSummary(fingerprint, startTime, sessionMeta, error),
            );
            xFailureReasons.add('行者 上传失败 ($sourceFilename): $error');
          } else {
            // Safe to call concurrently — Dart is single-threaded, so both
            // platform helpers mutate the same cached Map reference.
            await stateStore.markPlatformSynced(
              fingerprint,
              SyncPlatform.xingzhe.storageKey,
              null,
            );
            platformResults.add(
              PlatformSyncResult(
                platform: SyncPlatform.xingzhe,
                status: SyncStatus.success,
                syncedAt: now,
              ),
            );
            uploaded++;
            xSuccess++;
          }
        } else {
          final aid = activityId is int
              ? activityId
              : int.tryParse('$activityId') ?? 0;
          await stateStore.markPlatformSynced(
            fingerprint,
            SyncPlatform.xingzhe.storageKey,
            aid,
          );
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.xingzhe,
              status: SyncStatus.success,
              remoteActivityId: aid,
              syncedAt: now,
            ),
          );
          uploaded++;
          xSuccess++;
        }
      } catch (e) {
        if (_isIdempotentSuccess(e)) {
          await stateStore.markPlatformSynced(
            fingerprint,
            SyncPlatform.xingzhe.storageKey,
            null,
          );
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.xingzhe,
              status: SyncStatus.success,
              syncedAt: now,
            ),
          );
          uploaded++;
          xSuccess++;
        } else {
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.xingzhe,
              status: SyncStatus.failed,
              errorMessage: '$e',
              syncedAt: now,
            ),
          );
          failed++;
          xFailures.add(
            _failSummary(fingerprint, startTime, sessionMeta, '$e'),
          );
          xFailureReasons.add('行者 上传失败 ($sourceFilename): $e');
        }
      }
    }

    return _PlatformUploadResult(
      platformResults: platformResults,
      uploaded: uploaded,
      failed: failed,
      success: xSuccess,
      deduped: xDeduped,
      failures: xFailures,
      failureReasons: xFailureReasons,
    );
  }

  Future<_PlatformUploadResult> _uploadToIntervalsIcu({
    required String fingerprint,
    required String sourceFilename,
    required String startTime,
    required FitSessionMeta sessionMeta,
    required File uploadFile,
    required File? correctedFile,
    required String? correctionError,
    required String now,
  }) async {
    final platformResults = <PlatformSyncResult>[];
    int uploaded = 0, failed = 0;
    int iSuccess = 0, iDeduped = 0;
    final List<FailedActivitySummary> iFailures = [];
    final List<String> iFailureReasons = [];

    final skip = await stateStore.isAlreadyUploaded(
      fingerprint,
      SyncPlatform.intervalsIcu.storageKey,
    );
    if (skip) {
      platformResults.add(
        PlatformSyncResult(
          platform: SyncPlatform.intervalsIcu,
          status: SyncStatus.deduped,
          syncedAt: now,
        ),
      );
      iDeduped++;
    } else if (correctionError != null) {
      platformResults.add(
        PlatformSyncResult(
          platform: SyncPlatform.intervalsIcu,
          status: SyncStatus.failed,
          errorMessage: correctionError,
          syncedAt: now,
        ),
      );
      failed++;
      iFailures.add(
        _failSummary(fingerprint, startTime, sessionMeta, '坐标转换失败'),
      );
      iFailureReasons.add(
        'Intervals.icu 上传失败 ($sourceFilename): $correctionError',
      );
    } else {
      try {
        final activityId = await intervalsIcuClient!.uploadFit(
          correctedFile ?? uploadFile,
        );
        await stateStore.markPlatformSynced(
          fingerprint,
          SyncPlatform.intervalsIcu.storageKey,
          activityId > 0 ? activityId : null,
        );
        platformResults.add(
          PlatformSyncResult(
            platform: SyncPlatform.intervalsIcu,
            status: SyncStatus.success,
            remoteActivityId: activityId > 0 ? activityId : null,
            syncedAt: now,
          ),
        );
        uploaded++;
        iSuccess++;
      } catch (e) {
        if (_isIdempotentSuccess(e)) {
          await stateStore.markPlatformSynced(
            fingerprint,
            SyncPlatform.intervalsIcu.storageKey,
            null,
          );
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.intervalsIcu,
              status: SyncStatus.success,
              syncedAt: now,
            ),
          );
          uploaded++;
          iSuccess++;
        } else {
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.intervalsIcu,
              status: SyncStatus.failed,
              errorMessage: '$e',
              syncedAt: now,
            ),
          );
          failed++;
          iFailures.add(
            _failSummary(fingerprint, startTime, sessionMeta, '$e'),
          );
          iFailureReasons.add('Intervals.icu 上传失败 ($sourceFilename): $e');
        }
      }
    }

    return _PlatformUploadResult(
      platformResults: platformResults,
      uploaded: uploaded,
      failed: failed,
      success: iSuccess,
      deduped: iDeduped,
      failures: iFailures,
      failureReasons: iFailureReasons,
    );
  }

  Future<_PlatformUploadResult> _uploadToOutbase({
    required String fingerprint,
    required String sourceFilename,
    required String startTime,
    required FitSessionMeta sessionMeta,
    required File uploadFile,
    required File? correctedFile,
    required String? correctionError,
    required String now,
  }) async {
    final platformResults = <PlatformSyncResult>[];
    int uploaded = 0, failed = 0;
    int oSuccess = 0, oDeduped = 0;
    final List<FailedActivitySummary> oFailures = [];
    final List<String> oFailureReasons = [];

    final skip = await stateStore.isAlreadyUploaded(
      fingerprint,
      SyncPlatform.outbase.storageKey,
    );
    if (skip) {
      platformResults.add(
        PlatformSyncResult(
          platform: SyncPlatform.outbase,
          status: SyncStatus.deduped,
          syncedAt: now,
        ),
      );
      oDeduped++;
    } else if (correctionError != null) {
      platformResults.add(
        PlatformSyncResult(
          platform: SyncPlatform.outbase,
          status: SyncStatus.failed,
          errorMessage: correctionError,
          syncedAt: now,
        ),
      );
      failed++;
      oFailures.add(
        _failSummary(fingerprint, startTime, sessionMeta, '坐标转换失败'),
      );
      oFailureReasons.add('Outbase 上传失败 ($sourceFilename): $correctionError');
    } else {
      try {
        final result = await outbaseClient!.uploadFit(
          correctedFile ?? uploadFile,
        );
        if (result.success) {
          await stateStore.markPlatformSynced(
            fingerprint,
            SyncPlatform.outbase.storageKey,
            null,
          );
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.outbase,
              status: SyncStatus.success,
              syncedAt: now,
            ),
          );
          uploaded++;
          oSuccess++;
        } else if (result.alreadyUploaded) {
          await stateStore.markPlatformSynced(
            fingerprint,
            SyncPlatform.outbase.storageKey,
            null,
          );
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.outbase,
              status: SyncStatus.deduped,
              syncedAt: now,
            ),
          );
          oDeduped++;
        } else {
          platformResults.add(
            PlatformSyncResult(
              platform: SyncPlatform.outbase,
              status: SyncStatus.failed,
              errorMessage: result.message ?? 'Outbase upload failed',
              syncedAt: now,
            ),
          );
          failed++;
          oFailures.add(
            _failSummary(
              fingerprint,
              startTime,
              sessionMeta,
              result.message ?? 'Outbase upload failed',
            ),
          );
          oFailureReasons.add(
            'Outbase 上传失败 ($sourceFilename): ${result.message}',
          );
        }
      } catch (e) {
        platformResults.add(
          PlatformSyncResult(
            platform: SyncPlatform.outbase,
            status: SyncStatus.failed,
            errorMessage: '$e',
            syncedAt: now,
          ),
        );
        failed++;
        oFailures.add(_failSummary(fingerprint, startTime, sessionMeta, '$e'));
        oFailureReasons.add('Outbase 上传失败 ($sourceFilename): $e');
      }
    }

    return _PlatformUploadResult(
      platformResults: platformResults,
      uploaded: uploaded,
      failed: failed,
      success: oSuccess,
      deduped: oDeduped,
      failures: oFailures,
      failureReasons: oFailureReasons,
    );
  }
}
