import 'dart:io';

import 'package:fit_tool/fit_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/services/coordinate_converter.dart';
import 'package:onelap_strava_sync/services/fit_coordinate_rewrite_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseFitSessionMeta', () {
    test('returns session start time when present', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fit-session-meta-start-time-',
      );
      final File fitFile = File('${tempDir.path}/input.fit');
      final DateTime expectedStartTime = DateTime.utc(2026, 4, 11, 6, 30, 45);

      await fitFile.writeAsBytes(
        _buildFitBytes(<Message>[
          _sessionMessage(startTime: expectedStartTime),
        ]),
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final FitSessionMeta meta = await parseFitSessionMeta(fitFile);

      expect(
        meta.startTime,
        expectedStartTime.toIso8601String().replaceFirst(RegExp(r'\.\d+'), ''),
      );
    });

    test(
      'does not use session timestamp as start time when start time is absent',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'fit-session-meta-no-timestamp-fallback-',
        );
        final File fitFile = File('${tempDir.path}/input.fit');
        final DateTime sessionTimestamp = DateTime.utc(2026, 4, 11, 7, 45, 12);

        await fitFile.writeAsBytes(
          _buildFitBytes(<Message>[
            _sessionMessage(
              timestamp: sessionTimestamp,
              includeStartTime: false,
            ),
          ]),
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final FitSessionMeta meta = await parseFitSessionMeta(fitFile);

        expect(meta.startTime, isNull);
      },
    );
  });

  group('FitCoordinateRewriteService.rewrite', () {
    test('rewrites RecordMessage position coordinates', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fit-coordinate-rewrite-record-',
      );
      final File inputFile = File('${tempDir.path}/input.fit');
      await inputFile.writeAsBytes(
        _buildFitBytes(<Message>[
          _recordMessage(latitude: 39.915, longitude: 116.404),
        ]),
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final FitCoordinateRewriteService service = FitCoordinateRewriteService(
        loadCacheDirectory: () async => tempDir,
      );

      final File outputFile = await service.rewrite(inputFile);
      final FitFile fitFile = FitFile.fromBytes(await outputFile.readAsBytes());
      final RecordMessage record = _singleRecordMessage(fitFile);
      final (double expectedLatitude, double expectedLongitude) =
          _expectedConvertedCoordinatePair(39.915, 116.404);

      expect(record.positionLat, expectedLatitude);
      expect(record.positionLong, expectedLongitude);
      expect(fitFile.crc, isNotNull);
    });

    test('preserves null targeted coordinates', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fit-coordinate-rewrite-null-',
      );
      final File inputFile = File('${tempDir.path}/input.fit');
      await inputFile.writeAsBytes(
        _buildFitBytes(<Message>[
          _recordMessage(latitude: null, longitude: 116.404),
        ]),
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final FitCoordinateRewriteService service = FitCoordinateRewriteService(
        loadCacheDirectory: () async => tempDir,
      );

      final File outputFile = await service.rewrite(inputFile);
      final FitFile fitFile = FitFile.fromBytes(await outputFile.readAsBytes());
      final RecordMessage record = _singleRecordMessage(fitFile);

      expect(record.positionLat, isNull);
      expect(record.positionLong, _roundToFitCoordinatePrecision(116.404));
    });

    test('rewrites LapMessage start and end coordinates', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fit-coordinate-rewrite-lap-',
      );
      final File inputFile = File('${tempDir.path}/input.fit');
      await inputFile.writeAsBytes(
        _buildFitBytes(<Message>[
          _lapMessage(
            startLatitude: 39.915,
            startLongitude: 116.404,
            endLatitude: 39.925,
            endLongitude: 116.414,
          ),
        ]),
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final FitCoordinateRewriteService service = FitCoordinateRewriteService(
        loadCacheDirectory: () async => tempDir,
      );

      final File outputFile = await service.rewrite(inputFile);
      final FitFile fitFile = FitFile.fromBytes(await outputFile.readAsBytes());
      final LapMessage lap = _singleLapMessage(fitFile);
      final (double expectedStartLatitude, double expectedStartLongitude) =
          _expectedConvertedCoordinatePair(39.915, 116.404);
      final (double expectedEndLatitude, double expectedEndLongitude) =
          _expectedConvertedCoordinatePair(39.925, 116.414);

      expect(lap.startPositionLat, expectedStartLatitude);
      expect(lap.startPositionLong, expectedStartLongitude);
      expect(lap.endPositionLat, expectedEndLatitude);
      expect(lap.endPositionLong, expectedEndLongitude);
    });

    test('rewrites SessionMessage targeted coordinates', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fit-coordinate-rewrite-session-',
      );
      final File inputFile = File('${tempDir.path}/input.fit');
      await inputFile.writeAsBytes(
        _buildFitBytes(<Message>[
          _sessionMessage(
            startLatitude: 39.915,
            startLongitude: 116.404,
            necLatitude: 39.925,
            necLongitude: 116.414,
            swcLatitude: 39.905,
            swcLongitude: 116.394,
          ),
        ]),
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final FitCoordinateRewriteService service = FitCoordinateRewriteService(
        loadCacheDirectory: () async => tempDir,
      );

      final File outputFile = await service.rewrite(inputFile);
      final FitFile fitFile = FitFile.fromBytes(await outputFile.readAsBytes());
      final SessionMessage session = _singleSessionMessage(fitFile);
      final (double expectedStartLatitude, double expectedStartLongitude) =
          _expectedConvertedCoordinatePair(39.915, 116.404);
      final (double expectedNecLatitude, double expectedNecLongitude) =
          _expectedConvertedCoordinatePair(39.925, 116.414);
      final (double expectedSwcLatitude, double expectedSwcLongitude) =
          _expectedConvertedCoordinatePair(39.905, 116.394);

      expect(session.startPositionLat, expectedStartLatitude);
      expect(session.startPositionLong, expectedStartLongitude);
      expect(session.necLat, expectedNecLatitude);
      expect(session.necLong, expectedNecLongitude);
      expect(session.swcLat, expectedSwcLatitude);
      expect(session.swcLong, expectedSwcLongitude);
    });

    test(
      'preserves the original value when conversion would produce an invalid coordinate',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'fit-coordinate-rewrite-invalid-',
        );
        final File inputFile = File('${tempDir.path}/input.fit');
        await inputFile.writeAsBytes(
          _buildFitBytes(<Message>[
            _recordMessage(latitude: 95.0, longitude: 116.404),
          ]),
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final FitCoordinateRewriteService service = FitCoordinateRewriteService(
          loadCacheDirectory: () async => tempDir,
        );

        final File outputFile = await service.rewrite(inputFile);
        final FitFile fitFile = FitFile.fromBytes(
          await outputFile.readAsBytes(),
        );
        final RecordMessage record = _singleRecordMessage(fitFile);

        expect(record.positionLat, _roundToFitCoordinatePrecision(95.0));
        expect(record.positionLong, _roundToFitCoordinatePrecision(116.404));
      },
    );

    test('succeeds when no targeted coordinate fields are present', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fit-coordinate-rewrite-untargeted-',
      );
      final File inputFile = File('${tempDir.path}/input.fit');
      await inputFile.writeAsBytes(
        _buildFitBytes(<Message>[_recordMessage(heartRate: 150)]),
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final FitCoordinateRewriteService service = FitCoordinateRewriteService(
        loadCacheDirectory: () async => tempDir,
      );

      final File outputFile = await service.rewrite(inputFile);
      final FitFile fitFile = FitFile.fromBytes(await outputFile.readAsBytes());
      final RecordMessage record = _singleRecordMessage(fitFile);

      expect(record.heartRate, 150);
      expect(outputFile.path, isNot(inputFile.path));
    });

    test('names the rewritten file after the source filename', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fit-coordinate-rewrite-filename-',
      );
      final File inputFile = File('${tempDir.path}/input.fit');
      await inputFile.writeAsBytes(
        _buildFitBytes(<Message>[
          _recordMessage(latitude: 39.915, longitude: 116.404),
        ]),
      );

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final FitCoordinateRewriteService service = FitCoordinateRewriteService(
        loadCacheDirectory: () async => tempDir,
      );

      final File outputFile = await service.rewrite(
        inputFile,
        options: const RewriteOptions(
          startTime: '2026-04-15T06:07:08Z',
          sourceFilename: 'morning ride.fit',
        ),
      );

      expect(outputFile.uri.pathSegments.last, 'morning ride.fit');
    });

    test(
      'falls back to the start date when no source filename is given',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'fit-coordinate-rewrite-filename-date-',
        );
        final File inputFile = File('${tempDir.path}/input.fit');
        await inputFile.writeAsBytes(
          _buildFitBytes(<Message>[
            _recordMessage(latitude: 39.915, longitude: 116.404),
          ]),
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final FitCoordinateRewriteService service = FitCoordinateRewriteService(
          loadCacheDirectory: () async => tempDir,
        );

        final File outputFile = await service.rewrite(
          inputFile,
          options: const RewriteOptions(startTime: '2026-04-15T06:07:08Z'),
        );

        expect(outputFile.uri.pathSegments.last, '2026-04-15.fit');
      },
    );

    test(
      'creates a unique .fit output path in the application cache directory',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'fit-coordinate-rewrite-output-',
        );
        final File inputFile = File('${tempDir.path}/input.fit');
        await inputFile.writeAsBytes(
          _buildFitBytes(<Message>[
            _recordMessage(latitude: 39.915, longitude: 116.404),
          ]),
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final FitCoordinateRewriteService service = FitCoordinateRewriteService(
          loadCacheDirectory: () async => tempDir,
        );

        final File firstOutput = await service.rewrite(inputFile);
        final File secondOutput = await service.rewrite(inputFile);

        expect(firstOutput.path, startsWith(tempDir.path));
        expect(secondOutput.path, startsWith(tempDir.path));
        expect(firstOutput.path, endsWith('.fit'));
        expect(secondOutput.path, endsWith('.fit'));
        expect(secondOutput.path, isNot(firstOutput.path));
        expect(await firstOutput.exists(), isTrue);
        expect(await secondOutput.exists(), isTrue);
      },
    );

    test('throws for file smaller than FIT header minimum', () async {
      final tempDir = await Directory.systemTemp.createTemp('fit-header-');
      final tinyFile = File('${tempDir.path}/tiny.fit');
      await tinyFile.writeAsBytes(<int>[1, 2, 3]); // only 3 bytes

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final service = FitCoordinateRewriteService(
        loadCacheDirectory: () async => tempDir,
      );

      expect(() => service.rewrite(tinyFile), throwsA(isA<Exception>()));
    });

    test(
      'creates collision-safe .fit outputs for concurrent rewrites',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'fit-coordinate-rewrite-concurrent-',
        );
        final File inputFile = File('${tempDir.path}/input.fit');
        await inputFile.writeAsBytes(
          _buildFitBytes(<Message>[
            _recordMessage(latitude: 39.915, longitude: 116.404),
          ]),
        );

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final FitCoordinateRewriteService service = FitCoordinateRewriteService(
          loadCacheDirectory: () async => tempDir,
        );

        final List<File> outputs = await Future.wait<File>(<Future<File>>[
          service.rewrite(inputFile),
          service.rewrite(inputFile),
        ]);

        expect(outputs, hasLength(2));
        expect(outputs[0].path, isNot(outputs[1].path));
        expect(outputs[0].path, startsWith(tempDir.path));
        expect(outputs[1].path, startsWith(tempDir.path));
        expect(outputs[0].path, endsWith('.fit'));
        expect(outputs[1].path, endsWith('.fit'));
        expect(outputs[0].parent.path, isNot(outputs[1].parent.path));
        expect(outputs[0].parent.path, isNot(tempDir.path));
        expect(outputs[1].parent.path, isNot(tempDir.path));
        expect(await outputs[0].exists(), isTrue);
        expect(await outputs[1].exists(), isTrue);
      },
    );
  });
}

List<int> _buildFitBytes(List<Message> messages) {
  final FitFileBuilder builder = FitFileBuilder();
  builder.addAll(messages);
  return builder.build().toBytes();
}

RecordMessage _recordMessage({
  double? latitude,
  double? longitude,
  int? heartRate,
}) {
  final RecordMessage message = RecordMessage();
  message.timestamp = DateTime.utc(2026, 4, 11).millisecondsSinceEpoch;
  if (latitude != null) {
    message.positionLat = latitude;
  }
  if (longitude != null) {
    message.positionLong = longitude;
  }
  if (heartRate != null) {
    message.heartRate = heartRate;
  }
  return message;
}

LapMessage _lapMessage({
  double? startLatitude,
  double? startLongitude,
  double? endLatitude,
  double? endLongitude,
}) {
  final LapMessage message = LapMessage();
  message.timestamp = DateTime.utc(2026, 4, 11, 0, 1).millisecondsSinceEpoch;
  message.startTime = DateTime.utc(2026, 4, 11).millisecondsSinceEpoch;
  if (startLatitude != null) {
    message.startPositionLat = startLatitude;
  }
  if (startLongitude != null) {
    message.startPositionLong = startLongitude;
  }
  if (endLatitude != null) {
    message.endPositionLat = endLatitude;
  }
  if (endLongitude != null) {
    message.endPositionLong = endLongitude;
  }
  return message;
}

SessionMessage _sessionMessage({
  DateTime? timestamp,
  DateTime? startTime,
  bool includeStartTime = true,
  double? startLatitude,
  double? startLongitude,
  double? necLatitude,
  double? necLongitude,
  double? swcLatitude,
  double? swcLongitude,
}) {
  final SessionMessage message = SessionMessage();
  message.timestamp =
      (timestamp ?? DateTime.utc(2026, 4, 11, 0, 2)).millisecondsSinceEpoch;
  if (includeStartTime) {
    message.startTime =
        (startTime ?? DateTime.utc(2026, 4, 11)).millisecondsSinceEpoch;
  }
  if (startLatitude != null) {
    message.startPositionLat = startLatitude;
  }
  if (startLongitude != null) {
    message.startPositionLong = startLongitude;
  }
  if (necLatitude != null) {
    message.necLat = necLatitude;
  }
  if (necLongitude != null) {
    message.necLong = necLongitude;
  }
  if (swcLatitude != null) {
    message.swcLat = swcLatitude;
  }
  if (swcLongitude != null) {
    message.swcLong = swcLongitude;
  }
  return message;
}

double _roundToFitCoordinatePrecision(double value) {
  final int semicircles = (value * 2147483648 / 180.0).round();
  return semicircles * 180.0 / 2147483648;
}

RecordMessage _singleRecordMessage(FitFile fitFile) {
  return fitFile.records
      .map((Record record) => record.message)
      .whereType<RecordMessage>()
      .single;
}

LapMessage _singleLapMessage(FitFile fitFile) {
  return fitFile.records
      .map((Record record) => record.message)
      .whereType<LapMessage>()
      .single;
}

SessionMessage _singleSessionMessage(FitFile fitFile) {
  return fitFile.records
      .map((Record record) => record.message)
      .whereType<SessionMessage>()
      .single;
}

(double, double) _expectedConvertedCoordinatePair(
  double latitude,
  double longitude,
) {
  final double storedLatitude = _roundToFitCoordinatePrecision(latitude);
  final double storedLongitude = _roundToFitCoordinatePrecision(longitude);
  final (double convertedLatitude, double convertedLongitude) =
      CoordinateConverter.gcj02ToWgs84Exact(storedLatitude, storedLongitude);
  return (
    _roundToFitCoordinatePrecision(convertedLatitude),
    _roundToFitCoordinatePrecision(convertedLongitude),
  );
}
