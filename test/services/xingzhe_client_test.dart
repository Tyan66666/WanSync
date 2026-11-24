import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/services/settings_service.dart';
import 'package:onelap_strava_sync/services/xingzhe_client.dart';

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

class _FakeSettingsStore implements SettingsStore {
  _FakeSettingsStore([Map<String, String>? initial])
    : values = <String, String>{...?initial};

  final Map<String, String> values;

  @override
  Future<Map<String, String>> readAll() async => Map<String, String>.of(values);

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }
}

ResponseBody _jsonResponse(Map<String, dynamic> body, int statusCode) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    },
  );
}

void main() {
  group('XingzheClient.login', () {
    test('sanitizes secrets from login failure errors', () async {
      const String username = 'sensitive-user@example.com';
      const String password = 'SuperSecretPassword!';
      const String sessionId = 'sessionid-secret-123';
      const String authHeader = 'Bearer auth-secret-456';
      const String encryptedPassword = 'encrypted-secret-789';

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode(<String, String>{
            'message': 'login failed for $username',
            'cookie': 'sessionid=$sessionId',
            'authorization': authHeader,
            'password': password,
            'encrypted_password': encryptedPassword,
          }),
          401,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      });

      await expectLater(
        () => XingzheClient.login(
          username: username,
          password: password,
          dio: dio,
        ),
        throwsA(
          isA<XingzhePermanentError>().having(
            (XingzhePermanentError error) => error.toString(),
            'error string',
            allOf(
              contains('401'),
              isNot(contains(username)),
              isNot(contains(password)),
              isNot(contains(sessionId)),
              isNot(contains(authHeader)),
              isNot(contains(encryptedPassword)),
            ),
          ),
        ),
      );
    });
  });

  group('XingzheClient.uploadFit', () {
    test(
      'uploadFit preserves legacy duplicate compatibility by returning existing activity id',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'xingzhe-client-legacy-duplicate-test-',
        );
        final File fitFile = File('${tempDir.path}/activity.fit');
        await fitFile.writeAsBytes(const <int>[1, 2, 3]);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 9006,
              'msg': '文件已上传，已存在活动 12345',
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        });

        final XingzheClient client = XingzheClient(
          username: 'user',
          password: 'pass',
          dio: dio,
        );

        final int result = await client.uploadFit(fitFile, retries: 1);

        expect(result, 12345);
      },
    );

    test(
      'uploadFitDetailed preserves duplicate success metadata from 9006',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'xingzhe-client-duplicate-test-',
        );
        final File fitFile = File('${tempDir.path}/activity.fit');
        await fitFile.writeAsBytes(const <int>[1, 2, 3]);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 9006,
              'msg': '文件已上传，已存在活动 12345',
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        });

        final XingzheClient client = XingzheClient(
          username: 'user',
          password: 'pass',
          dio: dio,
        );

        final XingzheUploadFitResult result = await client.uploadFitDetailed(
          fitFile,
          retries: 1,
        );

        expect(result.alreadyUploaded, isTrue);
        expect(result.uploadId, 0);
        expect(result.remoteActivityId, 12345);
        expect(result.message, contains('12345'));
      },
    );

    test('sanitizes secrets while preserving safe HTTP error detail', () async {
      const String username = 'sensitive-user@example.com';
      const String password = 'SuperSecretPassword!';
      const String sessionId = 'sessionid-secret-123';
      const String authHeader = 'authorization=Bearer auth-secret-456';
      const String authToken = 'auth-secret-456';
      const String encryptedPassword =
          'encrypted_password=encrypted-secret-789';

      final Directory tempDir = await Directory.systemTemp.createTemp(
        'xingzhe-client-http-test-',
      );
      final File fitFile = File('${tempDir.path}/activity.fit');
      await fitFile.writeAsBytes(const <int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'msg':
                'invalid fit for $username sessionid=$sessionId password=$password $authHeader $encryptedPassword',
          }),
          400,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      });

      final XingzheClient client = XingzheClient(
        username: username,
        password: password,
        dio: dio,
      );

      await expectLater(
        () => client.uploadFit(fitFile, retries: 1),
        throwsA(
          isA<XingzhePermanentError>().having(
            (XingzhePermanentError error) => error.toString(),
            'error string',
            allOf(<Matcher>[
              contains('HTTP 400'),
              contains('invalid fit'),
              isNot(contains(username)),
              isNot(contains(password)),
              isNot(contains(sessionId)),
              isNot(contains(authHeader)),
              isNot(contains(authToken)),
              isNot(contains(encryptedPassword)),
            ]),
          ),
        ),
      );
    });

    test('falls back when upload failure detail is missing', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'xingzhe-client-null-msg-test-',
      );
      final File fitFile = File('${tempDir.path}/activity.fit');
      await fitFile.writeAsBytes(const <int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{'code': 1001}),
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      });

      final XingzheClient client = XingzheClient(
        username: 'user',
        password: 'pass',
        dio: dio,
      );

      await expectLater(
        () => client.uploadFit(fitFile, retries: 1),
        throwsA(
          isA<XingzhePermanentError>().having(
            (XingzhePermanentError error) => error.toString(),
            'error string',
            contains('xingzhe upload failed'),
          ),
        ),
      );
    });

    test(
      'retries 5xx (e.g. HTTP 502) and throws XingzheRetriableError',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'xingzhe-502-',
        );
        final File file = File('${tempDir.path}/test.fit');
        await file.writeAsBytes(const <int>[1, 2, 3]);
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });

        int callCount = 0;
        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          callCount++;
          return ResponseBody.fromString(
            '<html>502 Bad Gateway</html>',
            502,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['text/html'],
            },
          );
        });

        final XingzheClient client = XingzheClient(
          username: 'user',
          password: 'pass',
          dio: dio,
        );

        await expectLater(
          () => client.uploadFit(file, retries: 2),
          throwsA(isA<XingzheRetriableError>()),
        );
        // 初次 + 重试次数，应被调用 retries 次
        expect(callCount, 2);
      },
    );

    test('throws XingzhePermanentError when response is not a Map', () async {
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          '<html>Server Error</html>',
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['text/html'],
          },
        );
      });

      final XingzheClient client = XingzheClient(
        username: 'user',
        password: 'pass',
        dio: dio,
      );

      final Directory tempDir = await Directory.systemTemp.createTemp(
        'xingzhe-type-',
      );
      final File file = File('${tempDir.path}/test.fit');
      await file.writeAsBytes(const <int>[1, 2, 3]);

      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      expect(
        () => client.uploadFit(file),
        throwsA(isA<XingzhePermanentError>()),
      );
    });

    test(
      'sanitizes secrets while preserving safe upload failure detail',
      () async {
        const String username = 'sensitive-user@example.com';
        const String password = 'SuperSecretPassword!';
        const String sessionId = 'sessionid-secret-123';

        final Directory tempDir = await Directory.systemTemp.createTemp(
          'xingzhe-client-test-',
        );
        final File fitFile = File('${tempDir.path}/activity.fit');
        await fitFile.writeAsBytes(const <int>[1, 2, 3]);

        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final Dio dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 1001,
              'msg':
                  'invalid fit for $username sessionid=$sessionId password=$password',
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        });

        final XingzheClient client = XingzheClient(
          username: username,
          password: password,
          dio: dio,
        );

        await expectLater(
          () => client.uploadFit(fitFile, retries: 1),
          throwsA(
            isA<XingzhePermanentError>().having(
              (XingzhePermanentError error) => error.toString(),
              'error string',
              allOf(
                contains('invalid fit'),
                isNot(contains(username)),
                isNot(contains(password)),
                isNot(contains(sessionId)),
              ),
            ),
          ),
        );
      },
    );
  });

  group('XingzheClient session auto refresh', () {
    Future<File> createFitFile(String prefix) async {
      final Directory tempDir = await Directory.systemTemp.createTemp(prefix);
      final File file = File('${tempDir.path}/activity.fit');
      await file.writeAsBytes(const <int>[1, 2, 3]);
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      return file;
    }

    test('自动重新登录后重传成功，并落盘新的 sessionid', () async {
      final File fitFile = await createFitFile('xz-refresh-ok-');
      final _FakeSettingsStore store = _FakeSettingsStore(<String, String>{
        SettingsService.keyXingzheSessionId: 'stale-session',
      });

      int uploadCalls = 0;
      int loginCalls = 0;
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.path.contains('/user/login/')) {
          loginCalls += 1;
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{'id': 1},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
              'set-cookie': <String>[
                'sessionid=fresh-session; Path=/; HttpOnly',
              ],
            },
          );
        }

        uploadCalls += 1;
        final String cookie = '${options.headers['Cookie'] ?? ''}';
        if (!cookie.contains('fresh-session')) {
          return _jsonResponse(<String, dynamic>{
            'code': 401,
            'data': <String, dynamic>{},
            'msg': 'Authentication credentials were not provided.',
          }, 401);
        }
        return _jsonResponse(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{'workout_id': 4321},
        }, 200);
      });

      final XingzheClient client = XingzheClient(
        username: 'user@example.com',
        password: 'pass',
        sessionId: 'stale-session',
        dio: dio,
        settingsService: SettingsService(store: store),
      );

      final XingzheUploadFitResult result = await client.uploadFitDetailed(
        fitFile,
        retries: 1,
      );

      expect(result.uploadId, 4321);
      expect(client.sessionId, 'fresh-session');
      expect(loginCalls, 1);
      // 首次 401 + 刷新会话后重传，共两次上传请求。
      expect(uploadCalls, 2);
      expect(
        store.values[SettingsService.keyXingzheSessionId],
        'fresh-session',
      );
      expect(
        dio.options.headers['Cookie'],
        contains('sessionid=fresh-session'),
      );
    });

    test('连续两次 401 只自动登录一次，随后报永久错误', () async {
      final File fitFile = await createFitFile('xz-refresh-fail-');
      final _FakeSettingsStore store = _FakeSettingsStore();

      int uploadCalls = 0;
      int loginCalls = 0;
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.path.contains('/user/login/')) {
          loginCalls += 1;
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{'id': 1},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
              'set-cookie': <String>['sessionid=always-rejected; Path=/'],
            },
          );
        }
        uploadCalls += 1;
        return _jsonResponse(<String, dynamic>{
          'code': 401,
          'data': <String, dynamic>{},
          'msg': 'Authentication credentials were not provided.',
        }, 401);
      });

      final XingzheClient client = XingzheClient(
        username: 'user@example.com',
        password: 'pass',
        sessionId: 'stale-session',
        dio: dio,
        settingsService: SettingsService(store: store),
      );

      await expectLater(
        () => client.uploadFitDetailed(fitFile, retries: 1),
        throwsA(
          isA<XingzhePermanentError>().having(
            (XingzhePermanentError error) => error.message,
            'message',
            contains('自动重新登录后仍被拒绝'),
          ),
        ),
      );
      expect(loginCalls, 1);
      expect(uploadCalls, 2);
    });

    test('未保存用户名/密码时不做登录尝试，直接报永久错误', () async {
      final File fitFile = await createFitFile('xz-refresh-nocreds-');

      int loginCalls = 0;
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.path.contains('/user/login/')) {
          loginCalls += 1;
        }
        return _jsonResponse(<String, dynamic>{
          'code': 401,
          'data': <String, dynamic>{},
          'msg': 'Authentication credentials were not provided.',
        }, 401);
      });

      final XingzheClient client = XingzheClient(
        username: '',
        password: '',
        dio: dio,
        settingsService: SettingsService(store: _FakeSettingsStore()),
      );

      await expectLater(
        () => client.uploadFitDetailed(fitFile, retries: 1),
        throwsA(
          isA<XingzhePermanentError>().having(
            (XingzhePermanentError error) => error.message,
            'message',
            contains('无法自动重新登录'),
          ),
        ),
      );
      expect(loginCalls, 0);
    });

    test('400 之类的非认证错误不触发重新登录', () async {
      final File fitFile = await createFitFile('xz-no-relogin-');

      int loginCalls = 0;
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.path.contains('/user/login/')) {
          loginCalls += 1;
        }
        return _jsonResponse(<String, dynamic>{
          'code': 1001,
          'msg': 'invalid fit',
        }, 400);
      });

      final XingzheClient client = XingzheClient(
        username: 'user@example.com',
        password: 'pass',
        dio: dio,
        settingsService: SettingsService(store: _FakeSettingsStore()),
      );

      await expectLater(
        () => client.uploadFitDetailed(fitFile, retries: 1),
        throwsA(isA<XingzhePermanentError>()),
      );
      expect(loginCalls, 0);
    });

    test('body code 401（HTTP 200）也按会话失效处理', () async {
      final File fitFile = await createFitFile('xz-body-401-');

      int uploadCalls = 0;
      int loginCalls = 0;
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.path.contains('/user/login/')) {
          loginCalls += 1;
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{'id': 1},
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
              'set-cookie': <String>['sessionid=body-401-fresh; Path=/'],
            },
          );
        }
        uploadCalls += 1;
        if (uploadCalls == 1) {
          return _jsonResponse(<String, dynamic>{
            'code': 401,
            'data': <String, dynamic>{},
            'msg': 'Authentication credentials were not provided.',
          }, 200);
        }
        return _jsonResponse(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{'workout_id': 99},
        }, 200);
      });

      final XingzheClient client = XingzheClient(
        username: 'user@example.com',
        password: 'pass',
        dio: dio,
        settingsService: SettingsService(store: _FakeSettingsStore()),
      );

      final XingzheUploadFitResult result = await client.uploadFitDetailed(
        fitFile,
        retries: 1,
      );

      expect(result.uploadId, 99);
      expect(loginCalls, 1);
      expect(uploadCalls, 2);
    });
  });
}
