import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/models/shared_fit_draft.dart';
import 'package:onelap_strava_sync/models/sync_record.dart';
import 'package:onelap_strava_sync/services/dedupe_service.dart';
import 'package:onelap_strava_sync/services/fit_coordinate_rewrite_service.dart';
import 'package:onelap_strava_sync/services/fit_upload_coordinator.dart';
import 'package:onelap_strava_sync/services/settings_service.dart';
import 'package:onelap_strava_sync/services/shared_fit_upload_service.dart';
import 'package:onelap_strava_sync/services/state_store.dart';

class _FakeFitCoordinateRewriteService extends FitCoordinateRewriteService {
  _FakeFitCoordinateRewriteService({this.rewriteFile, this.error});

  final File? rewriteFile;
  final Exception? error;
  File? receivedFile;
  RewriteOptions? receivedOptions;

  @override
  Future<File> rewrite(File inputFile, {RewriteOptions? options}) async {
    receivedFile = inputFile;
    receivedOptions = options;
    if (error != null) {
      throw error!;
    }
    return rewriteFile!;
  }
}

class _FakeFitUploadCoordinator extends FitUploadCoordinator {
  _FakeFitUploadCoordinator({
    FitUploadPlan? plan,
    FitUploadCoordinatorResult? result,
  }) : plan =
           plan ??
           FitUploadPlan(
             targets: <FitUploadPlatform>[FitUploadPlatform.strava],
             hasMissingConfiguration: false,
             targetLabel: 'Strava',
           ),
       result =
           result ??
           FitUploadCoordinatorResult(
             status: FitUploadCoordinatorStatus.success,
             platformResults: <FitUploadPlatformResult>[
               const FitUploadPlatformResult(
                 platform: FitUploadPlatform.strava,
                 status: FitUploadPlatformStatus.success,
               ),
             ],
           );

  FitUploadPlan plan;
  FitUploadCoordinatorResult result;
  File? uploadedFile;
  Map<FitUploadPlatform, File> uploadedFileOverrides = {};
  Map<String, String>? uploadedSettings;
  int resolveUploadPlanCalls = 0;
  int uploadFileCalls = 0;

  @override
  FitUploadPlan resolveUploadPlan(Map<String, String> settings) {
    resolveUploadPlanCalls += 1;
    return plan;
  }

  @override
  Future<FitUploadCoordinatorResult> uploadFile(
    File file,
    Map<String, String> settings, {
    Map<FitUploadPlatform, File> fileOverrides = const {},
  }) async {
    uploadFileCalls += 1;
    uploadedFile = plan.targets.isEmpty
        ? file
        : (fileOverrides[plan.targets.first] ?? file);
    uploadedFileOverrides = <FitUploadPlatform, File>{
      for (final FitUploadPlatform platform in plan.targets)
        platform: fileOverrides[platform] ?? file,
    };
    uploadedSettings = settings;
    return result;
  }
}

class _FakeStateStore extends StateStore {
  _FakeStateStore({this.error});

  final Exception? error;
  final List<List<SyncRecord>> savedBatches = <List<SyncRecord>>[];
  final List<SyncRecord> existingRecords = <SyncRecord>[];
  final List<String> markedDedupeKeys = <String>[];
  final List<(String fingerprint, String platform, int? remoteActivityId)>
  markedPlatformSyncs = <(String, String, int?)>[];

  @override
  Future<void> saveSyncRecords(List<SyncRecord> records) async {
    if (error != null) {
      throw error!;
    }
    savedBatches.add(List<SyncRecord>.from(records));
    existingRecords
      ..clear()
      ..addAll(records);
  }

  @override
  Future<List<SyncRecord>> loadSyncRecords({
    DateTime? from,
    DateTime? to,
    int limit = 100,
  }) async {
    return existingRecords.take(limit).toList();
  }

  @override
  Future<void> markDedupeKey(String dedupeKey, String fingerprint) async {
    markedDedupeKeys.add(dedupeKey);
  }

  @override
  Future<void> markPlatformSynced(
    String fingerprint,
    String platform,
    int? remoteActivityId,
  ) async {
    markedPlatformSyncs.add((fingerprint, platform, remoteActivityId));
  }
}

Map<String, String> _settings({
  String uploadToStrava = 'true',
  String uploadToXingzhe = 'false',
  String gcjCorrectionEnabled = '',
  String gcjCorrectionStrava = '',
  String gcjCorrectionXingzhe = '',
  String gcjCorrectionIntervalsIcu = '',
  String gcjCorrectionOutbase = '',
}) {
  return <String, String>{
    SettingsService.keyUploadToStrava: uploadToStrava,
    SettingsService.keyUploadToXingzhe: uploadToXingzhe,
    SettingsService.keyGcjCorrectionEnabled: gcjCorrectionEnabled,
    SettingsService.keyGcjCorrectionStrava: gcjCorrectionStrava,
    SettingsService.keyGcjCorrectionXingzhe: gcjCorrectionXingzhe,
    SettingsService.keyGcjCorrectionIntervalsIcu: gcjCorrectionIntervalsIcu,
    SettingsService.keyGcjCorrectionOutbase: gcjCorrectionOutbase,
    SettingsService.keyStravaClientId: 'client-id',
    SettingsService.keyStravaClientSecret: 'client-secret',
    SettingsService.keyStravaRefreshToken: 'refresh-token',
    SettingsService.keyXingzheUsername: 'username',
    SettingsService.keyXingzhePassword: 'password',
  };
}

Future<File> _createFitFile(Directory tempDir, {String name = 'activity.fit'}) {
  final File fitFile = File('${tempDir.path}/$name');
  return fitFile.writeAsBytes(<int>[1, 2, 3]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel pathProviderChannel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );
  late Directory documentsDirectory;

  setUp(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'shared-fit-upload-documents-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'getApplicationDocumentsDirectory') {
            return documentsDirectory.path;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  group('SharedFitUploadService.loadUploadPlan', () {
    test('returns a Strava target label from coordinator preflight', () async {
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: <FitUploadPlatform>[FitUploadPlatform.strava],
          hasMissingConfiguration: false,
          targetLabel: 'Strava',
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(uploadToStrava: 'true'),
        coordinator: coordinator,
      );

      final FitUploadPlan plan = await service.loadUploadPlan();

      expect(plan.targetLabel, 'Strava');
      expect(coordinator.resolveUploadPlanCalls, 1);
    });

    test('returns a Xingzhe target label from coordinator preflight', () async {
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: <FitUploadPlatform>[FitUploadPlatform.xingzhe],
          hasMissingConfiguration: false,
          targetLabel: '行者',
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async =>
            _settings(uploadToStrava: 'false', uploadToXingzhe: 'true'),
        coordinator: coordinator,
      );

      final FitUploadPlan plan = await service.loadUploadPlan();

      expect(plan.targetLabel, '行者');
      expect(coordinator.resolveUploadPlanCalls, 1);
    });

    test(
      'returns a dual-platform target label from coordinator preflight',
      () async {
        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[
              FitUploadPlatform.strava,
              FitUploadPlatform.xingzhe,
            ],
            hasMissingConfiguration: false,
            targetLabel: 'Strava 和 行者',
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async =>
              _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
          coordinator: coordinator,
        );

        final FitUploadPlan plan = await service.loadUploadPlan();

        expect(plan.targetLabel, 'Strava 和 行者');
        expect(coordinator.resolveUploadPlanCalls, 1);
      },
    );
  });

  group('SharedFitUploadService.uploadDraft', () {
    test('returns invalidFile for a non-fit extension', () async {
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator();
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(),
        coordinator: coordinator,
      );

      const SharedFitDraft draft = SharedFitDraft(
        localFilePath: '/tmp/activity.gpx',
        displayName: 'activity.gpx',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.invalidFile);
      expect(coordinator.resolveUploadPlanCalls, 0);
      expect(coordinator.uploadFileCalls, 0);
    });

    test('returns invalidFile when the local file is not readable', () async {
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator();
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(),
        coordinator: coordinator,
      );

      const SharedFitDraft draft = SharedFitDraft(
        localFilePath: '/tmp/missing.fit',
        displayName: 'missing.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.invalidFile);
      expect(coordinator.resolveUploadPlanCalls, 0);
      expect(coordinator.uploadFileCalls, 0);
    });

    test(
      'returns missingConfiguration when no upload targets are enabled',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-missing-config-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: const <FitUploadPlatform>[],
            hasMissingConfiguration: true,
            targetLabel: '',
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async =>
              _settings(uploadToStrava: 'false', uploadToXingzhe: 'false'),
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.missingConfiguration);
        expect(coordinator.resolveUploadPlanCalls, 1);
        expect(coordinator.uploadFileCalls, 0);
      },
    );

    test(
      'accepts a fit localFilePath when displayName lacks the fit extension',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-display-name-mismatch-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitUploadCoordinator coordinator =
            _FakeFitUploadCoordinator();
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(),
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'shared_from_onelap',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.success);
        expect(coordinator.uploadedFile, isNotNull);
        expect(coordinator.uploadedFile!.path, fitFile.path);
      },
    );

    test('returns failure when loading settings throws', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-settings-failure-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator();
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async {
          throw Exception('settings unavailable');
        },
        coordinator: coordinator,
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'activity.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.failure);
      expect(result.message, 'Failed to load settings: settings unavailable');
      expect(coordinator.resolveUploadPlanCalls, 0);
      expect(coordinator.uploadFileCalls, 0);
    });

    test('delegates the original file when GCJ rewrite is disabled', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-rewrite-disabled-',
      );
      final File fitFile = await _createFitFile(tempDir);
      final File rewrittenFile = await _createFitFile(
        tempDir,
        name: 'rewritten.fit',
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeFitCoordinateRewriteService rewriteService =
          _FakeFitCoordinateRewriteService(rewriteFile: rewrittenFile);
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator();
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(gcjCorrectionEnabled: 'false'),
        rewriteService: rewriteService,
        coordinator: coordinator,
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'activity.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.success);
      expect(rewriteService.receivedFile, isNull);
      expect(coordinator.uploadedFile, isNotNull);
      expect(coordinator.uploadedFile!.path, fitFile.path);
    });

    test(
      'rewrites the file before delegating upload when GCJ rewrite is enabled',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-rewrite-enabled-',
        );
        final File fitFile = await _createFitFile(tempDir);
        final File rewrittenFile = await _createFitFile(
          tempDir,
          name: 'rewritten.fit',
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(rewriteFile: rewrittenFile);
        final _FakeFitUploadCoordinator coordinator =
            _FakeFitUploadCoordinator();
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(gcjCorrectionEnabled: 'true'),
          rewriteService: rewriteService,
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.success);
        expect(rewriteService.receivedFile, isNotNull);
        expect(rewriteService.receivedFile!.path, fitFile.path);
        expect(coordinator.uploadedFile, isNotNull);
        expect(coordinator.uploadedFile!.path, rewrittenFile.path);
      },
    );

    test('does not rewrite when Strava is not a target', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-rewrite-xingzhe-only-',
      );
      final File fitFile = await _createFitFile(tempDir);
      final File rewrittenFile = await _createFitFile(
        tempDir,
        name: 'rewritten.fit',
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeFitCoordinateRewriteService rewriteService =
          _FakeFitCoordinateRewriteService(rewriteFile: rewrittenFile);
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: <FitUploadPlatform>[FitUploadPlatform.xingzhe],
          hasMissingConfiguration: false,
          targetLabel: '行者',
        ),
        result: FitUploadCoordinatorResult(
          status: FitUploadCoordinatorStatus.success,
          platformResults: <FitUploadPlatformResult>[
            const FitUploadPlatformResult(
              platform: FitUploadPlatform.xingzhe,
              status: FitUploadPlatformStatus.success,
            ),
          ],
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(
          uploadToStrava: 'false',
          uploadToXingzhe: 'true',
          gcjCorrectionEnabled: 'true',
        ),
        rewriteService: rewriteService,
        coordinator: coordinator,
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'activity.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.success);
      expect(rewriteService.receivedFile, isNull);
      expect(coordinator.uploadedFile?.path, fitFile.path);
      expect(coordinator.uploadedFileOverrides.length, 1);
      expect(
        coordinator.uploadedFileOverrides[FitUploadPlatform.xingzhe]?.path,
        fitFile.path,
      );
    });

    test(
      'only Strava gets the rewritten file when multiple platforms are selected',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-rewrite-strava-only-',
        );
        final File fitFile = await _createFitFile(tempDir);
        final File rewrittenFile = await _createFitFile(
          tempDir,
          name: 'rewritten.fit',
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(rewriteFile: rewrittenFile);
        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[
              FitUploadPlatform.strava,
              FitUploadPlatform.xingzhe,
            ],
            hasMissingConfiguration: false,
            targetLabel: 'Strava 和 行者',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.success,
            platformResults: <FitUploadPlatformResult>[
              const FitUploadPlatformResult(
                platform: FitUploadPlatform.strava,
                status: FitUploadPlatformStatus.success,
              ),
              const FitUploadPlatformResult(
                platform: FitUploadPlatform.xingzhe,
                status: FitUploadPlatformStatus.success,
              ),
            ],
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(
            uploadToStrava: 'true',
            uploadToXingzhe: 'true',
            gcjCorrectionEnabled: 'true',
          ),
          rewriteService: rewriteService,
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.success);
        expect(rewriteService.receivedFile?.path, fitFile.path);
        expect(
          coordinator.uploadedFileOverrides[FitUploadPlatform.strava]?.path,
          rewrittenFile.path,
        );
        expect(
          coordinator.uploadedFileOverrides[FitUploadPlatform.xingzhe]?.path,
          fitFile.path,
        );
      },
    );

    test(
      'Xingzhe keeps the original file when correction is enabled only for Strava',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-rewrite-xingzhe-original-',
        );
        final File fitFile = await _createFitFile(tempDir);
        final File rewrittenFile = await _createFitFile(
          tempDir,
          name: 'rewritten.fit',
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(rewriteFile: rewrittenFile);
        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[
              FitUploadPlatform.strava,
              FitUploadPlatform.xingzhe,
            ],
            hasMissingConfiguration: false,
            targetLabel: 'Strava 和 行者',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.success,
            platformResults: <FitUploadPlatformResult>[
              const FitUploadPlatformResult(
                platform: FitUploadPlatform.strava,
                status: FitUploadPlatformStatus.success,
              ),
              const FitUploadPlatformResult(
                platform: FitUploadPlatform.xingzhe,
                status: FitUploadPlatformStatus.success,
              ),
            ],
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(
            uploadToStrava: 'true',
            uploadToXingzhe: 'true',
            gcjCorrectionStrava: 'true',
          ),
          rewriteService: rewriteService,
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.success);
        expect(
          coordinator.uploadedFileOverrides[FitUploadPlatform.strava]?.path,
          rewrittenFile.path,
        );
        expect(
          coordinator.uploadedFileOverrides[FitUploadPlatform.xingzhe]?.path,
          fitFile.path,
        );
      },
    );

    test(
      'rewrites for Xingzhe when correction is enabled for Xingzhe',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-rewrite-xingzhe-enabled-',
        );
        final File fitFile = await _createFitFile(tempDir);
        final File rewrittenFile = await _createFitFile(
          tempDir,
          name: 'rewritten.fit',
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(rewriteFile: rewrittenFile);
        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[FitUploadPlatform.xingzhe],
            hasMissingConfiguration: false,
            targetLabel: '行者',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.success,
            platformResults: <FitUploadPlatformResult>[
              const FitUploadPlatformResult(
                platform: FitUploadPlatform.xingzhe,
                status: FitUploadPlatformStatus.success,
              ),
            ],
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(
            uploadToStrava: 'false',
            uploadToXingzhe: 'true',
            gcjCorrectionXingzhe: 'true',
          ),
          rewriteService: rewriteService,
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.success);
        expect(rewriteService.receivedFile?.path, fitFile.path);
        expect(
          coordinator.uploadedFileOverrides[FitUploadPlatform.xingzhe]?.path,
          rewrittenFile.path,
        );
      },
    );

    test(
      'rewrite failure only fails the platforms that requested correction',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-rewrite-xingzhe-failure-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(
              error: Exception('rewrite failed'),
            );
        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[
              FitUploadPlatform.strava,
              FitUploadPlatform.xingzhe,
            ],
            hasMissingConfiguration: false,
            targetLabel: 'Strava 和 行者',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.success,
            platformResults: <FitUploadPlatformResult>[
              const FitUploadPlatformResult(
                platform: FitUploadPlatform.strava,
                status: FitUploadPlatformStatus.success,
              ),
            ],
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(
            uploadToStrava: 'true',
            uploadToXingzhe: 'true',
            gcjCorrectionXingzhe: 'true',
          ),
          rewriteService: rewriteService,
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.partialSuccess);
        expect(
          result.message,
          '已上传到 Strava；'
          '行者上传失败：FIT coordinate rewrite failed: rewrite failed',
        );
        expect(coordinator.uploadFileCalls, 1);
        expect(coordinator.uploadedFile?.path, fitFile.path);
        expect(
          coordinator.uploadedSettings?[SettingsService.keyUploadToStrava],
          'true',
        );
        expect(
          coordinator.uploadedSettings?[SettingsService.keyUploadToXingzhe],
          'false',
        );
      },
    );

    test(
      'deletes rewritten temp files after the delegated upload attempt',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-rewrite-cleanup-',
        );
        final File fitFile = await _createFitFile(tempDir);
        final Directory rewrittenDir = await Directory.systemTemp.createTemp(
          'fit-coordinate-rewrite-',
        );
        final File rewrittenFile = await _createFitFile(
          rewrittenDir,
          name: 'rewritten.fit',
        );

        addTearDown(() async {
          if (await rewrittenDir.exists()) {
            await rewrittenDir.delete(recursive: true);
          }
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(rewriteFile: rewrittenFile);
        final _FakeFitUploadCoordinator coordinator =
            _FakeFitUploadCoordinator();
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(gcjCorrectionEnabled: 'true'),
          rewriteService: rewriteService,
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.success);
        expect(await fitFile.exists(), isTrue);
        expect(await rewrittenFile.exists(), isFalse);
        expect(await rewrittenDir.exists(), isFalse);
      },
    );

    test('returns failure when GCJ rewrite throws', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-rewrite-failure-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeFitCoordinateRewriteService rewriteService =
          _FakeFitCoordinateRewriteService(error: Exception('rewrite failed'));
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator();
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(gcjCorrectionEnabled: 'true'),
        rewriteService: rewriteService,
        coordinator: coordinator,
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'activity.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.failure);
      expect(result.message, 'FIT coordinate rewrite failed: rewrite failed');
      expect(coordinator.uploadFileCalls, 0);
    });

    test(
      'uploads other platforms with the original file when Strava rewrite fails',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-rewrite-failure-other-targets-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitCoordinateRewriteService rewriteService =
            _FakeFitCoordinateRewriteService(
              error: Exception('rewrite failed'),
            );
        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[
              FitUploadPlatform.strava,
              FitUploadPlatform.xingzhe,
            ],
            hasMissingConfiguration: false,
            targetLabel: 'Strava 和 行者',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.success,
            platformResults: <FitUploadPlatformResult>[
              const FitUploadPlatformResult(
                platform: FitUploadPlatform.xingzhe,
                status: FitUploadPlatformStatus.success,
              ),
            ],
          ),
        );
        final _FakeStateStore stateStore = _FakeStateStore();
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(
            uploadToStrava: 'true',
            uploadToXingzhe: 'true',
            gcjCorrectionEnabled: 'true',
          ),
          rewriteService: rewriteService,
          coordinator: coordinator,
          stateStore: stateStore,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.partialSuccess);
        expect(
          result.message,
          '已上传到 行者；'
          'Strava上传失败：FIT coordinate rewrite failed: rewrite failed',
        );
        expect(coordinator.uploadFileCalls, 1);
        expect(coordinator.uploadedFile?.path, fitFile.path);
        expect(
          coordinator.uploadedSettings?[SettingsService.keyUploadToStrava],
          'false',
        );
        expect(
          coordinator.uploadedSettings?[SettingsService.keyUploadToXingzhe],
          'true',
        );

        final SyncRecord historyRecord = stateStore.savedBatches.single.single;
        expect(historyRecord.uploadedToStrava, isFalse);
        expect(historyRecord.uploadedToXingzhe, isTrue);
        expect(historyRecord.uploadedToIntervalsIcu, isFalse);
        expect(historyRecord.uploadedToOutbase, isFalse);
      },
    );

    test('returns partialSuccess with a partial-success message', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-partial-success-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: <FitUploadPlatform>[
            FitUploadPlatform.strava,
            FitUploadPlatform.xingzhe,
          ],
          hasMissingConfiguration: false,
          targetLabel: 'Strava 和 行者',
        ),
        result: FitUploadCoordinatorResult(
          status: FitUploadCoordinatorStatus.partialSuccess,
          platformResults: const <FitUploadPlatformResult>[
            FitUploadPlatformResult(
              platform: FitUploadPlatform.strava,
              status: FitUploadPlatformStatus.success,
            ),
            FitUploadPlatformResult(
              platform: FitUploadPlatform.xingzhe,
              status: FitUploadPlatformStatus.failure,
              message: 'session expired',
            ),
          ],
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async =>
            _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
        coordinator: coordinator,
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'activity.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.partialSuccess);
      expect(result.message, '已上传到 Strava；行者上传失败：session expired');
    });

    test('returns success when all delegated uploads succeed', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-all-success-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: <FitUploadPlatform>[
            FitUploadPlatform.strava,
            FitUploadPlatform.xingzhe,
          ],
          hasMissingConfiguration: false,
          targetLabel: 'Strava 和 行者',
        ),
        result: FitUploadCoordinatorResult(
          status: FitUploadCoordinatorStatus.success,
          platformResults: const <FitUploadPlatformResult>[
            FitUploadPlatformResult(
              platform: FitUploadPlatform.strava,
              status: FitUploadPlatformStatus.success,
            ),
            FitUploadPlatformResult(
              platform: FitUploadPlatform.xingzhe,
              status: FitUploadPlatformStatus.success,
            ),
          ],
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async =>
            _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
        coordinator: coordinator,
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'activity.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.success);
      expect(result.message, 'FIT 文件已经上传到 Strava 和 行者。');
    });

    test(
      'returns success when all delegated uploads are already uploaded',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-already-uploaded-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[
              FitUploadPlatform.strava,
              FitUploadPlatform.xingzhe,
            ],
            hasMissingConfiguration: false,
            targetLabel: 'Strava 和 行者',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.success,
            platformResults: const <FitUploadPlatformResult>[
              FitUploadPlatformResult(
                platform: FitUploadPlatform.strava,
                status: FitUploadPlatformStatus.alreadyUploaded,
              ),
              FitUploadPlatformResult(
                platform: FitUploadPlatform.xingzhe,
                status: FitUploadPlatformStatus.alreadyUploaded,
              ),
            ],
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async =>
              _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
          coordinator: coordinator,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'activity.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.success);
        expect(result.message, 'FIT 文件已经上传到 Strava 和 行者。');
      },
    );

    test('returns failure when all delegated uploads fail', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-failure-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: <FitUploadPlatform>[
            FitUploadPlatform.strava,
            FitUploadPlatform.xingzhe,
          ],
          hasMissingConfiguration: false,
          targetLabel: 'Strava 和 行者',
        ),
        result: FitUploadCoordinatorResult(
          status: FitUploadCoordinatorStatus.failure,
          platformResults: const <FitUploadPlatformResult>[
            FitUploadPlatformResult(
              platform: FitUploadPlatform.strava,
              status: FitUploadPlatformStatus.failure,
              message: 'upload failed',
            ),
            FitUploadPlatformResult(
              platform: FitUploadPlatform.xingzhe,
              status: FitUploadPlatformStatus.failure,
              message: 'session expired',
            ),
          ],
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(),
        coordinator: coordinator,
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'activity.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.failure);
      expect(result.message, 'Strava上传失败：upload failed；行者上传失败：session expired');
    });

    test('persists one mixed-result sync record for partial success', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-history-partial-success-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStateStore stateStore = _FakeStateStore();
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: <FitUploadPlatform>[
            FitUploadPlatform.strava,
            FitUploadPlatform.xingzhe,
          ],
          hasMissingConfiguration: false,
          targetLabel: 'Strava 和 行者',
        ),
        result: FitUploadCoordinatorResult(
          status: FitUploadCoordinatorStatus.partialSuccess,
          platformResults: const <FitUploadPlatformResult>[
            FitUploadPlatformResult(
              platform: FitUploadPlatform.strava,
              status: FitUploadPlatformStatus.success,
              remoteActivityId: 42,
            ),
            FitUploadPlatformResult(
              platform: FitUploadPlatform.xingzhe,
              status: FitUploadPlatformStatus.failure,
              message: 'session expired',
            ),
          ],
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async =>
            _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
        coordinator: coordinator,
        stateStore: stateStore,
        loadFitSessionMeta: (_) async => const FitSessionMeta(
          startTime: '2026-04-01T02:03:04Z',
          distanceM: 12345,
          ascentM: 321,
          sport: 'cycling',
        ),
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'shared-activity.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.partialSuccess);
      expect(stateStore.savedBatches, hasLength(1));
      expect(stateStore.savedBatches.single, hasLength(1));

      final SyncRecord record = stateStore.savedBatches.single.single;
      expect(record.sourceFilename, 'shared-activity.fit');
      expect(record.fingerprint, isNotEmpty);
      expect(
        record.fingerprint,
        await makeFingerprint(
          fitFile,
          '2026-04-01T02:03:04Z',
          'shared-fit-upload',
        ),
      );
      expect(record.startTime, '2026-04-01T02:03:04Z');
      expect(record.distanceM, 12345);
      expect(record.ascentM, 321);
      expect(record.sport, 'cycling');
      expect(record.uploadedToStrava, isTrue);
      expect(record.uploadedToXingzhe, isTrue);
      expect(record.platformResults, hasLength(2));
      expect(record.platformResults[0].platform, SyncPlatform.strava);
      expect(record.platformResults[0].status, SyncStatus.success);
      expect(record.platformResults[0].remoteActivityId, 42);
      expect(record.platformResults[1].platform, SyncPlatform.xingzhe);
      expect(record.platformResults[1].status, SyncStatus.failed);
      expect(record.platformResults[1].errorMessage, 'session expired');
    });

    test(
      'ignores history persistence failure after a successful upload',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-save-success-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(
            result: FitUploadCoordinatorResult(
              status: FitUploadCoordinatorStatus.success,
              platformResults: const <FitUploadPlatformResult>[
                FitUploadPlatformResult(
                  platform: FitUploadPlatform.strava,
                  status: FitUploadPlatformStatus.success,
                ),
              ],
            ),
          ),
          stateStore: _FakeStateStore(error: Exception('history save failed')),
        );

        final SharedFitUploadResult result = await service.uploadDraft(
          SharedFitDraft(
            localFilePath: fitFile.path,
            displayName: 'history-save-success.fit',
          ),
        );

        expect(result.status, SharedFitUploadStatus.success);
        expect(result.message, 'FIT 文件已经上传到 Strava。');
      },
    );

    test('persists one failed sync record for full failure', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-history-failure-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStateStore stateStore = _FakeStateStore();
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: <FitUploadPlatform>[
            FitUploadPlatform.strava,
            FitUploadPlatform.xingzhe,
          ],
          hasMissingConfiguration: false,
          targetLabel: 'Strava 和 行者',
        ),
        result: FitUploadCoordinatorResult(
          status: FitUploadCoordinatorStatus.failure,
          platformResults: const <FitUploadPlatformResult>[
            FitUploadPlatformResult(
              platform: FitUploadPlatform.strava,
              status: FitUploadPlatformStatus.failure,
              message: 'upload failed',
            ),
            FitUploadPlatformResult(
              platform: FitUploadPlatform.xingzhe,
              status: FitUploadPlatformStatus.failure,
              message: 'session expired',
            ),
          ],
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async =>
            _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
        coordinator: coordinator,
        stateStore: stateStore,
        loadFitSessionMeta: (_) async =>
            const FitSessionMeta(startTime: '2026-04-02T03:04:05Z'),
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'failure.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.failure);
      expect(stateStore.savedBatches, hasLength(1));
      final SyncRecord record = stateStore.savedBatches.single.single;
      expect(record.sourceFilename, 'failure.fit');
      expect(record.fingerprint, isNotEmpty);
      expect(
        record.fingerprint,
        await makeFingerprint(
          fitFile,
          '2026-04-02T03:04:05Z',
          'shared-fit-upload',
        ),
      );
      expect(record.startTime, '2026-04-02T03:04:05Z');
      expect(record.uploadedToStrava, isTrue);
      expect(record.uploadedToXingzhe, isTrue);
      expect(
        record.platformResults.map(
          (PlatformSyncResult result) => result.status,
        ),
        <SyncStatus>[SyncStatus.failed, SyncStatus.failed],
      );
      expect(
        record.platformResults
            .map((PlatformSyncResult result) => result.errorMessage)
            .toList(),
        <String?>['upload failed', 'session expired'],
      );
    });

    test(
      'ignores history persistence failure after a partial upload',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-save-partial-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async =>
              _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
          coordinator: _FakeFitUploadCoordinator(
            plan: FitUploadPlan(
              targets: <FitUploadPlatform>[
                FitUploadPlatform.strava,
                FitUploadPlatform.xingzhe,
              ],
              hasMissingConfiguration: false,
              targetLabel: 'Strava 和 行者',
            ),
            result: FitUploadCoordinatorResult(
              status: FitUploadCoordinatorStatus.partialSuccess,
              platformResults: const <FitUploadPlatformResult>[
                FitUploadPlatformResult(
                  platform: FitUploadPlatform.strava,
                  status: FitUploadPlatformStatus.success,
                ),
                FitUploadPlatformResult(
                  platform: FitUploadPlatform.xingzhe,
                  status: FitUploadPlatformStatus.failure,
                  message: 'session expired',
                ),
              ],
            ),
          ),
          stateStore: _FakeStateStore(error: Exception('history save failed')),
        );

        final SharedFitUploadResult result = await service.uploadDraft(
          SharedFitDraft(
            localFilePath: fitFile.path,
            displayName: 'history-save-partial.fit',
          ),
        );

        expect(result.status, SharedFitUploadStatus.partialSuccess);
        expect(result.message, '已上传到 Strava；行者上传失败：session expired');
      },
    );

    test(
      'maps already uploaded platform results to deduped history status',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-deduped-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStateStore stateStore = _FakeStateStore();
        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[
              FitUploadPlatform.strava,
              FitUploadPlatform.xingzhe,
            ],
            hasMissingConfiguration: false,
            targetLabel: 'Strava 和 行者',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.success,
            platformResults: const <FitUploadPlatformResult>[
              FitUploadPlatformResult(
                platform: FitUploadPlatform.strava,
                status: FitUploadPlatformStatus.alreadyUploaded,
                message: 'duplicate of #123',
              ),
              FitUploadPlatformResult(
                platform: FitUploadPlatform.xingzhe,
                status: FitUploadPlatformStatus.success,
              ),
            ],
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async =>
              _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
          coordinator: coordinator,
          stateStore: stateStore,
          loadFitSessionMeta: (_) async =>
              const FitSessionMeta(startTime: '2026-04-03T04:05:06Z'),
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'already.fit',
        );

        await service.uploadDraft(draft);

        final SyncRecord record = stateStore.savedBatches.single.single;
        expect(record.platformResults[0].status, SyncStatus.deduped);
        expect(record.platformResults[0].errorMessage, isNull);
        expect(record.platformResults[1].status, SyncStatus.success);
      },
    );

    test('marks dedupe state after a shared upload succeeds', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-marks-dedupe-state-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStateStore stateStore = _FakeStateStore();
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async =>
            _settings(uploadToStrava: 'true', uploadToXingzhe: 'true'),
        coordinator: _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[
              FitUploadPlatform.strava,
              FitUploadPlatform.xingzhe,
            ],
            hasMissingConfiguration: false,
            targetLabel: 'Strava 和 行者',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.partialSuccess,
            platformResults: const <FitUploadPlatformResult>[
              FitUploadPlatformResult(
                platform: FitUploadPlatform.strava,
                status: FitUploadPlatformStatus.success,
                remoteActivityId: 456,
              ),
              FitUploadPlatformResult(
                platform: FitUploadPlatform.xingzhe,
                status: FitUploadPlatformStatus.alreadyUploaded,
              ),
            ],
          ),
        ),
        stateStore: stateStore,
        loadFitSessionMeta: (_) async => const FitSessionMeta(
          startTime: '2026-04-14T01:02:03Z',
          distanceM: 12345,
        ),
      );

      await service.uploadDraft(
        SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'dedupe-state.fit',
        ),
      );

      expect(stateStore.savedBatches, hasLength(1));
      final String fingerprint =
          stateStore.savedBatches.single.single.fingerprint;
      expect(stateStore.markedDedupeKeys, <String>[
        '2026-04-14T01:02:03Z_12345',
      ]);
      expect(stateStore.markedPlatformSyncs, <(String, String, int?)>[
        (fingerprint, 'strava', 456),
        (fingerprint, 'xingzhe', null),
      ]);
    });

    test('passes rewrite options through shared gcj correction flow', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-rewrite-options-',
      );
      final File fitFile = await _createFitFile(tempDir);
      final File rewrittenFitFile = await _createFitFile(
        tempDir,
        name: 'rewritten.fit',
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeFitCoordinateRewriteService rewriteService =
          _FakeFitCoordinateRewriteService(rewriteFile: rewrittenFitFile);
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(
          uploadToStrava: 'true',
          uploadToXingzhe: 'false',
          gcjCorrectionEnabled: 'true',
        ),
        rewriteService: rewriteService,
        coordinator: _FakeFitUploadCoordinator(),
        loadFitSessionMeta: (_) async =>
            const FitSessionMeta(startTime: '2026-04-15T06:07:08Z'),
      );

      await service.uploadDraft(
        SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'morning-ride.fit',
        ),
      );

      expect(rewriteService.receivedOptions, isNotNull);
      expect(rewriteService.receivedOptions!.startTime, '2026-04-15T06:07:08Z');
      expect(
        rewriteService.receivedOptions!.sourceFilename,
        'morning-ride.fit',
      );
    });

    test('does not persist history for missing configuration', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-history-missing-config-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStateStore stateStore = _FakeStateStore();
      final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
        plan: FitUploadPlan(
          targets: const <FitUploadPlatform>[],
          hasMissingConfiguration: true,
          targetLabel: '',
        ),
      );
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async =>
            _settings(uploadToStrava: 'false', uploadToXingzhe: 'false'),
        coordinator: coordinator,
        stateStore: stateStore,
      );

      final SharedFitDraft draft = SharedFitDraft(
        localFilePath: fitFile.path,
        displayName: 'missing-config.fit',
      );

      final SharedFitUploadResult result = await service.uploadDraft(draft);

      expect(result.status, SharedFitUploadStatus.missingConfiguration);
      expect(stateStore.savedBatches, isEmpty);
    });

    test(
      'does not persist history when the coordinator made no attempts',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-no-attempt-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStateStore stateStore = _FakeStateStore();
        final _FakeFitUploadCoordinator coordinator = _FakeFitUploadCoordinator(
          plan: FitUploadPlan(
            targets: <FitUploadPlatform>[FitUploadPlatform.strava],
            hasMissingConfiguration: false,
            targetLabel: 'Strava',
          ),
          result: FitUploadCoordinatorResult(
            status: FitUploadCoordinatorStatus.failure,
            platformResults: const <FitUploadPlatformResult>[],
          ),
        );
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: coordinator,
          stateStore: stateStore,
        );

        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'no-attempt.fit',
        );

        final SharedFitUploadResult result = await service.uploadDraft(draft);

        expect(result.status, SharedFitUploadStatus.failure);
        expect(stateStore.savedBatches, isEmpty);
      },
    );

    test(
      'uses a user-safe persisted startTime when metadata parsing fails',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-fallback-start-time-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStateStore stateStore = _FakeStateStore();
        final _FakeFitUploadCoordinator coordinator =
            _FakeFitUploadCoordinator();
        final DateTime completionTime = DateTime.parse('2026-04-09T10:11:12Z');
        final SharedFitUploadService service = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: coordinator,
          stateStore: stateStore,
          loadFitSessionMeta: (_) async => throw Exception('parse failed'),
          now: () => completionTime,
        );
        final SharedFitDraft draft = SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'stable-history.fit',
        );

        await service.uploadDraft(draft);
        await service.uploadDraft(draft);

        expect(stateStore.savedBatches, hasLength(2));
        final String firstStartTime =
            stateStore.savedBatches[0].single.startTime;
        final String secondStartTime =
            stateStore.savedBatches[1].single.startTime;
        expect(firstStartTime, isNotEmpty);
        expect(secondStartTime, isNotEmpty);
        expect(firstStartTime, isNot(draft.localFilePath));
        expect(secondStartTime, isNot(draft.localFilePath));
        expect(secondStartTime, firstStartTime);
        expect(firstStartTime, isNot(draft.displayName));
        expect(DateTime.tryParse(firstStartTime), completionTime);
        expect(firstStartTime.startsWith('1970-'), isFalse);
        expect(stateStore.savedBatches[0].single.fingerprint, isNotEmpty);
      },
    );

    test(
      'uses the same fingerprint for the same fit shared under different names',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-fingerprint-same-fit-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStateStore firstStateStore = _FakeStateStore();
        final _FakeStateStore secondStateStore = _FakeStateStore();

        final SharedFitUploadService firstService = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(),
          stateStore: firstStateStore,
          loadFitSessionMeta: (_) async =>
              const FitSessionMeta(startTime: '2026-04-05T06:07:08Z'),
        );
        final SharedFitUploadService secondService = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(),
          stateStore: secondStateStore,
          loadFitSessionMeta: (_) async =>
              const FitSessionMeta(startTime: '2026-04-05T06:07:08Z'),
        );

        await firstService.uploadDraft(
          SharedFitDraft(
            localFilePath: fitFile.path,
            displayName: 'morning-ride.fit',
          ),
        );
        await secondService.uploadDraft(
          SharedFitDraft(
            localFilePath: fitFile.path,
            displayName: 'renamed-ride.fit',
          ),
        );

        final SyncRecord firstRecord =
            firstStateStore.savedBatches.single.single;
        final SyncRecord secondRecord =
            secondStateStore.savedBatches.single.single;
        expect(firstRecord.fingerprint, isNotEmpty);
        expect(secondRecord.fingerprint, isNotEmpty);
        expect(secondRecord.fingerprint, firstRecord.fingerprint);
      },
    );

    test(
      'keeps fallback fingerprint and startTime stable for the same fit across different local paths when metadata is unavailable',
      () async {
        final Directory firstTempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-fingerprint-fallback-stable-a-',
        );
        final Directory secondTempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-fingerprint-fallback-stable-b-',
        );
        final File firstFitFile = await _createFitFile(firstTempDir);
        final File secondFitFile = await _createFitFile(secondTempDir);
        await secondFitFile.writeAsBytes(await firstFitFile.readAsBytes());

        addTearDown(() async {
          if (await firstTempDir.exists()) {
            await firstTempDir.delete(recursive: true);
          }
          if (await secondTempDir.exists()) {
            await secondTempDir.delete(recursive: true);
          }
        });

        final _FakeStateStore firstStateStore = _FakeStateStore();
        final _FakeStateStore secondStateStore = _FakeStateStore();
        final DateTime completionTime = DateTime.parse('2026-04-10T11:12:13Z');

        final SharedFitUploadService firstService = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(),
          stateStore: firstStateStore,
          loadFitSessionMeta: (_) async => throw Exception('parse failed'),
          now: () => completionTime,
        );
        final SharedFitUploadService secondService = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(),
          stateStore: secondStateStore,
          loadFitSessionMeta: (_) async => throw Exception('parse failed'),
          now: () => completionTime,
        );

        await firstService.uploadDraft(
          SharedFitDraft(
            localFilePath: firstFitFile.path,
            displayName: 'retry-a.fit',
          ),
        );
        await secondService.uploadDraft(
          SharedFitDraft(
            localFilePath: secondFitFile.path,
            displayName: 'retry-b.fit',
          ),
        );

        final SyncRecord firstRecord =
            firstStateStore.savedBatches.single.single;
        final SyncRecord secondRecord =
            secondStateStore.savedBatches.single.single;
        expect(firstRecord.startTime, isNotEmpty);
        expect(DateTime.tryParse(firstRecord.startTime), completionTime);
        expect(DateTime.tryParse(secondRecord.startTime), completionTime);
        expect(firstRecord.startTime, isNot('retry-a.fit'));
        expect(secondRecord.startTime, isNot('retry-b.fit'));
        expect(secondRecord.startTime, firstRecord.startTime);
        expect(firstRecord.fingerprint, isNotEmpty);
        expect(secondRecord.fingerprint, firstRecord.fingerprint);
      },
    );

    test(
      'keeps the first persisted fallback startTime when retrying the same fit later',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-first-start-time-',
        );
        final File fitFile = await _createFitFile(tempDir);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final _FakeStateStore stateStore = _FakeStateStore();
        final DateTime firstCompletionTime = DateTime.parse(
          '2026-04-12T13:14:15Z',
        );
        final DateTime secondCompletionTime = DateTime.parse(
          '2026-04-13T14:15:16Z',
        );

        final SharedFitUploadService firstService = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(),
          stateStore: stateStore,
          loadFitSessionMeta: (_) async => throw Exception('parse failed'),
          now: () => firstCompletionTime,
        );
        final SharedFitUploadService secondService = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(),
          stateStore: stateStore,
          loadFitSessionMeta: (_) async => throw Exception('parse failed'),
          now: () => secondCompletionTime,
        );

        await firstService.uploadDraft(
          SharedFitDraft(
            localFilePath: fitFile.path,
            displayName: 'first-attempt.fit',
          ),
        );
        await secondService.uploadDraft(
          SharedFitDraft(
            localFilePath: fitFile.path,
            displayName: 'second-attempt.fit',
          ),
        );

        expect(stateStore.savedBatches, hasLength(2));
        final SyncRecord firstSaved = stateStore.savedBatches[0].single;
        final SyncRecord secondSaved = stateStore.savedBatches[1].single;
        expect(firstSaved.startTime, '2026-04-12T13:14:15Z');
        expect(secondSaved.fingerprint, firstSaved.fingerprint);
        expect(secondSaved.startTime, firstSaved.startTime);
      },
    );

    test(
      'falls back to a stable non-empty fingerprint when the primary fingerprint helper throws',
      () async {
        final Directory firstTempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-fingerprint-failure-a-',
        );
        final Directory secondTempDir = await Directory.systemTemp.createTemp(
          'shared-fit-upload-history-fingerprint-failure-b-',
        );
        final File firstFitFile = await _createFitFile(firstTempDir);
        final File secondFitFile = await _createFitFile(secondTempDir);
        await secondFitFile.writeAsBytes(await firstFitFile.readAsBytes());

        addTearDown(() async {
          if (await firstTempDir.exists()) {
            await firstTempDir.delete(recursive: true);
          }
          if (await secondTempDir.exists()) {
            await secondTempDir.delete(recursive: true);
          }
        });

        final _FakeStateStore firstStateStore = _FakeStateStore();
        final _FakeStateStore secondStateStore = _FakeStateStore();
        final DateTime completionTime = DateTime.parse('2026-04-11T12:13:14Z');
        final SharedFitUploadService firstService = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(),
          stateStore: firstStateStore,
          loadFitSessionMeta: (_) async => throw Exception('parse failed'),
          now: () => completionTime,
          makeHistoryFingerprint: (file, startTime, recordKey) async {
            throw FileSystemException('read failed');
          },
        );
        final SharedFitUploadService secondService = SharedFitUploadService(
          loadSettings: () async => _settings(uploadToXingzhe: 'false'),
          coordinator: _FakeFitUploadCoordinator(),
          stateStore: secondStateStore,
          loadFitSessionMeta: (_) async => throw Exception('parse failed'),
          now: () => completionTime,
          makeHistoryFingerprint: (file, startTime, recordKey) async {
            throw FileSystemException('read failed');
          },
        );

        await firstService.uploadDraft(
          SharedFitDraft(
            localFilePath: firstFitFile.path,
            displayName: 'fingerprint-failure-a.fit',
          ),
        );
        await secondService.uploadDraft(
          SharedFitDraft(
            localFilePath: secondFitFile.path,
            displayName: 'fingerprint-failure-b.fit',
          ),
        );

        final SyncRecord firstRecord =
            firstStateStore.savedBatches.single.single;
        final SyncRecord secondRecord =
            secondStateStore.savedBatches.single.single;
        expect(firstRecord.fingerprint, isNotEmpty);
        expect(secondRecord.fingerprint, firstRecord.fingerprint);
        expect(DateTime.tryParse(firstRecord.startTime), completionTime);
        expect(DateTime.tryParse(secondRecord.startTime), completionTime);
        expect(firstRecord.startTime, isNot('fingerprint-failure-a.fit'));
        expect(secondRecord.startTime, isNot('fingerprint-failure-b.fit'));
        expect(firstRecord.startTime, secondRecord.startTime);
      },
    );

    test('does not persist history when all fingerprint paths fail', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'shared-fit-upload-history-fingerprint-all-fail-',
      );
      final File fitFile = await _createFitFile(tempDir);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final _FakeStateStore stateStore = _FakeStateStore();
      final SharedFitUploadService service = SharedFitUploadService(
        loadSettings: () async => _settings(uploadToXingzhe: 'false'),
        coordinator: _FakeFitUploadCoordinator(),
        stateStore: stateStore,
        loadFitSessionMeta: (_) async =>
            const FitSessionMeta(startTime: '2026-04-08T09:10:11Z'),
        makeHistoryFingerprint: (file, startTime, recordKey) async {
          throw FileSystemException('read failed');
        },
        fallbackHistoryFingerprint: (file, startTime, recordKey) async {
          throw FileSystemException('fallback read failed');
        },
      );

      final SharedFitUploadResult result = await service.uploadDraft(
        SharedFitDraft(
          localFilePath: fitFile.path,
          displayName: 'fingerprint-all-fail.fit',
        ),
      );

      expect(result.status, SharedFitUploadStatus.success);
      expect(result.message, 'FIT 文件已经上传到 Strava。');
      expect(stateStore.savedBatches, isEmpty);
    });
  });
}
