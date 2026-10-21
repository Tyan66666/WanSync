import 'dart:io';
import 'dart:typed_data';

import '../models/shared_fit_draft.dart';
import '../models/sync_record.dart';
import 'package:crypto/crypto.dart';
import 'dedupe_service.dart';
import 'fit_coordinate_rewrite_service.dart';
import 'fit_upload_coordinator.dart';
import 'gcj_correction_settings.dart';
import 'settings_service.dart';
import 'state_store.dart';

enum SharedFitUploadStatus {
  missingConfiguration,
  invalidFile,
  success,
  partialSuccess,
  failure,
}

class SharedFitUploadResult {
  final SharedFitUploadStatus status;
  final String? message;

  const SharedFitUploadResult({required this.status, this.message});
}

typedef SharedFitSettingsLoader = Future<Map<String, String>> Function();
typedef SharedFitSessionMetaLoader = Future<FitSessionMeta> Function(File file);
typedef SharedFitFingerprintLoader =
    Future<String> Function(File file, String startTime, String recordKey);
typedef SharedFitNow = DateTime Function();

class SharedFitUploadService {
  SharedFitUploadService({
    SharedFitSettingsLoader? loadSettings,
    FitCoordinateRewriteService? rewriteService,
    FitUploadCoordinator? coordinator,
    StateStore? stateStore,
    SharedFitSessionMetaLoader? loadFitSessionMeta,
    SharedFitFingerprintLoader? makeHistoryFingerprint,
    SharedFitFingerprintLoader? fallbackHistoryFingerprint,
    SharedFitNow? now,
  }) : _loadSettings = loadSettings ?? SettingsService().loadSettings,
       _rewriteService = rewriteService,
       _coordinator = coordinator ?? FitUploadCoordinator(),
       _stateStore = stateStore ?? StateStore(),
       _loadFitSessionMeta = loadFitSessionMeta ?? parseFitSessionMeta,
       _makeHistoryFingerprint = makeHistoryFingerprint ?? makeFingerprint,
       _fallbackHistoryFingerprint =
           fallbackHistoryFingerprint ?? makeFingerprint,
       _now = now ?? DateTime.now;

  final SharedFitSettingsLoader _loadSettings;
  final FitCoordinateRewriteService? _rewriteService;
  final FitUploadCoordinator _coordinator;
  final StateStore _stateStore;
  final SharedFitSessionMetaLoader _loadFitSessionMeta;
  final SharedFitFingerprintLoader _makeHistoryFingerprint;
  final SharedFitFingerprintLoader _fallbackHistoryFingerprint;
  final SharedFitNow _now;

  Future<FitUploadPlan> loadUploadPlan() async {
    final Map<String, String> settings = await _loadSettings();
    return _coordinator.resolveUploadPlan(settings);
  }

  Future<SharedFitUploadResult> uploadDraft(SharedFitDraft draft) async {
    if (!_hasFitExtension(draft)) {
      return const SharedFitUploadResult(
        status: SharedFitUploadStatus.invalidFile,
      );
    }

    final File file = File(draft.localFilePath);
    if (!await _isReadableFile(file)) {
      return const SharedFitUploadResult(
        status: SharedFitUploadStatus.invalidFile,
      );
    }

    final Map<String, String> settings;
    FitSessionMeta sessionMeta = const FitSessionMeta();
    try {
      settings = await _loadSettings();
    } on Exception catch (error) {
      return SharedFitUploadResult(
        status: SharedFitUploadStatus.failure,
        message:
            'Failed to load settings: ${'$error'.replaceFirst('Exception: ', '')}',
      );
    }

    final FitUploadPlan plan = _coordinator.resolveUploadPlan(settings);
    if (plan.hasMissingConfiguration) {
      return const SharedFitUploadResult(
        status: SharedFitUploadStatus.missingConfiguration,
      );
    }

    try {
      sessionMeta = await _loadFitSessionMeta(file);
    } on Exception {
      sessionMeta = const FitSessionMeta();
    }

    File uploadFile = file;
    bool shouldDeleteUploadFile = false;
    final Map<FitUploadPlatform, File> fileOverrides = {};
    final GcjCorrectionSettings gcjCorrection =
        GcjCorrectionSettings.fromSettings(settings);
    final List<FitUploadPlatform> correctionTargets = plan.targets
        .where(
          (FitUploadPlatform platform) =>
              gcjCorrection.forSyncPlatform(_mapSyncPlatform(platform)),
        )
        .toList();

    try {
      String? correctionError;
      if (correctionTargets.isNotEmpty) {
        final FitCoordinateRewriteService rewriteService =
            _rewriteService ?? FitCoordinateRewriteService();
        try {
          uploadFile = await rewriteService.rewrite(
            file,
            options: RewriteOptions(
              startTime: sessionMeta.startTime,
              sourceFilename: draft.displayName,
            ),
          );
          shouldDeleteUploadFile = uploadFile.path != file.path;
          for (final FitUploadPlatform platform in correctionTargets) {
            fileOverrides[platform] = uploadFile;
          }
        } on Exception catch (error) {
          correctionError =
              'FIT coordinate rewrite failed: ${'$error'.replaceFirst('Exception: ', '')}';
        }
      }

      if (correctionError != null) {
        final List<FitUploadPlatform> otherTargets = plan.targets
            .where(
              (FitUploadPlatform platform) =>
                  !correctionTargets.contains(platform),
            )
            .toList();
        if (otherTargets.isEmpty) {
          return SharedFitUploadResult(
            status: SharedFitUploadStatus.failure,
            message: correctionError,
          );
        }

        // 纠偏失败时，未开启纠偏的平台继续用原始文件上传。
        final Map<String, String> otherSettings = Map<String, String>.from(
          settings,
        );
        for (final FitUploadPlatform platform in correctionTargets) {
          otherSettings[_uploadKeyFor(platform)] = 'false';
        }
        final FitUploadCoordinatorResult otherResult = await _coordinator
            .uploadFile(file, otherSettings);
        final FitUploadCoordinatorResult mergedResult = _mergeRewriteFailures(
          failedPlatforms: correctionTargets,
          failureMessage: correctionError,
          otherResult: otherResult,
        );
        // Only platforms that were actually attempted may be flagged in the
        // history record; corrected targets never received a file.
        final FitUploadPlan attemptedPlan = FitUploadPlan(
          targets: otherTargets,
          hasMissingConfiguration: false,
          targetLabel: plan.targetLabel,
        );
        return await _completeUpload(
          coordinatorResult: mergedResult,
          draft: draft,
          file: file,
          plan: attemptedPlan,
          sessionMeta: sessionMeta,
        );
      }

      final FitUploadCoordinatorResult coordinatorResult = await _coordinator
          .uploadFile(file, settings, fileOverrides: fileOverrides);
      return await _completeUpload(
        coordinatorResult: coordinatorResult,
        draft: draft,
        file: file,
        plan: plan,
        sessionMeta: sessionMeta,
      );
    } on Exception catch (error) {
      return SharedFitUploadResult(
        status: SharedFitUploadStatus.failure,
        message: '$error'.replaceFirst('Exception: ', ''),
      );
    } finally {
      if (shouldDeleteUploadFile) {
        await _deleteTempUploadFile(uploadFile);
      }
    }
  }

  Future<SharedFitUploadResult> _completeUpload({
    required FitUploadCoordinatorResult coordinatorResult,
    required SharedFitDraft draft,
    required File file,
    required FitUploadPlan plan,
    required FitSessionMeta sessionMeta,
  }) async {
    final SharedFitUploadResult result = _mapCoordinatorResult(
      coordinatorResult,
    );
    try {
      await _persistSyncHistoryIfNeeded(
        draft: draft,
        file: file,
        plan: plan,
        coordinatorResult: coordinatorResult,
        sessionMeta: sessionMeta,
      );
    } on Exception {
      // History persistence is best-effort after upload completes.
    }
    try {
      await _persistDedupeStateIfNeeded(
        coordinatorResult: coordinatorResult,
        fingerprint: await _resolveDedupeFingerprint(file, sessionMeta),
        sessionMeta: sessionMeta,
      );
    } on Exception {
      // Dedupe persistence is best-effort after upload completes.
    }
    return result;
  }

  FitUploadCoordinatorResult _mergeRewriteFailures({
    required List<FitUploadPlatform> failedPlatforms,
    required String failureMessage,
    required FitUploadCoordinatorResult otherResult,
  }) {
    final List<FitUploadPlatformResult> mergedResults =
        <FitUploadPlatformResult>[
          for (final FitUploadPlatform platform in failedPlatforms)
            FitUploadPlatformResult(
              platform: platform,
              status: FitUploadPlatformStatus.failure,
              message: failureMessage,
            ),
          ...otherResult.platformResults,
        ];

    final bool hasSuccess = mergedResults.any(
      (FitUploadPlatformResult result) =>
          result.status == FitUploadPlatformStatus.success ||
          result.status == FitUploadPlatformStatus.alreadyUploaded,
    );
    final bool hasFailure = mergedResults.any(
      (FitUploadPlatformResult result) =>
          result.status == FitUploadPlatformStatus.failure,
    );

    final FitUploadCoordinatorStatus status;
    if (!hasSuccess) {
      status = FitUploadCoordinatorStatus.failure;
    } else if (hasFailure) {
      status = FitUploadCoordinatorStatus.partialSuccess;
    } else {
      status = FitUploadCoordinatorStatus.success;
    }

    return FitUploadCoordinatorResult(
      status: status,
      platformResults: mergedResults,
    );
  }

  bool _hasFitExtension(SharedFitDraft draft) {
    return draft.localFilePath.toLowerCase().endsWith('.fit') ||
        draft.displayName.toLowerCase().endsWith('.fit');
  }

  String _uploadKeyFor(FitUploadPlatform platform) {
    return switch (platform) {
      FitUploadPlatform.strava => SettingsService.keyUploadToStrava,
      FitUploadPlatform.xingzhe => SettingsService.keyUploadToXingzhe,
      FitUploadPlatform.intervalsIcu => SettingsService.keyUploadToIntervalsIcu,
      FitUploadPlatform.outbase => SettingsService.keyUploadToOutbase,
    };
  }

  Future<bool> _isReadableFile(File file) async {
    if (!await file.exists()) {
      return false;
    }

    try {
      await file.length();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _deleteTempUploadFile(File file) async {
    // The rewritten file always lives in a dedicated temp directory created by
    // FitCoordinateRewriteService (fit-coordinate-rewrite-*), so remove both
    // the file and its parent directory (mirrors sync_engine cleanup).
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Best-effort cleanup for rewritten temp files.
    }
    try {
      final Directory parent = file.parent;
      if (await parent.exists()) {
        await parent.delete();
      }
    } on FileSystemException {
      // Best-effort cleanup for the rewrite temp directory.
    }
  }

  Future<void> _persistSyncHistoryIfNeeded({
    required SharedFitDraft draft,
    required File file,
    required FitUploadPlan plan,
    required FitUploadCoordinatorResult coordinatorResult,
    required FitSessionMeta sessionMeta,
  }) async {
    if (coordinatorResult.platformResults.isEmpty) {
      return;
    }

    final DateTime completionTime = _now();
    final String syncedAt = completionTime.toIso8601String();
    final String identityStartTime = await _resolveHistoryIdentityStartTime(
      file,
      sessionMeta,
    );
    final String fingerprint = await _buildHistoryFingerprint(
      file,
      identityStartTime,
    );
    if (fingerprint.isEmpty) {
      return;
    }
    final String persistedStartTime = await _resolvePersistedHistoryStartTime(
      completionTime,
      fingerprint,
      sessionMeta,
    );

    final SyncRecord record = SyncRecord(
      fingerprint: fingerprint,
      sourceFilename: draft.displayName,
      startTime: persistedStartTime,
      syncedAt: completionTime,
      distanceM: sessionMeta.distanceM,
      ascentM: sessionMeta.ascentM,
      sport: sessionMeta.sport,
      uploadedToStrava: plan.targets.contains(FitUploadPlatform.strava),
      uploadedToXingzhe: plan.targets.contains(FitUploadPlatform.xingzhe),
      uploadedToIntervalsIcu: plan.targets.contains(
        FitUploadPlatform.intervalsIcu,
      ),
      uploadedToOutbase: plan.targets.contains(FitUploadPlatform.outbase),
      platformResults: coordinatorResult.platformResults
          .map(
            (FitUploadPlatformResult result) => PlatformSyncResult(
              platform: _mapSyncPlatform(result.platform),
              status: _mapSyncStatus(result.status),
              remoteActivityId: result.remoteActivityId,
              errorMessage: _historyErrorMessage(result),
              syncedAt: syncedAt,
            ),
          )
          .toList(),
    );

    await _stateStore.saveSyncRecords(<SyncRecord>[record]);
  }

  Future<void> _persistDedupeStateIfNeeded({
    required FitUploadCoordinatorResult coordinatorResult,
    required String fingerprint,
    required FitSessionMeta sessionMeta,
  }) async {
    if (fingerprint.isEmpty) {
      return;
    }

    final List<FitUploadPlatformResult> successfulResults = coordinatorResult
        .platformResults
        .where(
          (FitUploadPlatformResult result) =>
              result.status == FitUploadPlatformStatus.success ||
              result.status == FitUploadPlatformStatus.alreadyUploaded,
        )
        .toList();
    if (successfulResults.isEmpty) {
      return;
    }

    final String? dedupeKey = _dedupeKey(sessionMeta);
    if (dedupeKey != null) {
      await _stateStore.markDedupeKey(dedupeKey, fingerprint);
    }

    for (final FitUploadPlatformResult result in successfulResults) {
      await _stateStore.markPlatformSynced(
        fingerprint,
        _mapSyncPlatform(result.platform).storageKey,
        result.remoteActivityId,
      );
    }
  }

  Future<String> _resolveDedupeFingerprint(
    File file,
    FitSessionMeta sessionMeta,
  ) async {
    final String identityStartTime = await _resolveHistoryIdentityStartTime(
      file,
      sessionMeta,
    );
    return _buildHistoryFingerprint(file, identityStartTime);
  }

  String? _dedupeKey(FitSessionMeta sessionMeta) {
    final String startTime = (sessionMeta.startTime ?? '').trim();
    if (startTime.isEmpty) {
      return null;
    }

    return buildDedupeKey(
      startTime: startTime,
      distanceM: sessionMeta.distanceM,
    );
  }

  Future<String> _buildHistoryFingerprint(File file, String startTime) async {
    final String recordKey = _sharedHistoryRecordKey();
    try {
      return await _makeHistoryFingerprint(file, startTime, recordKey);
    } on Exception {
      try {
        return await _fallbackHistoryFingerprint(file, startTime, recordKey);
      } on Exception {
        return '';
      }
    }
  }

  String _sharedHistoryRecordKey() {
    return 'shared-fit-upload';
  }

  Future<String> _resolveHistoryIdentityStartTime(
    File file,
    FitSessionMeta sessionMeta,
  ) async {
    final String parsedStartTime = (sessionMeta.startTime ?? '').trim();
    if (parsedStartTime.isNotEmpty) {
      return parsedStartTime;
    }

    return _stableFileDerivedStartTime(file);
  }

  Future<String> _resolvePersistedHistoryStartTime(
    DateTime completionTime,
    String fingerprint,
    FitSessionMeta sessionMeta,
  ) async {
    final String parsedStartTime = (sessionMeta.startTime ?? '').trim();
    if (parsedStartTime.isNotEmpty) {
      return parsedStartTime;
    }

    final List<SyncRecord> existingRecords = await _stateStore.loadSyncRecords(
      limit: 500,
    );
    for (final SyncRecord record in existingRecords) {
      if (record.fingerprint == fingerprint && record.startTime.isNotEmpty) {
        return record.startTime;
      }
    }

    return completionTime.toUtc().toIso8601String().replaceFirst(
      RegExp(r'\.\d+'),
      '',
    );
  }

  Future<String> _stableFileDerivedStartTime(File file) async {
    final Uint8List bytes = await file.readAsBytes();
    final List<int> digestBytes = sha256.convert(bytes).bytes;
    int checksum = 0;
    for (final int unit in digestBytes.take(8)) {
      checksum = (checksum * 257 + unit) & 0x7fffffff;
    }

    final int seconds = checksum % 60;
    final int minutes = (checksum ~/ 60) % 60;
    final int hours = (checksum ~/ 3600) % 24;
    final int days = ((checksum ~/ 86400) % 28) + 1;
    return '1970-01-${days.toString().padLeft(2, '0')}T${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}Z';
  }

  SyncPlatform _mapSyncPlatform(FitUploadPlatform platform) {
    return switch (platform) {
      FitUploadPlatform.strava => SyncPlatform.strava,
      FitUploadPlatform.xingzhe => SyncPlatform.xingzhe,
      FitUploadPlatform.intervalsIcu => SyncPlatform.intervalsIcu,
      FitUploadPlatform.outbase => SyncPlatform.outbase,
    };
  }

  SyncStatus _mapSyncStatus(FitUploadPlatformStatus status) {
    return switch (status) {
      FitUploadPlatformStatus.success => SyncStatus.success,
      FitUploadPlatformStatus.alreadyUploaded => SyncStatus.deduped,
      FitUploadPlatformStatus.failure => SyncStatus.failed,
    };
  }

  String? _historyErrorMessage(FitUploadPlatformResult result) {
    if (result.status == FitUploadPlatformStatus.alreadyUploaded) {
      return null;
    }

    return result.message;
  }

  SharedFitUploadResult _mapCoordinatorResult(
    FitUploadCoordinatorResult coordinatorResult,
  ) {
    switch (coordinatorResult.status) {
      case FitUploadCoordinatorStatus.missingConfiguration:
        return const SharedFitUploadResult(
          status: SharedFitUploadStatus.missingConfiguration,
        );
      case FitUploadCoordinatorStatus.success:
        return SharedFitUploadResult(
          status: SharedFitUploadStatus.success,
          message: _buildSuccessMessage(coordinatorResult.platformResults),
        );
      case FitUploadCoordinatorStatus.partialSuccess:
        return SharedFitUploadResult(
          status: SharedFitUploadStatus.partialSuccess,
          message: _buildPartialSuccessMessage(
            coordinatorResult.platformResults,
          ),
        );
      case FitUploadCoordinatorStatus.failure:
        return SharedFitUploadResult(
          status: SharedFitUploadStatus.failure,
          message: _buildFailureMessage(coordinatorResult.platformResults),
        );
    }
  }

  String? _buildSuccessMessage(List<FitUploadPlatformResult> platformResults) {
    final List<String> successfulTargets = _successfulTargetLabels(
      platformResults,
    );
    if (successfulTargets.isEmpty) {
      return null;
    }

    return 'FIT 文件已经上传到 ${_joinTargetLabels(successfulTargets)}。';
  }

  String? _buildPartialSuccessMessage(
    List<FitUploadPlatformResult> platformResults,
  ) {
    final List<String> successfulTargets = _successfulTargetLabels(
      platformResults,
    );
    final List<String> failureMessages = platformResults
        .where(
          (FitUploadPlatformResult result) =>
              result.status == FitUploadPlatformStatus.failure,
        )
        .map(
          (FitUploadPlatformResult result) =>
              '${_platformLabel(result.platform)}上传失败${_formatFailureDetail(result.message)}',
        )
        .toList();

    if (successfulTargets.isEmpty) {
      return _buildFailureMessage(platformResults);
    }

    if (failureMessages.isEmpty) {
      return 'FIT 文件已经上传到 ${_joinTargetLabels(successfulTargets)}。';
    }

    return '已上传到 ${_joinTargetLabels(successfulTargets)}；${failureMessages.join('；')}';
  }

  String? _buildFailureMessage(List<FitUploadPlatformResult> platformResults) {
    final List<String> failureMessages = platformResults
        .where(
          (FitUploadPlatformResult result) =>
              result.status == FitUploadPlatformStatus.failure,
        )
        .map(
          (FitUploadPlatformResult result) =>
              '${_platformLabel(result.platform)}上传失败${_formatFailureDetail(result.message)}',
        )
        .toList();

    if (failureMessages.isNotEmpty) {
      return failureMessages.join('；');
    }

    return null;
  }

  List<String> _successfulTargetLabels(
    List<FitUploadPlatformResult> platformResults,
  ) {
    return platformResults
        .where(
          (FitUploadPlatformResult result) =>
              result.status == FitUploadPlatformStatus.success ||
              result.status == FitUploadPlatformStatus.alreadyUploaded,
        )
        .map(
          (FitUploadPlatformResult result) => _platformLabel(result.platform),
        )
        .toList();
  }

  String _joinTargetLabels(List<String> labels) {
    if (labels.length == 2) {
      return '${labels.first} 和 ${labels.last}';
    }

    return labels.join('、');
  }

  String _platformLabel(FitUploadPlatform platform) {
    return switch (platform) {
      FitUploadPlatform.strava => 'Strava',
      FitUploadPlatform.xingzhe => '行者',
      FitUploadPlatform.intervalsIcu => 'Intervals.icu',
      FitUploadPlatform.outbase => 'Outbase',
    };
  }

  String _formatFailureDetail(String? message) {
    final String trimmedMessage = (message ?? '').trim();
    if (trimmedMessage.isEmpty) {
      return '';
    }

    return '：$trimmedMessage';
  }
}
