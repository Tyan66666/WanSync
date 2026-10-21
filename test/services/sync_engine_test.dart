import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/models/onelap_activity.dart';
import 'package:onelap_strava_sync/models/sync_record.dart';
import 'package:onelap_strava_sync/models/sync_result_banner.dart';
import 'package:onelap_strava_sync/models/sync_summary.dart';
import 'package:onelap_strava_sync/services/fit_coordinate_rewrite_service.dart';
import 'package:onelap_strava_sync/services/gcj_correction_settings.dart';
import 'package:onelap_strava_sync/services/intervals_icu_client.dart';
import 'package:onelap_strava_sync/services/onelap_client.dart';
import 'package:onelap_strava_sync/services/state_store.dart';
import 'package:onelap_strava_sync/services/strava_client.dart';
import 'package:onelap_strava_sync/services/sync_engine.dart';
import 'package:onelap_strava_sync/services/xingzhe_client.dart';

class _FakeOneLapClient extends OneLapClient {
  _FakeOneLapClient({required this.activities, required this.downloadedFile})
    : super(baseUrl: 'https://example.com', username: 'user', password: 'pass');

  final List<OneLapActivity> activities;
  final File downloadedFile;

  @override
  Future<List<OneLapActivity>> listFitActivities({
    required DateTime since,
    int limit = 50,
  }) async {
    return activities;
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

class _FakeStravaClient extends StravaClient {
  _FakeStravaClient()
    : super(
        clientId: 'client-id',
        clientSecret: 'client-secret',
        refreshToken: 'refresh-token',
        accessToken: 'access-token',
        expiresAt: 4102444800,
      );

  File? uploadedFile;
  int uploadCalls = 0;
  bool activityExistsResult = true;

  @override
  Future<int> uploadFit(File file, {int retries = 3}) async {
    uploadedFile = file;
    uploadCalls++;
    return 42;
  }

  @override
  Future<bool> activityExists(int activityId) async => activityExistsResult;

  @override
  Future<Map<String, dynamic>> pollUpload(
    int uploadId, {
    int maxAttempts = 10,
  }) {
    return Future<Map<String, dynamic>>.value(<String, dynamic>{
      'activity_id': 99,
    });
  }
}

class _FakeStateStore extends StateStore {
  String? checkedFingerprint;
  String? markedFingerprint;
  int? markedActivityId;
  bool synced = false;
  final Map<String, bool> uploadedPlatforms = <String, bool>{};
  final Map<String, int> remoteActivityIds = {};
  final List<String> clearedPlatforms = [];
  List<SyncRecord> capturedRecords = [];
  void Function(String key, String fp)? markDedupeKeyOverride;

  @override
  Future<bool> isAlreadyUploaded(String fingerprint, String platform) async {
    checkedFingerprint = fingerprint;
    return uploadedPlatforms[platform] ?? synced;
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
    markedFingerprint = fingerprint;
    markedActivityId = remoteActivityId;
  }

  @override
  Future<void> markDedupeKey(String dedupeKey, String fingerprint) async {
    markDedupeKeyOverride?.call(dedupeKey, fingerprint);
  }

  @override
  Future<void> saveSyncRecords(List<SyncRecord> records) async {
    capturedRecords.addAll(records);
  }

  @override
  Future<int?> getRemoteActivityId(String fingerprint, String platform) async {
    return remoteActivityIds[platform];
  }

  @override
  Future<void> clearPlatformStatus(String fingerprint, String platform) async {
    clearedPlatforms.add(platform);
    uploadedPlatforms.remove(platform);
  }
}

class _FakeXingzheClient extends XingzheClient {
  _FakeXingzheClient()
    : super(username: 'xingzhe-user', password: 'xingzhe-pass');

  File? uploadedFile;
  int uploadCalls = 0;

  @override
  Future<int> uploadFit(File fitFile, {int retries = 3}) async {
    uploadedFile = fitFile;
    uploadCalls++;
    return 7;
  }

  @override
  Future<Map<String, dynamic>> pollUpload(
    int uploadId, {
    int maxAttempts = 10,
  }) async {
    return <String, dynamic>{'activity_id': 0, 'error': 'bad password'};
  }
}

class _FailingXingzheClient extends XingzheClient {
  _FailingXingzheClient() : super(username: 'user', password: 'pass');

  @override
  Future<int> uploadFit(File fitFile, {int retries = 3}) async {
    throw Exception('xingzhe upload failed');
  }

  @override
  Future<Map<String, dynamic>> pollUpload(
    int uploadId, {
    int maxAttempts = 10,
  }) async {
    return <String, dynamic>{'activity_id': 0};
  }
}

class _FakeFitCoordinateRewriteService extends FitCoordinateRewriteService {
  _FakeFitCoordinateRewriteService({this.rewrittenFile, this.error});

  final File? rewrittenFile;
  final Exception? error;
  File? receivedFile;
  int rewriteCalls = 0;

  @override
  Future<File> rewrite(File inputFile, {RewriteOptions? options}) async {
    receivedFile = inputFile;
    rewriteCalls++;
    if (error != null) {
      throw error!;
    }
    return rewrittenFile!;
  }
}

class _FakeIntervalsIcuClient extends IntervalsIcuClient {
  _FakeIntervalsIcuClient() : super(athleteId: 'athlete-id', apiKey: 'api-key');

  File? uploadedFile;
  int uploadCalls = 0;

  @override
  Future<int> uploadFit(File file, {int retries = 3}) async {
    uploadedFile = file;
    uploadCalls++;
    return 123;
  }
}

class _FailingIntervalsIcuClient extends IntervalsIcuClient {
  _FailingIntervalsIcuClient()
    : super(athleteId: 'athlete-id', apiKey: 'api-key');

  @override
  Future<int> uploadFit(File file, {int retries = 3}) async {
    throw IntervalsIcuPermanentError('API Key 无效');
  }
}

class _IdempotentIntervalsIcuClient extends IntervalsIcuClient {
  _IdempotentIntervalsIcuClient()
    : super(athleteId: 'athlete-id', apiKey: 'api-key');

  @override
  Future<int> uploadFit(File file, {int retries = 3}) async {
    throw IntervalsIcuPermanentError('duplicate of activity 98765');
  }
}

class _TrackingStravaClient extends StravaClient {
  _TrackingStravaClient({this.onStart, this.onDone})
    : super(
        clientId: 'id',
        clientSecret: 'secret',
        refreshToken: 'refresh',
        accessToken: 'access',
        expiresAt: 4102444800,
      );

  final VoidCallback? onStart;
  final VoidCallback? onDone;

  @override
  Future<int> uploadFit(File file, {int retries = 3}) async {
    onStart?.call();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    onDone?.call();
    return 42;
  }

  @override
  Future<Map<String, dynamic>> pollUpload(
    int uploadId, {
    int maxAttempts = 10,
  }) async {
    return <String, dynamic>{'activity_id': 99};
  }
}

class _TrackingXingzheClient extends XingzheClient {
  _TrackingXingzheClient({this.onStart, this.onDone})
    : super(username: 'user', password: 'pass');

  final VoidCallback? onStart;
  final VoidCallback? onDone;

  @override
  Future<int> uploadFit(File fitFile, {int retries = 3}) async {
    onStart?.call();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    onDone?.call();
    return 7;
  }

  @override
  Future<Map<String, dynamic>> pollUpload(
    int uploadId, {
    int maxAttempts = 10,
  }) async {
    return <String, dynamic>{'activity_id': 456};
  }
}

class _CountingOneLapClient extends OneLapClient {
  _CountingOneLapClient({
    required this.activities,
    required this.downloadedFile,
    this.onDownload,
    this.onDownloadDone,
  }) : super(
         baseUrl: 'https://example.com',
         username: 'user',
         password: 'pass',
       );

  final List<OneLapActivity> activities;
  final File downloadedFile;
  final VoidCallback? onDownload;
  final VoidCallback? onDownloadDone;
  int downloadCount = 0;

  @override
  Future<List<OneLapActivity>> listFitActivities({
    required DateTime since,
    int limit = 50,
  }) async => activities;

  @override
  Future<File> downloadFit(
    String url,
    String fileKey,
    Directory outDir, {
    OneLapActivity? activity,
  }) async {
    downloadCount++;
    onDownload?.call();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    onDownloadDone?.call();
    return downloadedFile;
  }
}

OneLapActivity _activity({String sourceFilename = 'activity.fit'}) {
  return OneLapActivity(
    activityId: 'activity-id',
    startTime: '2026-04-10T08:00:00Z',
    fitUrl: 'https://example.com/activity.fit',
    recordKey: 'record-key',
    sourceFilename: sourceFilename,
  );
}

Future<String> _expectedFingerprint(File file) async {
  final Digest hash = sha256.convert(await file.readAsBytes());
  return 'record-key|$hash|2026-04-10T08:00:00Z';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel pathProviderChannel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );
  late Directory cacheDirectory;

  setUpAll(() async {
    cacheDirectory = await Directory.systemTemp.createTemp(
      'sync-engine-cache-',
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

  group('SyncEngine.runOnce', () {
    test('original downloaded file is still used for fingerprinting', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-fingerprint-original-',
      );
      final File originalFile = File('${tempDir.path}/activity.fit');
      final File rewrittenFile = File('${tempDir.path}/rewritten.fit');
      await originalFile.writeAsBytes(<int>[1, 2, 3]);
      await rewrittenFile.writeAsBytes(<int>[4, 5, 6]);
      final String rewrittenFingerprint = await _expectedFingerprint(
        rewrittenFile,
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStateStore stateStore = _FakeStateStore();
      final SyncEngine engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: originalFile,
        ),
        stravaClient: _FakeStravaClient(),
        stateStore: stateStore,
        gcjCorrection: const GcjCorrectionSettings(strava: true),
        rewriteService: _FakeFitCoordinateRewriteService(
          rewrittenFile: rewrittenFile,
        ),
      );

      await engine.runOnce();

      expect(
        stateStore.checkedFingerprint,
        await _expectedFingerprint(originalFile),
      );
      expect(stateStore.checkedFingerprint, isNot(rewrittenFingerprint));
    });

    test('rewritten file is used for upload when rewrite is enabled', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-upload-rewritten-',
      );
      final File originalFile = File('${tempDir.path}/activity.fit');
      final File rewrittenFile = File('${tempDir.path}/rewritten.fit');
      await originalFile.writeAsBytes(<int>[1, 2, 3]);
      await rewrittenFile.writeAsBytes(<int>[4, 5, 6]);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStravaClient stravaClient = _FakeStravaClient();
      final _FakeFitCoordinateRewriteService rewriteService =
          _FakeFitCoordinateRewriteService(rewrittenFile: rewrittenFile);
      final SyncEngine engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: originalFile,
        ),
        stravaClient: stravaClient,
        stateStore: _FakeStateStore(),
        gcjCorrection: const GcjCorrectionSettings(strava: true),
        rewriteService: rewriteService,
      );

      await engine.runOnce();

      expect(rewriteService.receivedFile?.path, originalFile.path);
      expect(stravaClient.uploadedFile?.path, rewrittenFile.path);
    });

    test(
      'Strava gets rewritten file while Xingzhe gets original when both are enabled',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'sync-engine-strava-xingzhe-rewrite-',
        );
        final File originalFile = File('${tempDir.path}/activity.fit');
        final File rewrittenFile = File('${tempDir.path}/rewritten.fit');
        await originalFile.writeAsBytes(<int>[1, 2, 3]);
        await rewrittenFile.writeAsBytes(<int>[4, 5, 6]);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStravaClient stravaClient = _FakeStravaClient();
        final _FakeXingzheClient xingzheClient = _FakeXingzheClient();
        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(rewrittenFile: rewrittenFile);
        final SyncEngine engine = SyncEngine(
          oneLapClient: _FakeOneLapClient(
            activities: <OneLapActivity>[_activity()],
            downloadedFile: originalFile,
          ),
          stravaClient: stravaClient,
          xingzheClient: xingzheClient,
          stateStore: _FakeStateStore(),
          gcjCorrection: const GcjCorrectionSettings(strava: true),
          rewriteService: rewriteService,
          uploadToStrava: true,
          uploadToXingzhe: true,
        );

        await engine.runOnce();

        expect(rewriteService.receivedFile?.path, originalFile.path);
        expect(stravaClient.uploadedFile?.path, rewrittenFile.path);
        expect(xingzheClient.uploadedFile?.path, originalFile.path);
      },
    );

    test('cleans up the rewrite temp directory after upload attempt', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-rewrite-cleanup-',
      );
      final Directory rewrittenDir = Directory(
        '${tempDir.path}/rewritten-temp',
      );
      await rewrittenDir.create();
      final File originalFile = File('${tempDir.path}/activity.fit');
      final File rewrittenFile = File('${rewrittenDir.path}/rewritten.fit');
      await originalFile.writeAsBytes(<int>[1, 2, 3]);
      await rewrittenFile.writeAsBytes(<int>[4, 5, 6]);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final SyncEngine engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: originalFile,
        ),
        stravaClient: _FakeStravaClient(),
        stateStore: _FakeStateStore(),
        gcjCorrection: const GcjCorrectionSettings(strava: true),
        rewriteService: _FakeFitCoordinateRewriteService(
          rewrittenFile: rewrittenFile,
        ),
      );

      await engine.runOnce();

      expect(await originalFile.exists(), isTrue);
      expect(await Directory(tempDir.path).exists(), isTrue);
      expect(await rewrittenFile.exists(), isFalse);
      expect(await rewrittenDir.exists(), isFalse);
    });

    test('rewrite errors are reported as localized failure messages', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-rewrite-error-',
      );
      final File originalFile = File('${tempDir.path}/activity.fit');
      await originalFile.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStravaClient stravaClient = _FakeStravaClient();
      final SyncEngine engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: originalFile,
        ),
        stravaClient: stravaClient,
        stateStore: _FakeStateStore(),
        gcjCorrection: const GcjCorrectionSettings(strava: true),
        rewriteService: _FakeFitCoordinateRewriteService(
          error: Exception('bad coordinate'),
        ),
      );

      final summary = await engine.runOnce();

      expect(summary.failed, 1);
      expect(summary.success, 0);
      expect(summary.failureReasons, hasLength(1));
      expect(summary.failureReasons.single, contains('坐标转换失败'));
      expect(summary.stravaFailed, 1);
      expect(summary.stravaFailures, hasLength(1));
      expect(summary.stravaFailures.single.error, '坐标转换失败');
      expect(stravaClient.uploadedFile, isNull);
    });

    test('Strava rewrite failure does not block Xingzhe upload', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-strava-rewrite-xingzhe-',
      );
      final File originalFile = File('${tempDir.path}/activity.fit');
      await originalFile.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStravaClient stravaClient = _FakeStravaClient();
      final _FakeXingzheClient xingzheClient = _FakeXingzheClient();
      final SyncEngine engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: originalFile,
        ),
        stravaClient: stravaClient,
        xingzheClient: xingzheClient,
        stateStore: _FakeStateStore(),
        gcjCorrection: const GcjCorrectionSettings(strava: true),
        rewriteService: _FakeFitCoordinateRewriteService(
          error: Exception('bad coordinate'),
        ),
        uploadToStrava: true,
        uploadToXingzhe: true,
      );

      final summary = await engine.runOnce();

      expect(summary.stravaFailed, 1);
      expect(summary.stravaFailures.single.error, '坐标转换失败');
      expect(stravaClient.uploadedFile, isNull);
      expect(xingzheClient.uploadedFile?.path, originalFile.path);
      expect(xingzheClient.uploadCalls, 1);
    });

    test(
      'correction enabled for Xingzhe leaves the Strava upload file original',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'sync-engine-xingzhe-correction-',
        );
        final File originalFile = File('${tempDir.path}/activity.fit');
        final File rewrittenFile = File('${tempDir.path}/rewritten.fit');
        await originalFile.writeAsBytes(<int>[1, 2, 3]);
        await rewrittenFile.writeAsBytes(<int>[4, 5, 6]);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStravaClient stravaClient = _FakeStravaClient();
        final _FakeXingzheClient xingzheClient = _FakeXingzheClient();
        final SyncEngine engine = SyncEngine(
          oneLapClient: _FakeOneLapClient(
            activities: <OneLapActivity>[_activity()],
            downloadedFile: originalFile,
          ),
          stravaClient: stravaClient,
          xingzheClient: xingzheClient,
          stateStore: _FakeStateStore(),
          gcjCorrection: const GcjCorrectionSettings(xingzhe: true),
          rewriteService: _FakeFitCoordinateRewriteService(
            rewrittenFile: rewrittenFile,
          ),
          uploadToStrava: true,
          uploadToXingzhe: true,
        );

        await engine.runOnce();

        expect(stravaClient.uploadedFile?.path, originalFile.path);
        expect(xingzheClient.uploadedFile?.path, rewrittenFile.path);
      },
    );

    test(
      'correction failure fails only the platforms that requested it',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'sync-engine-xingzhe-correction-error-',
        );
        final File originalFile = File('${tempDir.path}/activity.fit');
        await originalFile.writeAsBytes(<int>[1, 2, 3]);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStravaClient stravaClient = _FakeStravaClient();
        final _FakeXingzheClient xingzheClient = _FakeXingzheClient();
        final SyncEngine engine = SyncEngine(
          oneLapClient: _FakeOneLapClient(
            activities: <OneLapActivity>[_activity()],
            downloadedFile: originalFile,
          ),
          stravaClient: stravaClient,
          xingzheClient: xingzheClient,
          stateStore: _FakeStateStore(),
          gcjCorrection: const GcjCorrectionSettings(xingzhe: true),
          rewriteService: _FakeFitCoordinateRewriteService(
            error: Exception('bad coordinate'),
          ),
          uploadToStrava: true,
          uploadToXingzhe: true,
        );

        final summary = await engine.runOnce();

        expect(summary.stravaSuccess, 1);
        expect(summary.stravaFailed, 0);
        expect(summary.xingzheFailed, 1);
        expect(stravaClient.uploadedFile?.path, originalFile.path);
        expect(xingzheClient.uploadedFile, isNull);
      },
    );

    test(
      'correction enabled for Intervals.icu rewrites its upload file',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'sync-engine-intervals-correction-',
        );
        final File originalFile = File('${tempDir.path}/activity.fit');
        final File rewrittenFile = File('${tempDir.path}/rewritten.fit');
        await originalFile.writeAsBytes(<int>[1, 2, 3]);
        await rewrittenFile.writeAsBytes(<int>[4, 5, 6]);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeIntervalsIcuClient intervalsIcuClient =
            _FakeIntervalsIcuClient();
        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(rewrittenFile: rewrittenFile);
        final SyncEngine engine = SyncEngine(
          oneLapClient: _FakeOneLapClient(
            activities: <OneLapActivity>[_activity()],
            downloadedFile: originalFile,
          ),
          stravaClient: _FakeStravaClient(),
          intervalsIcuClient: intervalsIcuClient,
          stateStore: _FakeStateStore(),
          gcjCorrection: const GcjCorrectionSettings(intervalsIcu: true),
          rewriteService: rewriteService,
          uploadToStrava: false,
          uploadToIntervalsIcu: true,
        );

        await engine.runOnce();

        expect(rewriteService.receivedFile?.path, originalFile.path);
        expect(intervalsIcuClient.uploadedFile?.path, rewrittenFile.path);
      },
    );

    test(
      'corrected platforms share a single rewrite of the same file',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'sync-engine-shared-correction-',
        );
        final File originalFile = File('${tempDir.path}/activity.fit');
        final File rewrittenFile = File('${tempDir.path}/rewritten.fit');
        await originalFile.writeAsBytes(<int>[1, 2, 3]);
        await rewrittenFile.writeAsBytes(<int>[4, 5, 6]);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStravaClient stravaClient = _FakeStravaClient();
        final _FakeXingzheClient xingzheClient = _FakeXingzheClient();
        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(rewrittenFile: rewrittenFile);
        final SyncEngine engine = SyncEngine(
          oneLapClient: _FakeOneLapClient(
            activities: <OneLapActivity>[_activity()],
            downloadedFile: originalFile,
          ),
          stravaClient: stravaClient,
          xingzheClient: xingzheClient,
          stateStore: _FakeStateStore(),
          gcjCorrection: const GcjCorrectionSettings(
            strava: true,
            xingzhe: true,
          ),
          rewriteService: rewriteService,
          uploadToStrava: true,
          uploadToXingzhe: true,
        );

        await engine.runOnce();

        expect(rewriteService.rewriteCalls, 1);
        expect(stravaClient.uploadedFile?.path, rewrittenFile.path);
        expect(xingzheClient.uploadedFile?.path, rewrittenFile.path);
      },
    );

    test('tracks platform deduped counts separately from failures', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-platform-deduped-',
      );
      final File originalFile = File('${tempDir.path}/activity.fit');
      await originalFile.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStateStore stateStore = _FakeStateStore()
        ..uploadedPlatforms['strava'] = true
        ..remoteActivityIds['strava'] = 99;
      final SyncEngine engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: originalFile,
        ),
        stravaClient: _FakeStravaClient(),
        xingzheClient: _FakeXingzheClient(),
        stateStore: stateStore,
        uploadToStrava: true,
        uploadToXingzhe: true,
      );

      final SyncSummary summary = await engine.runOnce();
      final SyncResultBanner banner = SyncResultBanner.fromSyncSummary(summary);

      expect(summary.success, 0);
      expect(summary.failed, 1);
      expect(summary.stravaSuccess, 0);
      expect(summary.stravaFailed, 0);
      expect(summary.stravaDeduped, 1);
      expect(summary.xingzheSuccess, 0);
      expect(summary.xingzheFailed, 1);
      expect(summary.xingzheDeduped, 0);
      expect(banner.stravaDeduped, 1);
      expect(banner.xingzheFailed, 1);
    });

    test('strava and xingzhe uploads run in parallel', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-parallel-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes([1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      int concurrent = 0;
      int maxConcurrent = 0;

      final strava = _TrackingStravaClient(
        onStart: () {
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        },
        onDone: () => concurrent--,
      );
      final xingzhe = _TrackingXingzheClient(
        onStart: () {
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        },
        onDone: () => concurrent--,
      );

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: [
            _activity(),
            _activity(sourceFilename: 'activity2.fit'),
          ],
          downloadedFile: file,
        ),
        stravaClient: strava,
        xingzheClient: xingzhe,
        stateStore: _FakeStateStore(),
        uploadToStrava: true,
        uploadToXingzhe: true,
      );

      await engine.runOnce();

      expect(
        maxConcurrent,
        greaterThanOrEqualTo(2),
        reason: 'Both platforms should upload simultaneously',
      );
      expect(
        maxConcurrent,
        lessThanOrEqualTo(2),
        reason: 'Must not exceed 2 concurrent uploads per activity',
      );
    });

    test(
      'downloads FIT files concurrently (up to concurrency limit)',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'sync-engine-concurrent-dl-',
        );
        final file = File('${tempDir.path}/activity.fit');
        await file.writeAsBytes([1, 2, 3]);

        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });

        int concurrent = 0;
        int maxConcurrent = 0;

        final fakeClient = _CountingOneLapClient(
          activities: List.generate(4, (_) => _activity()),
          downloadedFile: file,
          onDownload: () {
            concurrent++;
            if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          },
          onDownloadDone: () => concurrent--,
        );

        final engine = SyncEngine(
          oneLapClient: fakeClient,
          stravaClient: _FakeStravaClient(),
          stateStore: _FakeStateStore(),
          downloadConcurrency: 2,
        );

        await engine.runOnce();

        expect(
          maxConcurrent,
          greaterThanOrEqualTo(2),
          reason: 'Must actually download concurrently up to the limit',
        );
        expect(
          maxConcurrent,
          lessThanOrEqualTo(2),
          reason: 'Must not exceed concurrency limit',
        );
        expect(fakeClient.downloadCount, 4);
      },
    );

    test('one platform failure does not block the other', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-isolation-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes([1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final strava = _FakeStravaClient(); // succeeds
      final xingzhe = _FailingXingzheClient(); // throws on upload

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: [_activity()],
          downloadedFile: file,
        ),
        stravaClient: strava,
        xingzheClient: xingzhe,
        stateStore: _FakeStateStore(),
        uploadToStrava: true,
        uploadToXingzhe: true,
      );

      final summary = await engine.runOnce();

      // Strava should succeed even though Xingzhe failed
      expect(summary.stravaSuccess, 1);
      expect(summary.xingzheFailed, 1);
      expect(summary.success, 1); // partial success counts as success
      expect(summary.failed, 0); // only count as failed if ALL platforms failed
    });

    test('dedupe-path SyncRecord includes platform flags', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-dedup-record-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final stateStore = _FakeStateStore()
        ..synced =
            true // all platforms already synced
        ..remoteActivityIds['strava'] = 99;

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: file,
        ),
        stravaClient: _FakeStravaClient(),
        stateStore: stateStore,
      );

      final summary = await engine.runOnce();

      expect(summary.deduped, greaterThanOrEqualTo(1));
      expect(stateStore.capturedRecords, isNotEmpty);
      final dedupRecord = stateStore.capturedRecords.first;
      expect(dedupRecord.uploadedToStrava, isTrue);
      expect(dedupRecord.uploadedToXingzhe, isFalse);
    });

    test('dedupeKey includes timeSeconds when available', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-dedupe-key-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      String? capturedDedupeKey;
      final stateStore = _FakeStateStore()
        ..markDedupeKeyOverride = (String key, String fp) {
          capturedDedupeKey = key;
        };

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[
            OneLapActivity(
              activityId: 'activity-id',
              startTime: '2026-04-10T08:00:00Z',
              fitUrl: 'https://example.com/activity.fit',
              recordKey: 'record-key',
              sourceFilename: 'activity.fit',
              timeSeconds: 3600,
            ),
          ],
          downloadedFile: file,
        ),
        stravaClient: _FakeStravaClient(),
        stateStore: stateStore,
      );

      await engine.runOnce();

      expect(capturedDedupeKey, isNotNull);
      expect(capturedDedupeKey, contains('_3600'));
    });

    test('cleans up download directory after sync', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-download-cleanup-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: file,
        ),
        stravaClient: _FakeStravaClient(),
        stateStore: _FakeStateStore(),
      );

      await engine.runOnce();

      final downloadDir = Directory('${cacheDirectory.path}/fit_downloads');
      expect(await downloadDir.exists(), isFalse);
    });

    test('re-uploads to Strava when remote activity was deleted', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-strava-deleted-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final stateStore = _FakeStateStore()
        ..uploadedPlatforms['strava'] = true
        ..remoteActivityIds['strava'] = 42;

      final stravaClient = _FakeStravaClient()..activityExistsResult = false;

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: file,
        ),
        stravaClient: stravaClient,
        stateStore: stateStore,
      );

      final summary = await engine.runOnce();

      expect(summary.stravaSuccess, 1);
      expect(summary.stravaDeduped, 0);
      expect(stateStore.clearedPlatforms, contains('strava'));
    });

    test('uploads to Intervals.icu when enabled', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-intervals-icu-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final intervalsIcuClient = _FakeIntervalsIcuClient();

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: file,
        ),
        stravaClient: _FakeStravaClient(),
        intervalsIcuClient: intervalsIcuClient,
        stateStore: _FakeStateStore(),
        uploadToIntervalsIcu: true,
      );

      final summary = await engine.runOnce();

      expect(intervalsIcuClient.uploadCalls, 1);
      expect(intervalsIcuClient.uploadedFile, isNotNull);
      expect(summary.intervalsIcuSuccess, 1);
      expect(summary.intervalsIcuFailed, 0);
      expect(summary.intervalsIcuDeduped, 0);
    });

    test('Intervals.icu failure does not block Strava upload', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-intervals-icu-fail-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final stravaClient = _FakeStravaClient();
      final intervalsIcuClient = _FailingIntervalsIcuClient();

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: file,
        ),
        stravaClient: stravaClient,
        intervalsIcuClient: intervalsIcuClient,
        stateStore: _FakeStateStore(),
        uploadToStrava: true,
        uploadToIntervalsIcu: true,
      );

      final summary = await engine.runOnce();

      // Strava should succeed even though Intervals.icu failed
      expect(summary.stravaSuccess, 1);
      expect(summary.intervalsIcuFailed, 1);
      expect(summary.success, 1); // partial success counts as success
      expect(summary.failed, 0); // only count as failed if ALL platforms failed
    });

    test('skips Intervals.icu upload when already synced', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-intervals-icu-dedup-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final stateStore = _FakeStateStore()
        ..uploadedPlatforms['intervals_icu'] = true;

      final intervalsIcuClient = _FakeIntervalsIcuClient();

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: file,
        ),
        stravaClient: _FakeStravaClient(),
        intervalsIcuClient: intervalsIcuClient,
        stateStore: stateStore,
        uploadToStrava: true,
        uploadToIntervalsIcu: true,
      );

      final summary = await engine.runOnce();

      expect(intervalsIcuClient.uploadCalls, 0);
      expect(summary.intervalsIcuDeduped, 1);
      expect(summary.intervalsIcuSuccess, 0);
    });

    test('three platforms run in parallel', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-three-platforms-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes([1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      int concurrent = 0;
      int maxConcurrent = 0;

      final strava = _TrackingStravaClient(
        onStart: () {
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        },
        onDone: () => concurrent--,
      );
      final xingzhe = _TrackingXingzheClient(
        onStart: () {
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        },
        onDone: () => concurrent--,
      );
      final intervalsIcu = _FakeIntervalsIcuClient();

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: [
            _activity(),
            _activity(sourceFilename: 'activity2.fit'),
          ],
          downloadedFile: file,
        ),
        stravaClient: strava,
        xingzheClient: xingzhe,
        intervalsIcuClient: intervalsIcu,
        stateStore: _FakeStateStore(),
        uploadToStrava: true,
        uploadToXingzhe: true,
        uploadToIntervalsIcu: true,
      );

      await engine.runOnce();

      expect(
        maxConcurrent,
        greaterThanOrEqualTo(2),
        reason: 'All platforms should upload simultaneously',
      );
      expect(intervalsIcu.uploadCalls, 2);
    });

    test(
      'Intervals.icu uploads original file when correction is only enabled for Strava',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'sync-engine-intervals-rewrite-',
        );
        final file = File('${tempDir.path}/activity.fit');
        await file.writeAsBytes(<int>[1, 2, 3]);

        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });

        final intervalsIcuClient = _FakeIntervalsIcuClient();
        final rewriteService = _FakeFitCoordinateRewriteService(
          error: Exception('bad coordinate'),
        );

        final engine = SyncEngine(
          oneLapClient: _FakeOneLapClient(
            activities: <OneLapActivity>[_activity()],
            downloadedFile: file,
          ),
          stravaClient: _FakeStravaClient(),
          intervalsIcuClient: intervalsIcuClient,
          stateStore: _FakeStateStore(),
          gcjCorrection: const GcjCorrectionSettings(strava: true),
          rewriteService: rewriteService,
          uploadToStrava: false,
          uploadToIntervalsIcu: true,
        );

        final summary = await engine.runOnce();

        expect(summary.intervalsIcuFailed, 0);
        expect(summary.intervalsIcuSuccess, 1);
        expect(intervalsIcuClient.uploadCalls, 1);
        expect(intervalsIcuClient.uploadedFile?.path, file.path);
        expect(rewriteService.receivedFile, isNull);
      },
    );

    test('Intervals.icu idempotent success from duplicate error', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sync-engine-intervals-idempotent-',
      );
      final file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(<int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final intervalsIcuClient = _IdempotentIntervalsIcuClient();

      final engine = SyncEngine(
        oneLapClient: _FakeOneLapClient(
          activities: <OneLapActivity>[_activity()],
          downloadedFile: file,
        ),
        stravaClient: _FakeStravaClient(),
        intervalsIcuClient: intervalsIcuClient,
        stateStore: _FakeStateStore(),
        uploadToIntervalsIcu: true,
      );

      final summary = await engine.runOnce();

      expect(summary.intervalsIcuSuccess, 1);
      expect(summary.intervalsIcuFailed, 0);
      expect(summary.intervalsIcuDeduped, 0);
    });
  });
}
