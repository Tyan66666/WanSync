import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'settings_service.dart';
import 'package:encrypt/encrypt.dart';
import 'package:http_parser/http_parser.dart';

class XingzheRetriableError implements Exception {
  final String message;

  /// 服务端状态码（5xx 等可重试错误时可用）。
  final int? statusCode;

  const XingzheRetriableError(this.message, {this.statusCode});
  @override
  String toString() => 'XingzheRetriableError: $message';
}

/// 行者登录态失效（session 过期 / 被踢下线 / 从未登录）。
///
/// 行者 API 在未认证时返回 HTTP 401，响应体为
/// `{"code":401,"data":{},"msg":"Authentication credentials were not provided."}`。
/// 这是内部信号：`uploadFitDetailed` 捕获后会尝试自动重新登录并重传。
class _XingzheSessionExpiredError implements Exception {
  const _XingzheSessionExpiredError(this.detail);

  final String detail;

  @override
  String toString() => '_XingzheSessionExpiredError: $detail';
}

class XingzhePermanentError implements Exception {
  final String message;
  const XingzhePermanentError(this.message);
  @override
  String toString() => 'XingzhePermanentError: $message';
}

class XingzheUploadFitResult {
  const XingzheUploadFitResult({
    required this.uploadId,
    this.remoteActivityId,
    this.alreadyUploaded = false,
    this.message,
  });

  final int uploadId;
  final int? remoteActivityId;
  final bool alreadyUploaded;
  final String? message;
}

class XingzheClient {
  String username;
  String password;
  String? authToken;
  String? sessionId;
  final Dio _dio;
  final SettingsService _settings;

  /// 单飞：并发上传同时撞到会话失效时共用同一次重新登录。
  Future<void>? _sessionRefresh;

  XingzheClient({
    required this.username,
    required this.password,
    this.authToken,
    this.sessionId,
    Dio? dio,
    SettingsService? settingsService,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 30),
               headers: {
                 'User-Agent':
                     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36',
                 'Accept-Encoding': 'gzip, deflate',
               },
             ),
           ),
       _settings = settingsService ?? SettingsService() {
    final String? currentSessionId = sessionId;
    if (currentSessionId != null && currentSessionId.isNotEmpty) {
      _dio.options.headers['Cookie'] =
          'sessionid=$currentSessionId; _XingzheWeb_Token=true';
    }
  }

  static Future<XingzheClient> create({
    required String username,
    required String password,
    Dio? dio,
  }) async {
    final settingsService = SettingsService();
    final settings = await settingsService.loadSettings();
    final sessionId = settings[SettingsService.keyXingzheSessionId];

    return XingzheClient(
      username: username,
      password: password,
      dio: dio,
      sessionId: sessionId,
      settingsService: settingsService,
    );
  }

  static const String publicKey = '''-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDmuQkBbijudDAJgfffDeeIButq
WHZvUwcRuvWdg89393FSdz3IJUHc0rgI/S3WuU8N0VePJLmVAZtCOK4qe4FY/eKm
WpJmn7JfXB4HTMWjPVoyRZmSYjW4L8GrWmh51Qj7DwpTADadF3aq04o+s1b8LXJa
8r6+TIqqL5WUHtRqmQIDAQAB
-----END PUBLIC KEY-----
''';

  static String _statusSummary(
    int? statusCode, {
    String fallback = 'request failed',
  }) {
    if (statusCode == null) {
      return fallback;
    }
    return '$fallback: HTTP $statusCode';
  }

  static String _sanitizeDetail(Object? detail, {required String fallback}) {
    if (detail == null) {
      return fallback;
    }

    final raw = '$detail'.trim();
    if (raw.isEmpty || raw.toLowerCase() == 'null') {
      return fallback;
    }

    var sanitized = raw;
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'([\w.+-]+@[\w.-]+)'),
      (_) => '[redacted-email]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'sessionid=[^\s,;]+', caseSensitive: false),
      (_) => 'sessionid=[redacted]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'password=[^\s,;]+', caseSensitive: false),
      (_) => 'password=[redacted]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'authorization=.*?(?=\s+\w+=|$)', caseSensitive: false),
      (_) => 'authorization=[redacted]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'encrypted_password=[^\s,;]+', caseSensitive: false),
      (_) => 'encrypted_password=[redacted]',
    );

    return sanitized.isEmpty ? fallback : sanitized;
  }

  static String _statusWithDetail(
    int? statusCode,
    Object? detail, {
    required String fallback,
  }) {
    final summary = _statusSummary(statusCode, fallback: fallback);
    final sanitized = _sanitizeDetail(detail, fallback: fallback);
    if (sanitized == fallback) {
      return summary;
    }
    return '$summary: $sanitized';
  }

  static String encryptPassword(String password) {
    final parser = RSAKeyParser();
    final rsaPublicKey = parser.parse(publicKey) as RSAPublicKey;

    // 使用 PKCS1_v1_5 加密模式，与 Python 版本一致
    final cipher = PKCS1Encoding(RSAEngine());
    cipher.init(true, PublicKeyParameter<RSAPublicKey>(rsaPublicKey));

    final passwordBytes = utf8.encode(password);
    final encryptedBytes = cipher.process(passwordBytes);
    return base64.encode(encryptedBytes);
  }

  static Future<XingzheClient> login({
    required String username,
    required String password,
    Dio? dio,
    SettingsService? settingsService,
  }) async {
    final SettingsService effectiveSettings =
        settingsService ?? SettingsService();
    final dioInstance =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 30),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36',
              'Accept-Encoding': 'gzip, deflate',
              'Content-Type': 'application/json',
            },
          ),
        );

    final encryptedPassword = encryptPassword(password);
    Response response;
    try {
      response = await dioInstance.post(
        'https://www.imxingzhe.com/api/v1/user/login/',
        data: {'account': username, 'password': encryptedPassword},
        options: Options(contentType: 'application/json'),
      );
    } on DioException catch (e) {
      throw XingzhePermanentError(
        _statusSummary(e.response?.statusCode, fallback: '行者登录失败'),
      );
    }

    if (response.statusCode != 200) {
      throw XingzhePermanentError('行者登录失败: ${response.statusCode}');
    }

    final payload = response.data as Map<String, dynamic>;
    if (payload['data'] == null) {
      throw const XingzhePermanentError('行者登录失败');
    }

    // 从响应头中提取 cookies
    final setCookie = response.headers['set-cookie'];
    final String extractedSessionId = setCookie != null
        ? _extractSessionId(setCookie)
        : '';

    if (extractedSessionId.isNotEmpty) {
      dioInstance.options.headers['Cookie'] =
          'sessionid=$extractedSessionId; _XingzheWeb_Token=true';
      try {
        await effectiveSettings.saveSettings({
          SettingsService.keyXingzheSessionId: extractedSessionId,
          SettingsService.keyXingzheUsername: username,
          SettingsService.keyXingzhePassword: password,
        });
      } on Exception {
        // 会话已经可用，落盘失败不该让登录整体失败；最坏情况是下次启动
        // 读到旧 sessionid，再走一次自动重新登录。
      }
    }

    return XingzheClient(
      username: username,
      password: password,
      authToken: null,
      dio: dioInstance,
      sessionId: extractedSessionId.isNotEmpty ? extractedSessionId : null,
      settingsService: effectiveSettings,
    );
  }

  /// 从 Set-Cookie header 列表中提取 sessionid
  static String _extractSessionId(List<String> setCookies) {
    for (final cookie in setCookies) {
      final match = RegExp(r'sessionid=([^;]+)').firstMatch(cookie);
      if (match != null) {
        return match.group(1)!;
      }
    }
    return '';
  }

  Future<void> ensureAuthenticated() async {
    // 依赖 session 保持认证状态；失效时由上传流程自动重新登录。
  }

  static bool _isSessionExpiredStatus(int? statusCode) {
    return statusCode == 401 || statusCode == 403;
  }

  /// 用已保存的用户名/密码重新登录，刷新同一个 Dio 上的 Cookie 并落盘新的
  /// sessionid。并发调用共用同一次登录（单飞）。
  Future<void> _reauthenticateSession() {
    return _sessionRefresh ??= _performReauthentication().whenComplete(() {
      _sessionRefresh = null;
    });
  }

  Future<void> _performReauthentication() async {
    final String effectiveUsername = username.trim();
    final String effectivePassword = password;

    if (effectiveUsername.isEmpty || effectivePassword.isEmpty) {
      throw const XingzhePermanentError(
        '行者会话已失效(401)，且未保存行者用户名/密码，无法自动重新登录，请在设置 → 行者 中重新登录',
      );
    }

    final XingzheClient refreshed;
    try {
      refreshed = await XingzheClient.login(
        username: effectiveUsername,
        password: effectivePassword,
        dio: _dio,
        settingsService: _settings,
      );
    } on XingzhePermanentError catch (error) {
      throw XingzhePermanentError(
        '行者会话已失效(401)，自动重新登录失败：${error.message}，请在设置 → 行者 中重新登录',
      );
    }

    final String? newSessionId = refreshed.sessionId;
    if (newSessionId == null || newSessionId.isEmpty) {
      throw const XingzhePermanentError(
        '行者会话已失效(401)，自动重新登录未拿到新的会话，请在设置 → 行者 中重新登录',
      );
    }

    sessionId = newSessionId;
  }

  Future<int> uploadFit(File file, {int retries = 3}) async {
    final XingzheUploadFitResult result = await uploadFitDetailed(
      file,
      retries: retries,
    );
    return result.remoteActivityId ?? result.uploadId;
  }

  Future<XingzheUploadFitResult> uploadFitDetailed(
    File file, {
    int retries = 3,
  }) async {
    final int maxAttempts = retries < 1 ? 1 : retries;
    var sessionRefreshed = false;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _uploadOnce(file);
      } on _XingzheSessionExpiredError catch (error) {
        // 行者会话失效（HTTP 401/403）：自动重新登录一次后重传。
        if (sessionRefreshed) {
          throw XingzhePermanentError(
            '行者登录已失效(401)，自动重新登录后仍被拒绝，'
            '请在设置 → 行者 中重新登录（${error.detail}）',
          );
        }
        sessionRefreshed = true;
        await _reauthenticateSession();
        // 刷新会话不该消耗原本的上传重试预算。
        attempt -= 1;
        continue;
      } on XingzheRetriableError catch (error) {
        // 历史行为保留：5xx 里的 500 也顺手刷新一次会话，但登录失败不阻断
        // 5xx 本身的重试（真正的登录失效已由上面的 401 分支处理）。
        if (error.statusCode == 500 && !sessionRefreshed) {
          sessionRefreshed = true;
          try {
            await _reauthenticateSession();
          } on Exception {
            // 忽略：5xx 仍是可重试错误，交给下面的重试逻辑。
          }
          attempt -= 1;
          continue;
        }
        if (attempt < maxAttempts) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        rethrow;
      }
    }
    throw XingzheRetriableError('xingzhe upload exhausted retries');
  }

  Future<XingzheUploadFitResult> _uploadOnce(File file) async {
    final String filename = file.path.split('/').last;

    Response response;
    try {
      // 计算文件的 MD5 哈希值
      final fileBytes = await file.readAsBytes();
      final md5Hash = md5.convert(fileBytes).toString();

      // 构建 FormData
      final formData = FormData.fromMap({
        'file_source': 'undefined',
        'fit_filename': filename,
        'md5': md5Hash,
        'name': filename,
        'sport': '3',
        'fit_file': await MultipartFile.fromFile(
          file.path,
          filename: filename,
          contentType: MediaType('application', 'octet-stream'),
        ),
      });

      // 发送上传请求
      response = await _dio.post(
        'https://www.imxingzhe.com/api/v1/fit/upload/',
        data: formData,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => true,
        ),
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      if (_isSessionExpiredStatus(status)) {
        throw _XingzheSessionExpiredError(
          _statusWithDetail(
            status,
            e.response?.data is Map<String, dynamic>
                ? (e.response?.data as Map<String, dynamic>)['msg']
                : null,
            fallback: 'xingzhe session expired',
          ),
        );
      }
      if (status >= 500) {
        throw XingzheRetriableError(
          'xingzhe upload 5xx: $status',
          statusCode: status,
        );
      }
      if (status >= 400) {
        throw XingzhePermanentError(
          _statusWithDetail(
            status,
            e.response?.data is Map<String, dynamic>
                ? (e.response?.data as Map<String, dynamic>)['msg']
                : e.response?.data,
            fallback: 'xingzhe upload failed',
          ),
        );
      }
      rethrow;
    }

    final int? statusCode = response.statusCode;
    final Object? responseBody = response.data;
    final Map<String, dynamic>? body = responseBody is Map<String, dynamic>
        ? responseBody
        : null;
    final int? bodyCode = body?['code'] is num
        ? (body!['code'] as num).toInt()
        : null;

    // 会话失效：行者 API 未认证时返回 HTTP 401 + body code 401。
    if (_isSessionExpiredStatus(statusCode) || bodyCode == 401) {
      throw _XingzheSessionExpiredError(
        _statusWithDetail(
          statusCode,
          body?['msg'],
          fallback: 'xingzhe session expired',
        ),
      );
    }

    // 5xx 是服务端/网关瞬时错误（含 502 Bad Gateway、503、504 等）。
    // 注意：本请求使用 validateStatus 始终返回 true，Dio 不会为 5xx
    // 抛出 DioException，因此重试逻辑由上层 uploadFitDetailed 处理。
    if (statusCode != null && statusCode >= 500) {
      throw XingzheRetriableError(
        'xingzhe upload 5xx: $statusCode',
        statusCode: statusCode,
      );
    }

    if (body == null) {
      throw XingzhePermanentError(
        _statusSummary(
          statusCode,
          fallback: 'xingzhe upload returned unexpected response type',
        ),
      );
    }

    final payload = body;

    // 9006 = 文件已上传（幂等成功），从 msg 中提取已存在的 activity_id
    if (payload['code'] == 9006) {
      final msg = '${payload['msg'] ?? ''}';
      final match = RegExp(r'(\d{4,})').firstMatch(msg);
      final existingId = match != null ? int.tryParse(match.group(1)!) ?? 0 : 0;
      return XingzheUploadFitResult(
        uploadId: 0,
        remoteActivityId: existingId > 0 ? existingId : null,
        alreadyUploaded: true,
        message: msg,
      );
    }

    if (statusCode != null && statusCode >= 400) {
      throw XingzhePermanentError(
        _statusWithDetail(
          statusCode,
          payload['msg'],
          fallback: 'xingzhe upload failed',
        ),
      );
    }

    if (payload['code'] != 0) {
      throw XingzhePermanentError(
        _sanitizeDetail(payload['msg'], fallback: 'xingzhe upload failed'),
      );
    }

    // 行者上传成功后返回 workout_id，即真实活动 ID
    final data = payload['data'] as Map<String, dynamic>?;
    final workoutIdRaw = data?['workout_id'] ?? data?['id'];
    if (workoutIdRaw == null) {
      return const XingzheUploadFitResult(uploadId: 0);
    }
    final int workoutId = workoutIdRaw is int
        ? workoutIdRaw
        : int.tryParse('$workoutIdRaw') ?? 0;
    return XingzheUploadFitResult(
      uploadId: workoutId,
      remoteActivityId: workoutId > 0 ? workoutId : null,
    );
  }

  Future<Map<String, dynamic>> pollUpload(
    int uploadId, {
    int maxAttempts = 10,
  }) async {
    // 行者上传接口是同步的，uploadFit 返回的 workout_id 就是真实活动 ID
    // pollUpload 在这里只做兜底：如果 uploadId 为 0（之前没拿到 workout_id），
    // 尝试通过 MD5 查一下已上传的活动。
    if (uploadId > 0) {
      return {'status': 'complete', 'activity_id': uploadId};
    }

    // 兜底查询（uploadId=0 时才走到这里）
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final resp = await _dio.get(
          'https://www.imxingzhe.com/api/v1/fit/list/',
        );
        final payload = resp.data as Map<String, dynamic>;
        if (payload['code'] == 0) {
          final List<dynamic> items = payload['data'] as List<dynamic>? ?? [];
          if (items.isNotEmpty) {
            final latest = items.first as Map<String, dynamic>;
            final id = latest['id'] ?? latest['workout_id'];
            return {'status': 'complete', 'activity_id': id};
          }
        }
      } on DioException catch (e) {
        // 兜底查询撞到会话失效时也顺手刷新一次，让后续尝试恢复正常。
        if (_isSessionExpiredStatus(e.response?.statusCode)) {
          try {
            await _reauthenticateSession();
          } on Exception {
            // 兜底查询不保证成功，刷新失败就算了。
          }
        }
      } catch (_) {
        // Ignore fallback lookup failures and keep polling.
      }
      if (attempt < maxAttempts - 1) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    return {'status': 'unknown', 'activity_id': null};
  }
}
