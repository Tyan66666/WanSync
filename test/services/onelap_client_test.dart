import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/models/onelap_activity.dart';
import 'package:onelap_strava_sync/services/onelap_client.dart';

class _FakeHttpClientAdapter implements HttpClientAdapter {
  _FakeHttpClientAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }
}

class _DownloadRoute {
  _DownloadRoute({required this.statusCode, this.bytes});

  final int statusCode;
  final List<int>? bytes;
}

List<int> _validFitBytes(List<int> payload) {
  final header = <int>[
    0x0E,
    0x10,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x2E,
    0x46,
    0x49,
    0x54,
    0x00,
    0x00,
  ];
  return [...header, ...payload];
}

void main() {
  group('OneLapActivity', () {
    test(
      'stores recordId on OneLapActivity without affecting legacy fields',
      () {
        const OneLapActivity activity = OneLapActivity(
          activityId: '1',
          startTime: '2026-03-29T10:00:00',
          fitUrl: 'geo/20260329/file.fit',
          recordKey: 'fileKey:geo/20260329/file.fit',
          sourceFilename: 'file.fit',
          recordId: 'record-123',
          rawFitUrl: 'geo/20260329/file.fit',
          rawDurl: 'http://fits.rfsvr.net/file.fit?token=abc',
          rawFileKey: 'geo/20260329/file.fit',
        );

        expect(activity.recordId, 'record-123');
        expect(activity.activityId, '1');
        expect(activity.startTime, '2026-03-29T10:00:00');
        expect(activity.fitUrl, 'geo/20260329/file.fit');
        expect(activity.recordKey, 'fileKey:geo/20260329/file.fit');
        expect(activity.sourceFilename, 'file.fit');
        expect(activity.rawFitUrl, 'geo/20260329/file.fit');
        expect(activity.rawDurl, 'http://fits.rfsvr.net/file.fit?token=abc');
        expect(activity.rawFileKey, 'geo/20260329/file.fit');
      },
    );

    test('stores distanceKm and timeSeconds when provided', () {
      const OneLapActivity activity = OneLapActivity(
        activityId: '1',
        startTime: '2026-03-29T10:00:00',
        fitUrl: 'geo/20260329/file.fit',
        recordKey: 'fileKey:geo/20260329/file.fit',
        sourceFilename: 'file.fit',
        distanceKm: 42.5,
        timeSeconds: 5400,
      );

      expect(activity.distanceKm, 42.5);
      expect(activity.timeSeconds, 5400);
    });

    test('distanceKm and timeSeconds default to null', () {
      const OneLapActivity activity = OneLapActivity(
        activityId: '1',
        startTime: '2026-03-29T10:00:00',
        fitUrl: 'geo/20260329/file.fit',
        recordKey: 'fileKey:geo/20260329/file.fit',
        sourceFilename: 'file.fit',
      );

      expect(activity.distanceKm, isNull);
      expect(activity.timeSeconds, isNull);
    });
  });

  group('OneLapClient.login', () {
    test(
      'caches token and refresh token for subsequent authenticated requests',
      () async {
        int loginRequests = 0;
        final Map<String, Object?> authHeadersByUrl = <String, Object?>{};
        const String otmFitPath =
            'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
        const String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          authHeadersByUrl[url] = options.headers['Authorization'];

          if (url == 'http://example.com/api/login') {
            loginRequests++;
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'cached-token-123',
                  'refresh_token': 'cached-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/geo/20260329/wrong.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[4, 5, 6, 7],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-login-cache-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await client.login();

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        expect(loginRequests, 1);
        expect(authHeadersByUrl[otmFitContentUrl], 'cached-token-123');
        expect(await downloaded.readAsBytes(), <int>[4, 5, 6, 7]);
      },
    );

    test('downloads bare OTM fileKey through fit_content fallback', () async {
      const String bareFileKey = 'ONELAP_677767-2026-10-18-20-33-08.st';
      final String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          '${base64Encode(utf8.encode(bareFileKey))}';
      final List<int> fitBytes = _validFitBytes(<int>[1, 2, 3, 4]);
      final List<String> requestedUrls = <String>[];

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();
        requestedUrls.add(url);
        if (url == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'token': 'bare-token-123',
                'refresh_token': 'bare-refresh-456',
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }
        if (url == otmFitContentUrl) {
          return ResponseBody.fromBytes(
            fitBytes,
            HttpStatus.ok,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }
        return ResponseBody.fromString('not found', HttpStatus.notFound);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-bare-filekey-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final File downloaded = await client.downloadFit(
        'ONELAP_677767-2026-10-18-20-33-08.st',
        'demo.fit',
        outputDir,
        activity: const OneLapActivity(
          activityId: '6ad4bc85a28dc842fe23e338',
          startTime: '2026-10-18 19:02:33',
          fitUrl: 'ONELAP_677767-2026-10-18-20-33-08.st',
          recordKey: 'fileKey:ONELAP_677767-2026-10-18-20-33-08.st',
          sourceFilename: 'demo.fit',
          rawFitUrl: 'ONELAP_677767-2026-10-18-20-33-08.st',
          rawDurl:
              'http://fits.rfsvr.net/ONELAP_677767-2026-10-18-20-33-08.st?e=1&token=abc',
          rawFileKey: 'ONELAP_677767-2026-10-18-20-33-08.st',
        ),
      );

      expect(requestedUrls, contains(otmFitContentUrl));
      expect(await downloaded.readAsBytes(), fitBytes);
    });

    test(
      'still accepts OneLap success code 0 when token fields are present',
      () async {
        int loginRequests = 0;
        final Map<String, Object?> authHeadersByUrl = <String, Object?>{};
        const String otmFitPath =
            'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
        const String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          authHeadersByUrl[url] = options.headers['Authorization'];

          if (url == 'http://example.com/api/login') {
            loginRequests++;
            return ResponseBody.fromString(
              jsonEncode({
                'code': 0,
                'data': {
                  'token': 'cached-token-123',
                  'refresh_token': 'cached-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/geo/20260329/wrong.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[8, 9, 10],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-login-code-zero-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await client.login();

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        expect(loginRequests, 1);
        expect(authHeadersByUrl[otmFitContentUrl], 'cached-token-123');
        expect(await downloaded.readAsBytes(), <int>[8, 9, 10]);
      },
    );

    test('fails when OneLap response omits required token fields', () async {
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.toString() == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'token': 'cached-token-123'},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }
        return ResponseBody.fromString('not found', 404);
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      await expectLater(
        client.login(),
        throwsA(
          isA<Exception>().having(
            (Exception error) => error.toString(),
            'message',
            contains('missing token fields'),
          ),
        ),
      );
    });

    test('accepts legacy list-shaped login payload with token fields', () async {
      int loginRequests = 0;
      final Map<String, Object?> authHeadersByUrl = <String, Object?>{};
      const String otmFitPath =
          'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
      const String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();
        authHeadersByUrl[url] = options.headers['Authorization'];

        if (url == 'http://example.com/api/login') {
          loginRequests++;
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': [
                {
                  'token': 'legacy-token-123',
                  'refresh_token': 'legacy-refresh-456',
                },
              ],
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
            url == 'http://example.com/geo/20260329/wrong.fit' ||
            url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.notFound,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        if (url == otmFitContentUrl) {
          return ResponseBody.fromBytes(
            <int>[1, 2, 3, 4],
            HttpStatus.ok,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-login-legacy-list-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      await client.login();

      final File downloaded = await client.downloadFit(
        'http://fits.rfsvr.net/correct.fit?token=abc',
        'demo.fit',
        outputDir,
        activity: const OneLapActivity(
          activityId: '93825',
          startTime: '2026-03-31T15:21:16',
          fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          recordKey:
              'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
          sourceFilename: 'demo.fit',
          rawFitUrl: 'geo/20260329/wrong.fit',
          rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          rawFileKey: otmFitPath,
        ),
      );

      expect(loginRequests, 1);
      expect(authHeadersByUrl[otmFitContentUrl], 'legacy-token-123');
      expect(await downloaded.readAsBytes(), <int>[1, 2, 3, 4]);
    });
  });

  group('OneLapClient.listFitActivities', () {
    test(
      'lists recent activities from the token-backed OTM record API and enriches recordKey from detail',
      () async {
        final List<String> requests = <String>[];
        final List<Object?> otmAuthHeaders = <Object?>[];
        final List<String> requestBodies = <String>[];

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add('${options.method} $url');

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            otmAuthHeaders.add(options.headers['Authorization']);
            requestBodies.add(jsonEncode(options.data));
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 321,
                      'name': 'Morning Ride',
                      'start_riding_time': '2026-03-28T10:00:00',
                      'durl': 'http://fits.rfsvr.net/recent.fit?token=abc',
                    },
                    {
                      'id': 111,
                      'start_riding_time': '2026-03-24T10:00:00',
                      'durl': 'http://fits.rfsvr.net/older.fit?token=def',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/321') {
            otmAuthHeaders.add(options.headers['Authorization']);
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'fileKey': 'geo/20260328/recent.fit',
                  'fit_url': 'geo/20260328/recent-alt.fit',
                  'durl': 'http://fits.rfsvr.net/detail.fit?token=abc',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
        );

        expect(activities, hasLength(1));
        expect(
          requests,
          contains('POST https://otm.onelap.cn/api/otm/ride_record/list'),
        );
        expect(
          requests,
          contains(
            'GET https://otm.onelap.cn/api/otm/ride_record/analysis/321',
          ),
        );
        expect(otmAuthHeaders, everyElement('otm-token-123'));
        expect(requestBodies, <String>['{"page":1,"limit":50}']);
        expect(activities.single.activityId, '321');
        expect(activities.single.recordId, '321');
        expect(activities.single.startTime, '2026-03-28T10:00:00');
        expect(
          activities.single.fitUrl,
          'http://fits.rfsvr.net/detail.fit?token=abc',
        );
        expect(activities.single.recordKey, 'fileKey:geo/20260328/recent.fit');
        expect(activities.single.sourceFilename, 'Morning Ride');
      },
    );

    test(
      'throws OnelapRiskControlError for risk-control list responses',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 429,
                'msg': 'risk control triggered',
                'error': 'too many requests',
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.listFitActivities(since: DateTime.utc(2026, 3, 27)),
          throwsA(
            isA<OnelapRiskControlError>().having(
              (OnelapRiskControlError error) => error.message,
              'message',
              contains('risk control triggered'),
            ),
          ),
        );
      },
    );

    test('throws OnelapRiskControlError for code -2 list responses', () async {
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();

        if (url == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'token': 'otm-token-123',
                'refresh_token': 'otm-refresh-456',
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
          return ResponseBody.fromString(
            jsonEncode({'code': -2, 'msg': 'temporary backend message'}),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      await expectLater(
        client.listFitActivities(since: DateTime.utc(2026, 3, 27)),
        throwsA(
          isA<OnelapRiskControlError>().having(
            (OnelapRiskControlError error) => error.message,
            'message',
            contains('temporary backend message'),
          ),
        ),
      );
    });

    test(
      'does not treat generic throttling text alone as risk control for list responses',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({'code': 429, 'msg': 'too many requests'}),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.listFitActivities(since: DateTime.utc(2026, 3, 27)),
          throwsA(
            isA<Exception>().having(
              (Exception error) => error.toString(),
              'message',
              contains('OneLap activities request failed: too many requests'),
            ),
          ),
        );
      },
    );

    test(
      'does not treat unrelated nested payload text as risk control for list responses',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 500,
                'msg': 'temporary backend message',
                'data': {
                  'details':
                      'previous risk control triggered for another account',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.listFitActivities(since: DateTime.utc(2026, 3, 27)),
          throwsA(
            isA<Exception>().having(
              (Exception error) => error.toString(),
              'message',
              contains(
                'OneLap activities request failed: temporary backend message',
              ),
            ),
          ),
        );
      },
    );

    test(
      'caps single-page list requests and results to min(limit, 50)',
      () async {
        final List<String> requestBodies = <String>[];

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            requestBodies.add(jsonEncode(options.data));
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 101,
                      'name': 'Ride 1',
                      'start_riding_time': '2026-03-28T10:00:00',
                      'durl': 'http://fits.rfsvr.net/1.fit?token=abc',
                    },
                    {
                      'id': 102,
                      'name': 'Ride 2',
                      'start_riding_time': '2026-03-28T11:00:00',
                      'durl': 'http://fits.rfsvr.net/2.fit?token=abc',
                    },
                    {
                      'id': 103,
                      'name': 'Ride 3',
                      'start_riding_time': '2026-03-28T12:00:00',
                      'durl': 'http://fits.rfsvr.net/3.fit?token=abc',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url.startsWith(
            'https://otm.onelap.cn/api/otm/ride_record/analysis/',
          )) {
            final String recordId = url.split('/').last;
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'durl': 'http://fits.rfsvr.net/$recordId.fit?token=abc',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
          limit: 2,
        );

        expect(requestBodies, <String>['{"page":1,"limit":2}']);
        expect(activities, hasLength(2));
        expect(
          activities.map((OneLapActivity activity) => activity.activityId),
          <String>['101', '102'],
        );
      },
    );

    test('returns no activities when limit is zero', () async {
      final List<String> requestBodies = <String>[];

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();

        if (url == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'token': 'otm-token-123',
                'refresh_token': 'otm-refresh-456',
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
          requestBodies.add(jsonEncode(options.data));
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'list': [
                  {
                    'id': 661,
                    'name': 'Should Not Return',
                    'start_riding_time': '2026-03-28T10:00:00',
                    'durl': 'http://fits.rfsvr.net/ignored.fit?token=abc',
                  },
                ],
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/661') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'durl': 'http://fits.rfsvr.net/ignored.fit?token=abc'},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final List<OneLapActivity> activities = await client.listFitActivities(
        since: DateTime.utc(2026, 3, 27),
        limit: 0,
      );

      expect(requestBodies, isEmpty);
      expect(activities, isEmpty);
    });

    test(
      'falls back to recordId-based recordKey when detail enrichment request fails',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {'id': 654, 'start_riding_time': '2026-03-28T10:00:00'},
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/654') {
            return ResponseBody.fromString(
              jsonEncode({'code': 500, 'msg': 'detail failed'}),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
        );

        expect(activities, hasLength(1));
        expect(activities.single.recordId, '654');
        expect(activities.single.recordKey, 'recordId:654');
        expect(activities.single.fitUrl, '');
      },
    );

    test(
      'keeps list-derived legacy recordKey when detail enrichment request fails',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 656,
                      'start_riding_time': '2026-03-28T10:00:00',
                      'fileKey': 'geo/20260328/recent.fit',
                      'fit_url': 'geo/20260328/recent.fit',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/656') {
            return ResponseBody.fromString(
              jsonEncode({'code': 500, 'msg': 'detail failed'}),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
        );

        expect(activities, hasLength(1));
        expect(activities.single.recordId, '656');
        expect(activities.single.recordKey, 'fileKey:geo/20260328/recent.fit');
        expect(activities.single.fitUrl, 'geo/20260328/recent.fit');
        expect(activities.single.rawFileKey, 'geo/20260328/recent.fit');
      },
    );

    test(
      'prefers detail-derived legacy recordKey when detail enrichment succeeds with a different identity',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 657,
                      'start_riding_time': '2026-03-28T10:00:00',
                      'fileKey': 'geo/20260328/list.fit',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/657') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'fileKey': 'geo/20260328/detail.fit',
                  'fit_url': 'geo/20260328/detail.fit',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
        );

        expect(activities, hasLength(1));
        expect(activities.single.recordKey, 'fileKey:geo/20260328/detail.fit');
        expect(activities.single.rawFileKey, 'geo/20260328/detail.fit');
        expect(activities.single.fitUrl, 'geo/20260328/detail.fit');
      },
    );

    test(
      'prefers stable detail fileKey over list durl for recordKey',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 660,
                      'start_riding_time': '2026-03-28T10:00:00',
                      'durl': 'http://fits.rfsvr.net/transient.fit?token=abc',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/660') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'fileKey': 'geo/20260328/stable.fit',
                  'durl': 'http://fits.rfsvr.net/transient.fit?token=xyz',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
        );

        expect(activities, hasLength(1));
        expect(activities.single.recordKey, 'fileKey:geo/20260328/stable.fit');
        expect(activities.single.rawFileKey, 'geo/20260328/stable.fit');
        expect(
          activities.single.fitUrl,
          'http://fits.rfsvr.net/transient.fit?token=xyz',
        );
      },
    );

    test(
      'replaces stale list-derived legacy download fields when detail enrichment succeeds',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 658,
                      'start_riding_time': '2026-03-28T10:00:00',
                      'fileKey': 'geo/20260328/list.fit',
                      'fit_url': 'geo/20260328/list.fit',
                      'durl': 'http://fits.rfsvr.net/list.fit?token=abc',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/658') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'fileKey': 'geo/20260328/detail.fit',
                  'fit_url': 'geo/20260328/detail.fit',
                  'fitUrl': 'geo/20260328/detail-alt.fit',
                  'durl': 'http://fits.rfsvr.net/detail.fit?token=xyz',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
        );

        expect(activities, hasLength(1));
        expect(activities.single.recordKey, 'fileKey:geo/20260328/detail.fit');
        expect(activities.single.rawFileKey, 'geo/20260328/detail.fit');
        expect(activities.single.rawFitUrl, 'geo/20260328/detail.fit');
        expect(activities.single.rawFitUrlAlt, 'geo/20260328/detail-alt.fit');
        expect(
          activities.single.rawDurl,
          'http://fits.rfsvr.net/detail.fit?token=xyz',
        );
        expect(
          activities.single.fitUrl,
          'http://fits.rfsvr.net/detail.fit?token=xyz',
        );
      },
    );

    test('reads nested ridingRecord fields from detail payload', () async {
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();

        if (url == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'token': 'otm-token-123',
                'refresh_token': 'otm-refresh-456',
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'list': [
                  {'id': 659, 'start_riding_time': '2026-03-28T10:00:00'},
                ],
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/659') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'ridingRecord': {
                  'fileKey': 'geo/20260328/nested.fit',
                  'fitUrl': 'geo/20260328/nested-alt.fit',
                  'durl': 'http://fits.rfsvr.net/nested.fit?token=xyz',
                },
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final List<OneLapActivity> activities = await client.listFitActivities(
        since: DateTime.utc(2026, 3, 27),
      );

      expect(activities, hasLength(1));
      expect(activities.single.recordId, '659');
      expect(activities.single.rawFileKey, 'geo/20260328/nested.fit');
      expect(activities.single.rawFitUrlAlt, 'geo/20260328/nested-alt.fit');
      expect(
        activities.single.rawDurl,
        'http://fits.rfsvr.net/nested.fit?token=xyz',
      );
      expect(
        activities.single.fitUrl,
        'http://fits.rfsvr.net/nested.fit?token=xyz',
      );
    });

    test(
      'surfaces OnelapRiskControlError when detail enrichment hits risk control',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 655,
                      'start_riding_time': '2026-03-28T10:00:00',
                      'fit_url': 'geo/20260328/recent.fit',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/655') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 429,
                'msg': 'risk control triggered',
                'error': 'too many requests',
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.listFitActivities(since: DateTime.utc(2026, 3, 27)),
          throwsA(
            isA<OnelapRiskControlError>().having(
              (OnelapRiskControlError error) => error.message,
              'message',
              contains('risk control triggered'),
            ),
          ),
        );
      },
    );

    test(
      'falls back to recordId-based recordKey when detail payload has no legacy identity fields',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {'id': 777, 'start_riding_time': '2026-03-28T10:00:00'},
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/777') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'summary': {'distance': 1200},
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
        );

        expect(activities, hasLength(1));
        expect(activities.single.recordId, '777');
        expect(activities.single.recordKey, 'recordId:777');
        expect(activities.single.fitUrl, '');
        expect(activities.single.sourceFilename, '2026-03-28T10:00:00');
      },
    );

    test(
      'uses start_riding_time as sourceFilename fallback when record name is absent',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 778,
                      'start_riding_time': '2026-03-28T11:30:00',
                      'fitUrl': 'geo/20260328/recent.fit',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/778') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {'fitUrl': 'geo/20260328/recent.fit'},
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final List<OneLapActivity> activities = await client.listFitActivities(
          since: DateTime.utc(2026, 3, 27),
        );

        expect(activities, hasLength(1));
        expect(activities.single.sourceFilename, '2026-03-28T11:30:00');
        expect(activities.single.fitUrl, 'geo/20260328/recent.fit');
      },
    );

    test(
      'throws a clear error when OneLap detail payload is invalid',
      () async {
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'list': [
                    {
                      'id': 888,
                      'created_at': 1774768800,
                      'durl': 'http://fits.rfsvr.net/recent.fit?token=abc',
                    },
                  ],
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/888') {
            return ResponseBody.fromString(
              jsonEncode({'code': 200, 'data': 'invalid'}),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.listFitActivities(since: DateTime.utc(2026, 3, 27)),
          throwsA(
            isA<Exception>().having(
              (Exception error) => error.toString(),
              'message',
              contains('OneLap detail payload is invalid'),
            ),
          ),
        );
      },
    );

    test('prefers durl over fit_url and fitUrl for download URL', () async {
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.toString() == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': [
                {'token': 'otm-token-123', 'refresh_token': 'otm-refresh-456'},
              ],
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }
        if (options.uri.toString() ==
            'https://otm.onelap.cn/api/otm/ride_record/list') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'list': [
                  {
                    'id': 1,
                    'start_time': '2026-03-29T10:00:00',
                    'fileKey': 'demo.fit',
                    'fit_url': 'geo/20260329/wrong.fit',
                    'fitUrl': 'geo/20260329/also-wrong.fit',
                    'durl': 'http://fits.rfsvr.net/correct.fit?token=abc',
                  },
                ],
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }
        if (options.uri.toString() ==
            'https://otm.onelap.cn/api/otm/ride_record/analysis/1') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'fileKey': 'demo.fit',
                'fit_url': 'geo/20260329/wrong.fit',
                'fitUrl': 'geo/20260329/also-wrong.fit',
                'durl': 'http://fits.rfsvr.net/correct.fit?token=abc',
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }
        return ResponseBody.fromString('not found', 404);
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final activities = await client.listFitActivities(
        since: DateTime.utc(2026, 3, 28),
      );

      expect(activities, hasLength(1));
      expect(
        activities.single.fitUrl,
        'http://fits.rfsvr.net/correct.fit?token=abc',
      );
      expect(activities.single.sourceFilename, '2026-03-29T10:00:00');
    });

    test('uses fileKey when no fit URL fields exist', () async {
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.toString() == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': [
                {'token': 'otm-token-123', 'refresh_token': 'otm-refresh-456'},
              ],
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }
        if (options.uri.toString() ==
            'https://otm.onelap.cn/api/otm/ride_record/list') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'list': [
                  {
                    'id': 1,
                    'start_time': '2026-03-29T10:00:00',
                    'fileKey': 'geo/20260329/filekey.fit',
                  },
                ],
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }
        if (options.uri.toString() ==
            'https://otm.onelap.cn/api/otm/ride_record/analysis/1') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'fileKey': 'geo/20260329/filekey.fit'},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }
        return ResponseBody.fromString('not found', 404);
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final List<OneLapActivity> activities = await client.listFitActivities(
        since: DateTime.utc(2026, 3, 28),
      );

      expect(activities, hasLength(1));
      expect(activities.single.fitUrl, 'geo/20260329/filekey.fit');
      expect(activities.single.rawFileKey, 'geo/20260329/filekey.fit');
      expect(activities.single.recordKey, 'fileKey:geo/20260329/filekey.fit');
    });

    test('parses distanceKm and timeSeconds from detail response', () async {
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();

        if (url == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'token': 'tok', 'refresh_token': 'ref'},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'https://otm.onelap.cn/api/otm/ride_record/list') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'list': [
                  {'id': 100, 'start_riding_time': '2026-03-29T10:00:00'},
                ],
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'https://otm.onelap.cn/api/otm/ride_record/analysis/100') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'ridingRecord': {
                  'fileKey': 'geo/20260329/ride.fit',
                  'totalDistance': 42500,
                  'time': 5400,
                },
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final activities = await client.listFitActivities(
        since: DateTime.utc(2026, 3, 28),
      );

      expect(activities, hasLength(1));
      expect(activities.single.distanceKm, 42.5);
      expect(activities.single.timeSeconds, 5400);
    });
  });

  group('OneLapClient.downloadFit', () {
    test('falls back from absolute durl to raw fit_url after 404', () async {
      final List<String> requests = <String>[];
      final Map<String, _DownloadRoute> routes = <String, _DownloadRoute>{
        'http://fits.rfsvr.net/correct.fit?token=abc': _DownloadRoute(
          statusCode: HttpStatus.notFound,
        ),
        'http://example.com/geo/20260329/wrong.fit': _DownloadRoute(
          statusCode: HttpStatus.ok,
          bytes: _validFitBytes([9, 8, 7]),
        ),
      };
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();
        requests.add(url);
        final _DownloadRoute route =
            routes[url] ?? _DownloadRoute(statusCode: HttpStatus.notFound);
        return ResponseBody.fromBytes(
          route.bytes ?? <int>[],
          route.statusCode,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/octet-stream'],
          },
        );
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-fallback-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final File downloaded = await client.downloadFit(
        'http://fits.rfsvr.net/correct.fit?token=abc',
        'demo.fit',
        outputDir,
        activity: const OneLapActivity(
          activityId: '1',
          startTime: '2026-03-29T10:00:00',
          fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          recordKey: 'fileKey:demo.fit',
          sourceFilename: 'demo.fit',
          rawFitUrl: 'geo/20260329/wrong.fit',
          rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          rawFileKey: 'demo.fit',
        ),
      );

      expect(requests, <String>[
        'http://fits.rfsvr.net/correct.fit?token=abc',
        'http://example.com/geo/20260329/wrong.fit',
      ]);
      expect(await downloaded.readAsBytes(), _validFitBytes([9, 8, 7]));
    });

    test(
      'falls back to raw fileKey path after durl and raw fit urls 404',
      () async {
        final List<String> requests = <String>[];
        final Map<String, _DownloadRoute> routes = <String, _DownloadRoute>{
          'http://fits.rfsvr.net/correct.fit?token=abc': _DownloadRoute(
            statusCode: HttpStatus.notFound,
          ),
          'http://example.com/geo/20260329/wrong.fit': _DownloadRoute(
            statusCode: HttpStatus.notFound,
          ),
          'http://u.onelap.cn/geo/20260329/wrong.fit': _DownloadRoute(
            statusCode: HttpStatus.notFound,
          ),
          'https://u.onelap.cn/geo/20260329/wrong.fit': _DownloadRoute(
            statusCode: HttpStatus.notFound,
          ),
          'https://www.onelap.cn/geo/20260329/wrong.fit': _DownloadRoute(
            statusCode: HttpStatus.notFound,
          ),
          'http://example.com/geo/20260329/filekey.fit': _DownloadRoute(
            statusCode: HttpStatus.ok,
            bytes: _validFitBytes([1, 2, 3]),
          ),
        };
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);
          final _DownloadRoute route =
              routes[url] ?? _DownloadRoute(statusCode: HttpStatus.notFound);
          return ResponseBody.fromBytes(
            route.bytes ?? <int>[],
            route.statusCode,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-filekey-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '1',
            startTime: '2026-03-29T10:00:00',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey: 'fileKey:geo/20260329/filekey.fit',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: 'geo/20260329/filekey.fit',
          ),
        );

        expect(
          requests,
          contains('http://example.com/geo/20260329/filekey.fit'),
        );
        expect(await downloaded.readAsBytes(), _validFitBytes([1, 2, 3]));
      },
    );

    test(
      'falls back to secondary geo host after primary returns 404',
      () async {
        final HttpServer primaryServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final HttpServer fallbackServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-test-',
        );

        primaryServer.listen((HttpRequest request) async {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        });

        final List<int> expectedBytes = _validFitBytes(<int>[1, 2, 3, 4, 5]);
        fallbackServer.listen((HttpRequest request) async {
          request.response.statusCode = HttpStatus.ok;
          request.response.add(expectedBytes);
          await request.response.close();
        });

        final String primaryBaseUrl =
            'http://${primaryServer.address.host}:${primaryServer.port}';
        final String fallbackBaseUrl =
            'http://${fallbackServer.address.host}:${fallbackServer.port}';

        final OneLapClient client = OneLapClient(
          baseUrl: primaryBaseUrl,
          username: 'unused',
          password: 'unused',
          geoFallbackBaseUrls: <String>[fallbackBaseUrl],
        );

        addTearDown(() async {
          await primaryServer.close(force: true);
          await fallbackServer.close(force: true);
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final File downloaded = await client.downloadFit(
          'geo/20260329/sample.fit',
          'sample.fit',
          outputDir,
        );

        expect(await downloaded.exists(), isTrue);
        expect(await downloaded.readAsBytes(), expectedBytes);
      },
    );

    test(
      'falls back to OTM fit content download after standard URLs fail',
      () async {
        final List<String> requests = <String>[];
        final Map<String, Object> authHeadersByUrl = <String, Object>{};
        final String otmFitPath =
            'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
        final String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);
          authHeadersByUrl[url] = options.headers['Authorization'] ?? '';

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': [
                  {
                    'token': 'otm-token-123',
                    'refresh_token': 'otm-refresh-456',
                  },
                ],
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/geo/20260329/wrong.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            return ResponseBody.fromBytes(
              _validFitBytes(<int>[4, 5, 6, 7]),
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey: 'fileKey:$otmFitPath',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        expect(requests, contains('http://example.com/api/login'));
        expect(requests, contains(otmFitContentUrl));
        expect(authHeadersByUrl[otmFitContentUrl], 'otm-token-123');
        expect(
          await downloaded.readAsBytes(),
          _validFitBytes(<int>[4, 5, 6, 7]),
        );
      },
    );

    test(
      'downloads FIT through the recordId OTM endpoint before trying legacy URLs',
      () async {
        final List<String> requests = <String>[];
        final Map<String, Object?> authHeadersByUrl = <String, Object?>{};
        final Map<String, ResponseType?> responseTypesByUrl =
            <String, ResponseType?>{};
        const String recordId = '93825';
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);
          authHeadersByUrl[url] = options.headers['Authorization'];
          responseTypesByUrl[url] = options.responseType;

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              _validFitBytes(<int>[7, 7, 7]),
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc') {
            return ResponseBody.fromBytes(
              <int>[1, 2, 3],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-recordid-primary-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            recordId: recordId,
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey: 'recordId:93825',
            sourceFilename: 'demo.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          ),
        );

        expect(requests, contains('http://example.com/api/login'));
        expect(requests, contains(recordIdFitContentUrl));
        expect(
          requests.where(
            (String url) =>
                url == 'http://fits.rfsvr.net/correct.fit?token=abc',
          ),
          isEmpty,
        );
        expect(authHeadersByUrl[recordIdFitContentUrl], 'otm-token-123');
        expect(responseTypesByUrl[recordIdFitContentUrl], ResponseType.bytes);
        expect(await downloaded.readAsBytes(), _validFitBytes([7, 7, 7]));
      },
    );

    test(
      'falls back to u.onelap.cn recordId FIT endpoint after otm.onelap.cn returns 500',
      () async {
        final List<String> requests = <String>[];
        final Map<String, Object?> authHeadersByUrl = <String, Object?>{};
        final Map<String, ResponseType?> responseTypesByUrl =
            <String, ResponseType?>{};
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/69ea1c54271f399a5f0662c7';
        const String fallbackRecordIdFitContentUrl =
            'https://u.onelap.cn/api/otm/ride_record/analysis/fit_content/69ea1c54271f399a5f0662c7';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);
          authHeadersByUrl[url] = options.headers['Authorization'];
          responseTypesByUrl[url] = options.responseType;

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.internalServerError,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == fallbackRecordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              _validFitBytes(<int>[6, 9, 1]),
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc') {
            return ResponseBody.fromBytes(
              <int>[1, 2, 3],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-recordid-host-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final File downloaded = await client.downloadFit(
          '',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            recordId: '69ea1c54271f399a5f0662c7',
            startTime: '2026-03-31T15:21:16',
            fitUrl: '',
            recordKey: 'recordId:69ea1c54271f399a5f0662c7',
            sourceFilename: 'demo.fit',
          ),
        );

        expect(requests, <String>[
          'http://example.com/api/login',
          recordIdFitContentUrl,
          fallbackRecordIdFitContentUrl,
        ]);
        expect(authHeadersByUrl[recordIdFitContentUrl], 'otm-token-123');
        expect(
          authHeadersByUrl[fallbackRecordIdFitContentUrl],
          'otm-token-123',
        );
        expect(responseTypesByUrl[recordIdFitContentUrl], ResponseType.bytes);
        expect(
          responseTypesByUrl[fallbackRecordIdFitContentUrl],
          ResponseType.bytes,
        );
        expect(await downloaded.readAsBytes(), _validFitBytes([6, 9, 1]));
      },
    );

    test(
      'falls back to legacy direct download when recordId FIT endpoint fails non-auth',
      () async {
        final List<String> requests = <String>[];
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.internalServerError,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc') {
            return ResponseBody.fromBytes(
              _validFitBytes(<int>[4, 5, 6]),
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-recordid-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            recordId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey: 'recordId:93825',
            sourceFilename: 'demo.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          ),
        );

        expect(requests, <String>[
          'http://example.com/api/login',
          recordIdFitContentUrl,
          'http://fits.rfsvr.net/correct.fit?token=abc',
        ]);
        expect(await downloaded.readAsBytes(), _validFitBytes([4, 5, 6]));
      },
    );

    test(
      'throws a clear error when the recordId FIT endpoint returns an empty body even if legacy candidates exist',
      () async {
        final List<String> requests = <String>[];
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc') {
            return ResponseBody.fromBytes(
              <int>[4, 5, 6],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-recordid-empty-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.downloadFit(
            'http://fits.rfsvr.net/correct.fit?token=abc',
            'demo.fit',
            outputDir,
            activity: const OneLapActivity(
              activityId: '93825',
              recordId: '93825',
              startTime: '2026-03-31T15:21:16',
              fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
              recordKey: 'recordId:93825',
              sourceFilename: 'demo.fit',
              rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (Exception error) => error.toString(),
              'message',
              contains('recordId FIT endpoint returned an empty body'),
            ),
          ),
        );

        expect(requests, <String>[
          'http://example.com/api/login',
          recordIdFitContentUrl,
        ]);
      },
    );

    test(
      'does not attempt legacy download when recordId is the only candidate and recordId fetch fails non-auth',
      () async {
        final List<String> requests = <String>[];
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';
        const String fallbackRecordIdFitContentUrl =
            'https://u.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.internalServerError,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == fallbackRecordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-recordid-only-nolegacy-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.downloadFit(
            '',
            'demo.fit',
            outputDir,
            activity: const OneLapActivity(
              activityId: '93825',
              recordId: '93825',
              startTime: '2026-03-31T15:21:16',
              fitUrl: '',
              recordKey: 'recordId:93825',
              sourceFilename: 'demo.fit',
            ),
          ),
          throwsA(
            isA<DioException>().having(
              (DioException error) => error.response?.statusCode,
              'statusCode',
              HttpStatus.internalServerError,
            ),
          ),
        );

        expect(requests, <String>[
          'http://example.com/api/login',
          recordIdFitContentUrl,
          fallbackRecordIdFitContentUrl,
        ]);
      },
    );

    test(
      'includes fallback host diagnostics when recordId-only FIT download fails on both hosts',
      () async {
        final List<String> requests = <String>[];
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';
        const String fallbackRecordIdFitContentUrl =
            'https://u.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.internalServerError,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == fallbackRecordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              utf8.encode('missing fallback fit'),
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['text/plain'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-recordid-only-diagnostics-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.downloadFit(
            '',
            'demo.fit',
            outputDir,
            activity: const OneLapActivity(
              activityId: '93825',
              recordId: '93825',
              startTime: '2026-03-31T15:21:16',
              fitUrl: '',
              recordKey: 'recordId:93825',
              sourceFilename: 'demo.fit',
            ),
          ),
          throwsA(
            isA<DioException>()
                .having(
                  (DioException error) => error.response?.statusCode,
                  'statusCode',
                  HttpStatus.internalServerError,
                )
                .having(
                  (DioException error) => error.message,
                  'message',
                  allOf(
                    contains('HTTP 500'),
                    contains(recordIdFitContentUrl),
                    contains('Fallback host attempt'),
                    contains(fallbackRecordIdFitContentUrl),
                    contains('status 404'),
                    contains('content-type text/plain'),
                  ),
                ),
          ),
        );

        expect(requests, <String>[
          'http://example.com/api/login',
          recordIdFitContentUrl,
          fallbackRecordIdFitContentUrl,
        ]);
      },
    );

    test(
      'throws a clear error when the recordId FIT endpoint returns an empty body',
      () async {
        final List<String> requests = <String>[];
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc') {
            return ResponseBody.fromBytes(
              <int>[9, 9, 9],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-recordid-empty-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.downloadFit(
            '',
            'demo.fit',
            outputDir,
            activity: const OneLapActivity(
              activityId: '93825',
              recordId: '93825',
              startTime: '2026-03-31T15:21:16',
              fitUrl: '',
              recordKey: 'recordId:93825',
              sourceFilename: 'demo.fit',
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (Exception error) => error.toString(),
              'message',
              contains('recordId FIT endpoint returned an empty body'),
            ),
          ),
        );

        expect(requests, <String>[
          'http://example.com/api/login',
          recordIdFitContentUrl,
        ]);
      },
    );

    test(
      'throws a clear error when the recordId FIT endpoint returns JSON error content',
      () async {
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/93825';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'otm-token-123',
                  'refresh_token': 'otm-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              utf8.encode('{"code":500,"msg":"fit not ready"}'),
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-recordid-json-error-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.downloadFit(
            '',
            'demo.fit',
            outputDir,
            activity: const OneLapActivity(
              activityId: '93825',
              recordId: '93825',
              startTime: '2026-03-31T15:21:16',
              fitUrl: '',
              recordKey: 'recordId:93825',
              sourceFilename: 'demo.fit',
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (Exception error) => error.toString(),
              'message',
              contains('recordId FIT endpoint returned an error body'),
            ),
          ),
        );
      },
    );

    test('retries OTM auth via login when cached token is rejected', () async {
      final List<String> requests = <String>[];
      final List<Object?> otmAuthHeaders = <Object?>[];
      int loginRequests = 0;
      final String otmFitPath =
          'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
      final String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();
        requests.add(url);

        if (url == 'http://example.com/api/login') {
          loginRequests++;
          final String token = loginRequests == 1
              ? 'stale-token-123'
              : 'fresh-token-456';
          final String refreshToken = loginRequests == 1
              ? 'stale-refresh-123'
              : 'fresh-refresh-456';
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'token': token, 'refresh_token': refreshToken},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
            url == 'http://example.com/geo/20260329/wrong.fit' ||
            url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.notFound,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        if (url == otmFitContentUrl) {
          otmAuthHeaders.add(options.headers['Authorization']);
          if (options.headers['Authorization'] == 'stale-token-123') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.unauthorized,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromBytes(
            <int>[9, 8, 7, 6],
            HttpStatus.ok,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-otm-relogin-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      await client.login();

      final File downloaded = await client.downloadFit(
        'http://fits.rfsvr.net/correct.fit?token=abc',
        'demo.fit',
        outputDir,
        activity: OneLapActivity(
          activityId: '93825',
          startTime: '2026-03-31T15:21:16',
          fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          recordKey: 'fileKey:$otmFitPath',
          sourceFilename: 'demo.fit',
          rawFitUrl: 'geo/20260329/wrong.fit',
          rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          rawFileKey: otmFitPath,
        ),
      );

      expect(loginRequests, 2);
      expect(otmAuthHeaders, <Object?>['stale-token-123', 'fresh-token-456']);
      expect(await downloaded.readAsBytes(), <int>[9, 8, 7, 6]);
    });

    test(
      'refreshes OneLap auth token after a 403 response and retries once',
      () async {
        final List<String> requests = <String>[];
        final List<Object?> otmAuthHeaders = <Object?>[];
        final List<String> refreshRequestBodies = <String>[];
        int loginRequests = 0;
        int refreshRequests = 0;
        const String otmFitPath =
            'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
        const String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://example.com/api/login') {
            loginRequests++;
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'stale-token-123',
                  'refresh_token': 'stale-refresh-123',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://example.com/api/token') {
            refreshRequests++;
            refreshRequestBodies.add(jsonEncode(options.data));
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'refreshed-token-456',
                  'refresh_token': 'refreshed-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/geo/20260329/wrong.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            otmAuthHeaders.add(options.headers['Authorization']);
            if (otmAuthHeaders.length == 1) {
              return ResponseBody.fromBytes(
                <int>[],
                HttpStatus.forbidden,
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>[
                    'application/octet-stream',
                  ],
                },
              );
            }

            return ResponseBody.fromBytes(
              <int>[3, 4, 5, 6],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-refresh-403-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await client.login();

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        expect(loginRequests, 1);
        expect(refreshRequests, 1);
        expect(refreshRequestBodies, <String>[
          '{"token":"stale-refresh-123","from":"web","to":"web"}',
        ]);
        expect(otmAuthHeaders, <Object?>[
          'stale-token-123',
          'refreshed-token-456',
        ]);
        expect(await downloaded.readAsBytes(), <int>[3, 4, 5, 6]);
      },
    );

    test(
      'refreshes OneLap auth token after a 401 response and retries once',
      () async {
        final List<Object?> otmAuthHeaders = <Object?>[];
        final List<String> refreshRequestBodies = <String>[];
        int loginRequests = 0;
        int refreshRequests = 0;
        const String otmFitPath =
            'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
        const String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            loginRequests++;
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'stale-token-123',
                  'refresh_token': 'stale-refresh-123',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://example.com/api/token') {
            refreshRequests++;
            refreshRequestBodies.add(jsonEncode(options.data));
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'refreshed-token-456',
                  'refresh_token': 'refreshed-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/geo/20260329/wrong.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            otmAuthHeaders.add(options.headers['Authorization']);
            if (otmAuthHeaders.length == 1) {
              return ResponseBody.fromBytes(
                <int>[],
                HttpStatus.unauthorized,
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>[
                    'application/octet-stream',
                  ],
                },
              );
            }

            return ResponseBody.fromBytes(
              <int>[4, 4, 5, 5],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-refresh-401-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await client.login();

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        expect(loginRequests, 1);
        expect(refreshRequests, 1);
        expect(refreshRequestBodies, <String>[
          '{"token":"stale-refresh-123","from":"web","to":"web"}',
        ]);
        expect(otmAuthHeaders, <Object?>[
          'stale-token-123',
          'refreshed-token-456',
        ]);
        expect(await downloaded.readAsBytes(), <int>[4, 4, 5, 5]);
      },
    );

    test('surfaces non-auth OTM failures without refresh or re-login', () async {
      final List<Object?> otmAuthHeaders = <Object?>[];
      int loginRequests = 0;
      int refreshRequests = 0;
      const String otmFitPath =
          'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
      const String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();

        if (url == 'http://example.com/api/login') {
          loginRequests++;
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {
                'token': 'stale-token-123',
                'refresh_token': 'stale-refresh-123',
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://example.com/api/token') {
          refreshRequests++;
          return ResponseBody.fromString('unexpected refresh', 500);
        }

        if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
            url == 'http://example.com/geo/20260329/wrong.fit' ||
            url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.notFound,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        if (url == otmFitContentUrl) {
          otmAuthHeaders.add(options.headers['Authorization']);
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.unprocessableEntity,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-otm-non-auth-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      await client.login();

      await expectLater(
        client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        ),
        throwsA(
          isA<DioException>().having(
            (DioException error) => error.response?.statusCode,
            'statusCode',
            HttpStatus.unprocessableEntity,
          ),
        ),
      );

      expect(loginRequests, 1);
      expect(refreshRequests, 0);
      expect(otmAuthHeaders, <Object?>['stale-token-123']);
    });

    test(
      're-logs in when refresh returns non-200 HTTP status despite a valid payload',
      () async {
        final List<Object?> otmAuthHeaders = <Object?>[];
        int loginRequests = 0;
        int refreshRequests = 0;
        const String otmFitPath =
            'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
        const String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            loginRequests++;
            final String token = loginRequests == 1
                ? 'stale-token-123'
                : 'relogin-token-789';
            final String refreshToken = loginRequests == 1
                ? 'stale-refresh-123'
                : 'relogin-refresh-789';
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {'token': token, 'refresh_token': refreshToken},
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://example.com/api/token') {
            refreshRequests++;
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'refreshed-token-456',
                  'refresh_token': 'refreshed-refresh-456',
                },
              }),
              201,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/geo/20260329/wrong.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            otmAuthHeaders.add(options.headers['Authorization']);
            if (options.headers['Authorization'] != 'relogin-token-789') {
              return ResponseBody.fromBytes(
                <int>[],
                HttpStatus.forbidden,
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>[
                    'application/octet-stream',
                  ],
                },
              );
            }

            return ResponseBody.fromBytes(
              <int>[6, 5, 4, 3],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-refresh-http-201-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await client.login();

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        expect(loginRequests, 2);
        expect(refreshRequests, 1);
        expect(otmAuthHeaders, <Object?>[
          'stale-token-123',
          'relogin-token-789',
        ]);
        expect(await downloaded.readAsBytes(), <int>[6, 5, 4, 3]);
      },
    );

    test('re-logs in when refresh returns non-200 top-level code', () async {
      final List<Object?> otmAuthHeaders = <Object?>[];
      int loginRequests = 0;
      int refreshRequests = 0;
      const String otmFitPath =
          'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
      const String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();

        if (url == 'http://example.com/api/login') {
          loginRequests++;
          final String token = loginRequests == 1
              ? 'stale-token-123'
              : 'relogin-token-789';
          final String refreshToken = loginRequests == 1
              ? 'stale-refresh-123'
              : 'relogin-refresh-789';
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'token': token, 'refresh_token': refreshToken},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://example.com/api/token') {
          refreshRequests++;
          return ResponseBody.fromString(
            jsonEncode({
              'code': 500,
              'data': {
                'token': 'refreshed-token-456',
                'refresh_token': 'refreshed-refresh-456',
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
            url == 'http://example.com/geo/20260329/wrong.fit' ||
            url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.notFound,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        if (url == otmFitContentUrl) {
          otmAuthHeaders.add(options.headers['Authorization']);
          if (options.headers['Authorization'] != 'relogin-token-789') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.forbidden,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromBytes(
            <int>[7, 6, 5, 4],
            HttpStatus.ok,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-otm-refresh-code-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      await client.login();

      final File downloaded = await client.downloadFit(
        'http://fits.rfsvr.net/correct.fit?token=abc',
        'demo.fit',
        outputDir,
        activity: const OneLapActivity(
          activityId: '93825',
          startTime: '2026-03-31T15:21:16',
          fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          recordKey:
              'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
          sourceFilename: 'demo.fit',
          rawFitUrl: 'geo/20260329/wrong.fit',
          rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          rawFileKey: otmFitPath,
        ),
      );

      expect(loginRequests, 2);
      expect(refreshRequests, 1);
      expect(otmAuthHeaders, <Object?>['stale-token-123', 'relogin-token-789']);
      expect(await downloaded.readAsBytes(), <int>[7, 6, 5, 4]);
    });

    test('re-logs in when refresh returns an empty token', () async {
      final List<Object?> otmAuthHeaders = <Object?>[];
      int loginRequests = 0;
      int refreshRequests = 0;
      const String otmFitPath =
          'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
      const String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();

        if (url == 'http://example.com/api/login') {
          loginRequests++;
          final String token = loginRequests == 1
              ? 'stale-token-123'
              : 'relogin-token-789';
          final String refreshToken = loginRequests == 1
              ? 'stale-refresh-123'
              : 'relogin-refresh-789';
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'token': token, 'refresh_token': refreshToken},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://example.com/api/token') {
          refreshRequests++;
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'token': '', 'refresh_token': 'refreshed-refresh-456'},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
            url == 'http://example.com/geo/20260329/wrong.fit' ||
            url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.notFound,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        if (url == otmFitContentUrl) {
          otmAuthHeaders.add(options.headers['Authorization']);
          if (options.headers['Authorization'] != 'relogin-token-789') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.forbidden,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromBytes(
            <int>[3, 3, 2, 2],
            HttpStatus.ok,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-otm-refresh-empty-token-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      await client.login();

      final File downloaded = await client.downloadFit(
        'http://fits.rfsvr.net/correct.fit?token=abc',
        'demo.fit',
        outputDir,
        activity: const OneLapActivity(
          activityId: '93825',
          startTime: '2026-03-31T15:21:16',
          fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          recordKey:
              'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
          sourceFilename: 'demo.fit',
          rawFitUrl: 'geo/20260329/wrong.fit',
          rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          rawFileKey: otmFitPath,
        ),
      );

      expect(loginRequests, 2);
      expect(refreshRequests, 1);
      expect(otmAuthHeaders, <Object?>['stale-token-123', 'relogin-token-789']);
      expect(await downloaded.readAsBytes(), <int>[3, 3, 2, 2]);
    });

    test('re-logs in when refresh omits token', () async {
      final List<Object?> otmAuthHeaders = <Object?>[];
      int loginRequests = 0;
      int refreshRequests = 0;
      const String otmFitPath =
          'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
      const String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();

        if (url == 'http://example.com/api/login') {
          loginRequests++;
          final String token = loginRequests == 1
              ? 'stale-token-123'
              : 'relogin-token-789';
          final String refreshToken = loginRequests == 1
              ? 'stale-refresh-123'
              : 'relogin-refresh-789';
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'token': token, 'refresh_token': refreshToken},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://example.com/api/token') {
          refreshRequests++;
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': {'refresh_token': 'refreshed-refresh-456'},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
            url == 'http://example.com/geo/20260329/wrong.fit' ||
            url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
            url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.notFound,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        if (url == otmFitContentUrl) {
          otmAuthHeaders.add(options.headers['Authorization']);
          if (options.headers['Authorization'] != 'relogin-token-789') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.forbidden,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromBytes(
            <int>[2, 2, 1, 1],
            HttpStatus.ok,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-otm-refresh-missing-token-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      await client.login();

      final File downloaded = await client.downloadFit(
        'http://fits.rfsvr.net/correct.fit?token=abc',
        'demo.fit',
        outputDir,
        activity: const OneLapActivity(
          activityId: '93825',
          startTime: '2026-03-31T15:21:16',
          fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          recordKey:
              'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
          sourceFilename: 'demo.fit',
          rawFitUrl: 'geo/20260329/wrong.fit',
          rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
          rawFileKey: otmFitPath,
        ),
      );

      expect(loginRequests, 2);
      expect(refreshRequests, 1);
      expect(otmAuthHeaders, <Object?>['stale-token-123', 'relogin-token-789']);
      expect(await downloaded.readAsBytes(), <int>[2, 2, 1, 1]);
    });

    test(
      'retains the previous refresh token when OneLap refresh does not return a new one',
      () async {
        final List<String> refreshRequestBodies = <String>[];
        final List<Object?> otmAuthHeaders = <Object?>[];
        int loginRequests = 0;
        int refreshRequests = 0;
        const String otmFitPath =
            'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
        const String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            loginRequests++;
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'stale-token-123',
                  'refresh_token': 'stale-refresh-123',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://example.com/api/token') {
            refreshRequests++;
            refreshRequestBodies.add(jsonEncode(options.data));
            final String token = refreshRequests == 1
                ? 'refreshed-token-456'
                : 'refreshed-token-789';
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {'token': token},
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/geo/20260329/wrong.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            otmAuthHeaders.add(options.headers['Authorization']);
            if (otmAuthHeaders.length == 1 || otmAuthHeaders.length == 3) {
              return ResponseBody.fromBytes(
                <int>[],
                HttpStatus.forbidden,
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>[
                    'application/octet-stream',
                  ],
                },
              );
            }

            return ResponseBody.fromBytes(
              <int>[7, 7, 8, 8],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-refresh-retain-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await client.login();

        await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo-1.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo-1.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo-2.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo-2.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        expect(loginRequests, 1);
        expect(refreshRequests, 2);
        expect(refreshRequestBodies, <String>[
          '{"token":"stale-refresh-123","from":"web","to":"web"}',
          '{"token":"stale-refresh-123","from":"web","to":"web"}',
        ]);
        expect(otmAuthHeaders, <Object?>[
          'stale-token-123',
          'refreshed-token-456',
          'refreshed-token-456',
          'refreshed-token-789',
        ]);
        expect(await downloaded.readAsBytes(), <int>[7, 7, 8, 8]);
      },
    );

    test(
      're-logs in once when token refresh cannot recover an authenticated request',
      () async {
        final List<Object?> otmAuthHeaders = <Object?>[];
        final List<String> refreshRequestBodies = <String>[];
        int loginRequests = 0;
        int refreshRequests = 0;
        const String otmFitPath =
            'geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit';
        const String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();

          if (url == 'http://example.com/api/login') {
            loginRequests++;
            final String token = loginRequests == 1
                ? 'stale-token-123'
                : 'relogin-token-789';
            final String refreshToken = loginRequests == 1
                ? 'stale-refresh-123'
                : 'relogin-refresh-789';
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {'token': token, 'refresh_token': refreshToken},
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://example.com/api/token') {
            refreshRequests++;
            refreshRequestBodies.add(jsonEncode(options.data));
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': {
                  'token': 'refreshed-token-456',
                  'refresh_token': 'refreshed-refresh-456',
                },
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/geo/20260329/wrong.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/wrong.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/wrong.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            otmAuthHeaders.add(options.headers['Authorization']);
            if (options.headers['Authorization'] != 'relogin-token-789') {
              return ResponseBody.fromBytes(
                <int>[],
                HttpStatus.forbidden,
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>[
                    'application/octet-stream',
                  ],
                },
              );
            }

            return ResponseBody.fromBytes(
              <int>[8, 7, 6, 5],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-refresh-relogin-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await client.login();

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '93825',
            startTime: '2026-03-31T15:21:16',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey:
                'fileKey:geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'geo/20260329/wrong.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: otmFitPath,
          ),
        );

        expect(loginRequests, 2);
        expect(refreshRequests, 1);
        expect(refreshRequestBodies, <String>[
          '{"token":"stale-refresh-123","from":"web","to":"web"}',
        ]);
        expect(otmAuthHeaders, <Object?>[
          'stale-token-123',
          'refreshed-token-456',
          'relogin-token-789',
        ]);
        expect(await downloaded.readAsBytes(), <int>[8, 7, 6, 5]);
      },
    );

    test('uses absolute geo URL path for OTM fit content fallback', () async {
      final List<String> requests = <String>[];
      const String absoluteGeoUrl =
          'https://u.onelap.cn/geo/20260331/'
          'Magene_C506_1774941676_93825_1774942570550.fit';
      const String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          'Z2VvLzIwMjYwMzMxL01hZ2VuZV9DNTA2XzE3NzQ5NDE2NzZfOTM4MjVfMTc3NDk0MjU3MDU1MC5maXQ=';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();
        requests.add(url);

        if (url == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': [
                {'token': 'otm-token-123', 'refresh_token': 'otm-refresh-456'},
              ],
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == absoluteGeoUrl) {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.notFound,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        if (url == otmFitContentUrl) {
          return ResponseBody.fromBytes(
            <int>[8, 9, 10],
            HttpStatus.ok,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-otm-absolute-fallback-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final File downloaded = await client.downloadFit(
        absoluteGeoUrl,
        'demo.fit',
        outputDir,
        activity: const OneLapActivity(
          activityId: '93825',
          startTime: '2026-03-31T15:21:16',
          fitUrl: absoluteGeoUrl,
          recordKey:
              'fitUrl:https://u.onelap.cn/geo/20260331/Magene_C506_1774941676_93825_1774942570550.fit',
          sourceFilename: 'demo.fit',
        ),
      );

      expect(requests, contains(otmFitContentUrl));
      expect(await downloaded.readAsBytes(), <int>[8, 9, 10]);
    });

    test(
      'falls back to OTM fit content download for MATCH identifiers after standard URLs fail',
      () async {
        final List<String> requests = <String>[];
        final String matchIdentifier =
            'MATCH_677767-2026-04-09-21-09-29-log.st';
        final String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            '${base64.encode(utf8.encode(matchIdentifier))}';
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': [
                  {
                    'token': 'otm-token-123',
                    'refresh_token': 'otm-refresh-456',
                  },
                ],
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/not-match.fit' ||
              url == 'http://example.com/not-match-alt.fit' ||
              url == 'http://example.com/geo/20260329/not-used.fit' ||
              url == 'http://u.onelap.cn/geo/20260329/not-used.fit' ||
              url == 'https://u.onelap.cn/geo/20260329/not-used.fit' ||
              url == 'https://www.onelap.cn/geo/20260329/not-used.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            return ResponseBody.fromBytes(
              _validFitBytes(<int>[7, 6, 5, 4]),
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-match-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/correct.fit?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '677767',
            startTime: '2026-04-09T21:09:29',
            fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            recordKey: 'fileKey:MATCH_677767-2026-04-09-21-09-29-log.st',
            sourceFilename: 'demo.fit',
            rawFitUrl: 'not-match.fit',
            rawFitUrlAlt: 'not-match-alt.fit',
            rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
            rawFileKey: 'MATCH_677767-2026-04-09-21-09-29-log.st',
          ),
        );

        expect(requests, contains(otmFitContentUrl));
        expect(
          await downloaded.readAsBytes(),
          _validFitBytes(<int>[7, 6, 5, 4]),
        );
      },
    );

    test(
      'does not treat unsupported identifiers as OTM fit content fallback candidates',
      () async {
        final List<String> requests = <String>[];
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/not-match.fit' ||
              url == 'http://example.com/not-match-alt.fit') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-unsupported-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.downloadFit(
            'http://fits.rfsvr.net/correct.fit?token=abc',
            'demo.fit',
            outputDir,
            activity: const OneLapActivity(
              activityId: '1',
              startTime: '2026-04-09T21:09:29',
              fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
              recordKey: 'fileKey:unsupported-fit-id.st',
              sourceFilename: 'demo.fit',
              rawFitUrl: 'not-match.fit',
              rawFitUrlAlt: 'not-match-alt.fit',
              rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
              rawFileKey: 'unsupported-fit-id.st',
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (Exception error) => error.toString(),
              'message',
              contains('OTM fallback requires fileKey or fitUrl path'),
            ),
          ),
        );

        expect(requests, isNot(contains('http://example.com/api/login')));
        expect(
          requests.where((String url) => url.contains('/fit_content/')),
          isEmpty,
        );
      },
    );

    test(
      'does not treat malformed MATCH identifiers as OTM fit content fallback candidates',
      () async {
        final List<String> requests = <String>[];
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://fits.rfsvr.net/correct.fit?token=abc' ||
              url == 'http://example.com/not-match.fit' ||
              url == 'http://example.com/not-match-alt.fit' ||
              url == 'http://example.com/MATCH_placeholder') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-otm-malformed-match-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        await expectLater(
          client.downloadFit(
            'http://fits.rfsvr.net/correct.fit?token=abc',
            'demo.fit',
            outputDir,
            activity: const OneLapActivity(
              activityId: '1',
              startTime: '2026-04-09T21:09:29',
              fitUrl: 'http://fits.rfsvr.net/correct.fit?token=abc',
              recordKey: 'fileKey:MATCH_placeholder',
              sourceFilename: 'demo.fit',
              rawFitUrl: 'not-match.fit',
              rawFitUrlAlt: 'not-match-alt.fit',
              rawDurl: 'http://fits.rfsvr.net/correct.fit?token=abc',
              rawFileKey: 'MATCH_placeholder',
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (Exception error) => error.toString(),
              'message',
              contains('OTM fallback requires fileKey or fitUrl path'),
            ),
          ),
        );

        expect(requests, isNot(contains('http://example.com/api/login')));
        expect(
          requests.where((String url) => url.contains('/fit_content/')),
          isEmpty,
        );
      },
    );

    test(
      'falls back to OTM fit content when durl returns non-FIT .st content',
      () async {
        final List<String> requests = <String>[];
        const String matchIdentifier =
            'MATCH_677767-2026-03-05-21-06-35-log.st';
        final String otmFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
            '${base64.encode(utf8.encode(matchIdentifier))}';
        const String recordId = '69a984cab29588524341fe6b';
        const String recordIdFitContentUrl =
            'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/$recordId';

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          final String url = options.uri.toString();
          requests.add(url);

          if (url == 'http://example.com/api/login') {
            return ResponseBody.fromString(
              jsonEncode({
                'code': 200,
                'data': [
                  {
                    'token': 'otm-token-123',
                    'refresh_token': 'otm-refresh-456',
                  },
                ],
              }),
              200,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            );
          }

          if (url == recordIdFitContentUrl) {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.internalServerError,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == 'http://fits.rfsvr.net/demo.st?token=abc') {
            return ResponseBody.fromBytes(
              <int>[0x01, 0x0C, 0x08, 0x01, 0x10],
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>[
                  'application/vnd.sailingtracker.track',
                ],
              },
            );
          }

          if (url ==
              'http://example.com/MATCH_677767-2026-03-05-21-06-29-log.st') {
            return ResponseBody.fromBytes(
              <int>[],
              HttpStatus.notFound,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          if (url == otmFitContentUrl) {
            return ResponseBody.fromBytes(
              _validFitBytes(<int>[8, 8, 8]),
              HttpStatus.ok,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/octet-stream'],
              },
            );
          }

          return ResponseBody.fromString('not found', 404);
        });
        final Directory outputDir = await Directory.systemTemp.createTemp(
          'onelap-client-st-fallback-',
        );

        addTearDown(() async {
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
        });

        final OneLapClient client = OneLapClient(
          baseUrl: 'http://example.com',
          username: 'unused',
          password: 'unused',
          dio: dio,
        );

        final File downloaded = await client.downloadFit(
          'http://fits.rfsvr.net/demo.st?token=abc',
          'demo.fit',
          outputDir,
          activity: const OneLapActivity(
            activityId: '677767',
            recordId: recordId,
            startTime: '2026-03-05T21:06:35',
            fitUrl: 'http://fits.rfsvr.net/demo.st?token=abc',
            recordKey: 'fitUrl:MATCH_677767-2026-03-05-21-06-35-log.st',
            sourceFilename: 'demo.fit',
            rawFitUrlAlt: matchIdentifier,
            rawDurl: 'http://fits.rfsvr.net/demo.st?token=abc',
          ),
        );

        expect(requests, contains(otmFitContentUrl));
        expect(await downloaded.readAsBytes(), _validFitBytes(<int>[8, 8, 8]));
      },
    );

    test('falls back to OTM fit content when durl returns 403', () async {
      final List<String> requests = <String>[];
      const String matchIdentifier = 'MATCH_677767-2026-03-05-21-06-35-log.st';
      final String otmFitContentUrl =
          'https://otm.onelap.cn/api/otm/ride_record/analysis/fit_content/'
          '${base64.encode(utf8.encode(matchIdentifier))}';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final String url = options.uri.toString();
        requests.add(url);

        if (url == 'http://example.com/api/login') {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 200,
              'data': [
                {'token': 'otm-token-123', 'refresh_token': 'otm-refresh-456'},
              ],
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        }

        if (url == 'http://fits.rfsvr.net/demo.st?token=expired') {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.forbidden,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['text/plain'],
            },
          );
        }

        if (url ==
            'http://example.com/MATCH_677767-2026-03-05-21-06-29-log.st') {
          return ResponseBody.fromBytes(
            <int>[],
            HttpStatus.notFound,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        if (url == otmFitContentUrl) {
          return ResponseBody.fromBytes(
            _validFitBytes(<int>[9, 9, 9]),
            HttpStatus.ok,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/octet-stream'],
            },
          );
        }

        return ResponseBody.fromString('not found', 404);
      });
      final Directory outputDir = await Directory.systemTemp.createTemp(
        'onelap-client-403-fallback-',
      );

      addTearDown(() async {
        if (await outputDir.exists()) {
          await outputDir.delete(recursive: true);
        }
      });

      final OneLapClient client = OneLapClient(
        baseUrl: 'http://example.com',
        username: 'unused',
        password: 'unused',
        dio: dio,
      );

      final File downloaded = await client.downloadFit(
        'http://fits.rfsvr.net/demo.st?token=expired',
        'demo.fit',
        outputDir,
        activity: const OneLapActivity(
          activityId: '677767',
          startTime: '2026-03-05T21:06:35',
          fitUrl: 'http://fits.rfsvr.net/demo.st?token=expired',
          recordKey: 'fitUrl:MATCH_677767-2026-03-05-21-06-35-log.st',
          sourceFilename: 'demo.fit',
          rawFitUrlAlt: matchIdentifier,
          rawDurl: 'http://fits.rfsvr.net/demo.st?token=expired',
        ),
      );

      expect(requests, contains(otmFitContentUrl));
      expect(await downloaded.readAsBytes(), _validFitBytes(<int>[9, 9, 9]));
    });
  });
}
