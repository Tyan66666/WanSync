import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/models/onelap_activity.dart';
import 'package:onelap_strava_sync/models/sync_record.dart';
import 'package:onelap_strava_sync/services/onelap_client.dart';
import 'package:onelap_strava_sync/services/outbase_client.dart';
import 'package:onelap_strava_sync/services/state_store.dart';
import 'package:onelap_strava_sync/services/sync_engine.dart';

class _FakeOneLapClient extends OneLapClient {
  _FakeOneLapClient({required this.activities, required this.downloadedFile})
    : super(baseUrl: 'https://example.com', username: 'user', password: 'pass');

  final List<OneLapActivity> activities;
  final File downloadedFile;

  @override
  Future<OneLapActivityQuery> fetchActivities({
    required DateTime since,
    DateTime? until,
    int limit = 50,
  }) async {
    return OneLapActivityQuery(
      activities: activities,
      serverReturned: activities.length,
    );
  }

  @override
  Future<File> downloadFit(
    String url,
    String fileKey,
    Directory outDir, {
    OneLapActivity? activity,
  }) async {
    return downloadedFile;
  }
}

class _FakeOutbaseClient extends OutbaseClient {
  _FakeOutbaseClient({required this.result, this.error})
    : super(sessionId: 'fake');

  final OutbaseUploadResult result;
  final Exception? error;

  @override
  Future<OutbaseUploadResult> uploadFit(File file) async {
    if (error != null) throw error!;
    return result;
  }
}

class _FakeStateStore extends StateStore {
  final Map<String, bool> uploadedPlatforms = {};
  final Map<String, int> remoteActivityIds = {};
  List<SyncRecord> capturedRecords = [];

  @override
  Future<bool> isAlreadyUploaded(String fingerprint, String platform) async {
    return uploadedPlatforms['$fingerprint:$platform'] ?? false;
  }

  @override
  Future<bool> isDedupeKey(String dedupeKey) async => false;

  @override
  Future<String?> getDedupeKeyFingerprint(String dedupeKey) async => null;

  @override
  Future<void> markPlatformSynced(
    String fingerprint,
    String platform,
    int? remoteActivityId,
  ) async {
    uploadedPlatforms['$fingerprint:$platform'] = true;
    if (remoteActivityId != null) {
      remoteActivityIds['$fingerprint:$platform'] = remoteActivityId;
    }
  }

  @override
  Future<void> markDedupeKey(String dedupeKey, String fingerprint) async {}

  @override
  Future<void> saveSyncRecords(List<SyncRecord> records) async {
    capturedRecords.addAll(records);
  }

  @override
  Future<int?> getRemoteActivityId(String fingerprint, String platform) async {
    return remoteActivityIds['$fingerprint:$platform'];
  }

  @override
  Future<void> clearPlatformStatus(String fingerprint, String platform) async {
    uploadedPlatforms.remove('$fingerprint:$platform');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel pathProviderChannel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );
  late Directory cacheDirectory;

  setUpAll(() async {
    cacheDirectory = await Directory.systemTemp.createTemp(
      'sync-engine-outbase-cache-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'getApplicationCacheDirectory') {
            return cacheDirectory.path;
          }
          return null;
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  group('SyncEngine Outbase', () {
    late Directory tempDir;
    late File fitFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sync-engine-outbase-');
      fitFile = File('${tempDir.path}/test.fit');
      await fitFile.writeAsBytes(List<int>.generate(100, (i) => i));
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    OneLapActivity makeActivity({
      String startTime = '2026-07-12T10:00:00Z',
      String sourceFilename = 'test.fit',
    }) {
      return OneLapActivity(
        activityId: 'activity-id',
        startTime: startTime,
        fitUrl: 'https://example.com/test.fit',
        recordKey: 'record-key',
        sourceFilename: sourceFilename,
      );
    }

    test(
      'uploads to Outbase when uploadToOutbase is true and client provided',
      () async {
        final outbaseClient = _FakeOutbaseClient(
          result: const OutbaseUploadResult(
            success: true,
            alreadyUploaded: false,
          ),
        );
        final stateStore = _FakeStateStore();
        final oneLapClient = _FakeOneLapClient(
          activities: [makeActivity()],
          downloadedFile: fitFile,
        );

        final engine = SyncEngine(
          oneLapClient: oneLapClient,
          stravaClient: null,
          outbaseClient: outbaseClient,
          uploadToOutbase: true,
          uploadToStrava: false,
          uploadToXingzhe: false,
          stateStore: stateStore,
        );

        final summary = await engine.runOnce(lookbackDays: 1);

        expect(summary.outbaseSuccess, 1);
        expect(summary.outbaseFailed, 0);
        expect(summary.outbaseDeduped, 0);
      },
    );

    test('does not upload to Outbase when uploadToOutbase is false', () async {
      final outbaseClient = _FakeOutbaseClient(
        result: const OutbaseUploadResult(
          success: true,
          alreadyUploaded: false,
        ),
      );
      final stateStore = _FakeStateStore();
      final oneLapClient = _FakeOneLapClient(
        activities: [makeActivity()],
        downloadedFile: fitFile,
      );

      final engine = SyncEngine(
        oneLapClient: oneLapClient,
        stravaClient: null,
        outbaseClient: outbaseClient,
        uploadToOutbase: false,
        uploadToStrava: false,
        uploadToXingzhe: false,
        stateStore: stateStore,
      );

      final summary = await engine.runOnce(lookbackDays: 1);

      expect(summary.outbaseSuccess, 0);
      expect(summary.outbaseFailed, 0);
    });

    test('Outbase already uploaded counts as deduped', () async {
      final outbaseClient = _FakeOutbaseClient(
        result: const OutbaseUploadResult(
          success: false,
          alreadyUploaded: true,
          message: '相同时间内已存在其他运动数据',
        ),
      );
      final stateStore = _FakeStateStore();
      final oneLapClient = _FakeOneLapClient(
        activities: [makeActivity()],
        downloadedFile: fitFile,
      );

      final engine = SyncEngine(
        oneLapClient: oneLapClient,
        stravaClient: null,
        outbaseClient: outbaseClient,
        uploadToOutbase: true,
        uploadToStrava: false,
        uploadToXingzhe: false,
        stateStore: stateStore,
      );

      final summary = await engine.runOnce(lookbackDays: 1);

      expect(summary.outbaseDeduped, 1);
      expect(summary.outbaseSuccess, 0);
    });

    test('Outbase failure increments failed count', () async {
      final outbaseClient = _FakeOutbaseClient(
        result: const OutbaseUploadResult(
          success: false,
          alreadyUploaded: false,
        ),
        error: const OutbasePermanentError('session expired'),
      );
      final stateStore = _FakeStateStore();
      final oneLapClient = _FakeOneLapClient(
        activities: [makeActivity()],
        downloadedFile: fitFile,
      );

      final engine = SyncEngine(
        oneLapClient: oneLapClient,
        stravaClient: null,
        outbaseClient: outbaseClient,
        uploadToOutbase: true,
        uploadToStrava: false,
        uploadToXingzhe: false,
        stateStore: stateStore,
      );

      final summary = await engine.runOnce(lookbackDays: 1);

      expect(summary.outbaseFailed, 1);
      expect(summary.outbaseSuccess, 0);
    });

    test(
      'SyncProgress.outbaseEnabled and outbaseUploaded are updated',
      () async {
        final outbaseClient = _FakeOutbaseClient(
          result: const OutbaseUploadResult(
            success: true,
            alreadyUploaded: false,
          ),
        );
        final stateStore = _FakeStateStore();
        final oneLapClient = _FakeOneLapClient(
          activities: [makeActivity()],
          downloadedFile: fitFile,
        );

        final engine = SyncEngine(
          oneLapClient: oneLapClient,
          stravaClient: null,
          outbaseClient: outbaseClient,
          uploadToOutbase: true,
          uploadToStrava: false,
          uploadToXingzhe: false,
          stateStore: stateStore,
        );

        final progressUpdates = <dynamic>[];
        await engine.runOnce(
          lookbackDays: 1,
          onProgress: (p) => progressUpdates.add(p),
        );

        final lastProgress = progressUpdates.last;
        expect(lastProgress.outbaseEnabled, true);
        expect(lastProgress.outbaseUploaded, 1);
      },
    );

    test('SyncRecord.uploadedToOutbase is set correctly', () async {
      final outbaseClient = _FakeOutbaseClient(
        result: const OutbaseUploadResult(
          success: true,
          alreadyUploaded: false,
        ),
      );
      final stateStore = _FakeStateStore();
      final oneLapClient = _FakeOneLapClient(
        activities: [makeActivity()],
        downloadedFile: fitFile,
      );

      final engine = SyncEngine(
        oneLapClient: oneLapClient,
        stravaClient: null,
        outbaseClient: outbaseClient,
        uploadToOutbase: true,
        uploadToStrava: false,
        uploadToXingzhe: false,
        stateStore: stateStore,
      );

      await engine.runOnce(lookbackDays: 1);

      expect(stateStore.capturedRecords, isNotEmpty);
      expect(stateStore.capturedRecords.first.uploadedToOutbase, true);
    });
  });
}
