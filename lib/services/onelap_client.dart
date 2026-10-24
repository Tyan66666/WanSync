import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../models/onelap_activity.dart';

class OnelapRiskControlError implements Exception {
  final String message;
  const OnelapRiskControlError(this.message);
  @override
  String toString() => 'OnelapRiskControlError: $message';
}

class _OneLapDetailRequestFailed implements Exception {
  final String message;
  const _OneLapDetailRequestFailed(this.message);

  @override
  String toString() => message;
}

class _RecordIdFitEmptyBodyError implements Exception {
  const _RecordIdFitEmptyBodyError();

  @override
  String toString() => 'recordId FIT endpoint returned an empty body';
}

/// 单页记录列表的解析结果。
class _ActivitiesPage {
  final List<dynamic> list;
  final bool hasMore;

  const _ActivitiesPage({required this.list, required this.hasMore});
}

/// 一次记录拉取的结果。
///
/// 除活动列表外还带回诊断计数，用于区分「服务端没有记录」和「本地被过滤掉」，
/// 避免同步结果页把这两种情况混为一谈。
class OneLapActivityQuery {
  /// 需要同步的活动（已按日期范围过滤）。
  final List<OneLapActivity> activities;

  /// 服务端实际返回的原始条数（跨页累计）。
  final int serverReturned;

  /// 因早于起始日期被跳过的条数。
  final int outOfRange;

  /// 因缺少 id 或无法解析起始时间被跳过的条数。
  final int invalid;

  /// 实际请求的页数。
  final int pagesFetched;

  /// 查询的日期范围（`yyyy-MM-dd`），用于结果展示。
  final String rangeStart;
  final String rangeEnd;

  const OneLapActivityQuery({
    this.activities = const <OneLapActivity>[],
    this.serverReturned = 0,
    this.outOfRange = 0,
    this.invalid = 0,
    this.pagesFetched = 0,
    this.rangeStart = '',
    this.rangeEnd = '',
  });

  /// 服务端有数据但一条都没落到 [activities] 里的条数。
  int get skipped => outOfRange + invalid;
}

class OneLapClient {
  static const String _recordIdFallbackBaseUrl = 'https://u.onelap.cn';

  /// 服务端 `limit` 上限为 50，超出无效。
  static const int _pageSize = 50;

  /// 翻页次数上限，防止服务端分页信息异常时死循环。
  static const int _maxPages = 10;

  final String baseUrl;
  final String username;
  final String password;
  final List<String> geoFallbackBaseUrls;
  final String otmBaseUrl;
  late final Dio _dio;
  String? _token;
  String? _refreshToken;

  OneLapClient({
    required this.baseUrl,
    required this.username,
    required this.password,
    this.geoFallbackBaseUrls = const <String>[
      'https://u.onelap.cn',
      'https://www.onelap.cn',
    ],
    this.otmBaseUrl = 'https://otm.onelap.cn',
    Dio? dio,
  }) {
    final cookieJar = CookieJar();
    _dio =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );
    _dio.interceptors.add(CookieManager(cookieJar));
  }

  Future<void> login() async {
    final response = await _dio.post(
      '$baseUrl/api/login',
      data: FormData.fromMap({'account': username, 'password': _passwordHash}),
    );
    _cacheAuthFromLoginPayload(response.data as Map<String, dynamic>);
  }

  String get _passwordHash => md5.convert(utf8.encode(password)).toString();

  Future<List<OneLapActivity>> listFitActivities({
    required DateTime since,
    int limit = 50,
  }) async {
    final OneLapActivityQuery query = await fetchActivities(
      since: since,
      limit: limit,
    );
    return query.activities;
  }

  /// 拉取 [since] 之后（含）的活动。
  ///
  /// 日期范围会直接下发给服务端（`start_date` / `end_date`，与网页版
  /// otm.onelap.cn/recordPage 的查询方式一致），因此不再受「最新 N 条」
  /// 窗口的隐形限制；需要时按服务端分页继续翻页。
  Future<OneLapActivityQuery> fetchActivities({
    required DateTime since,
    DateTime? until,
    int limit = 50,
  }) async {
    final String rangeStart = _formatDate(since);
    final String rangeEnd = _formatDate(until ?? DateTime.now());
    final int maxResults = limit < 0 ? 0 : (limit > 500 ? 500 : limit);
    if (maxResults == 0) {
      return OneLapActivityQuery(rangeStart: rangeStart, rangeEnd: rangeEnd);
    }

    final List<dynamic> items = <dynamic>[];
    final int requestPageSize = maxResults < _pageSize ? maxResults : _pageSize;
    int pagesFetched = 0;
    int page = 1;
    bool hasMore = true;
    while (hasMore && items.length < maxResults && pagesFetched < _maxPages) {
      final _ActivitiesPage payload = await _fetchActivitiesPayload(
        page: page,
        limit: requestPageSize,
        startDate: rangeStart,
        endDate: rangeEnd,
      );
      items.addAll(payload.list);
      pagesFetched++;
      hasMore = payload.hasMore && payload.list.isNotEmpty;
      page++;
    }

    int outOfRange = 0;
    int invalid = 0;
    final result = <OneLapActivity>[];

    for (final raw in items) {
      final map = raw as Map<String, dynamic>;
      final activityId = '${map['id'] ?? map['activity_id'] ?? ''}'.trim();
      final startTime = _parseStartTime(map);
      final startDate = _dateOnly(startTime);
      if (activityId.isEmpty || startDate.isEmpty) {
        invalid++;
        continue;
      }
      if (startDate.compareTo(rangeStart) < 0) {
        outOfRange++;
        continue;
      }

      var rawFitUrl = '${map['fit_url'] ?? ''}'.trim();
      var rawFitUrlAlt = '${map['fitUrl'] ?? ''}'.trim();
      var rawDurl = '${map['durl'] ?? ''}'.trim();
      var rawFileKey = '${map['fileKey'] ?? ''}'.trim();
      var recordKey = _buildRecordIdentity(map).$1;
      if (recordKey.isEmpty) {
        recordKey = 'recordId:$activityId';
      }
      var sourceFilename = _buildSourceFilename(map, startTime);

      double? detailDistanceKm;
      int? detailTimeSeconds;

      try {
        final Map<String, dynamic> detail = await _fetchRideRecordDetail(
          activityId,
        );
        final (detailRecordKey, _) = _buildRecordIdentity(detail);
        if (detailRecordKey.isNotEmpty) {
          recordKey = detailRecordKey;
        }

        final String detailFitUrl = '${detail['fit_url'] ?? ''}'.trim();
        final String detailFitUrlAlt = '${detail['fitUrl'] ?? ''}'.trim();
        final String detailDurl = '${detail['durl'] ?? ''}'.trim();
        final String detailFileKey = '${detail['fileKey'] ?? ''}'.trim();

        final num? distRaw = detail['totalDistance'] as num?;
        final num? timeRaw = detail['time'] as num?;
        if (distRaw != null) detailDistanceKm = distRaw.toDouble() / 1000;
        if (timeRaw != null) detailTimeSeconds = timeRaw.toInt();

        if (detailFitUrl.isNotEmpty) {
          rawFitUrl = detailFitUrl;
        }
        if (detailFitUrlAlt.isNotEmpty) {
          rawFitUrlAlt = detailFitUrlAlt;
        }
        if (detailDurl.isNotEmpty) {
          rawDurl = detailDurl;
        }
        if (detailFileKey.isNotEmpty) {
          rawFileKey = detailFileKey;
        }
      } on DioException catch (error) {
        if (_isAuthFailureStatus(error.response?.statusCode)) {
          rethrow;
        }
      } on _OneLapDetailRequestFailed {
        // Keep the best identity we already have from the list payload.
      }

      final fitUrl = _selectDownloadUrl(
        rawDurl: rawDurl,
        rawFitUrl: rawFitUrl,
        rawFitUrlAlt: rawFitUrlAlt,
        recordKey: recordKey,
      );

      result.add(
        OneLapActivity(
          activityId: activityId,
          recordId: activityId,
          startTime: startTime,
          fitUrl: fitUrl,
          recordKey: recordKey,
          sourceFilename: sourceFilename,
          rawFitUrl: rawFitUrl.isEmpty ? null : rawFitUrl,
          rawFitUrlAlt: rawFitUrlAlt.isEmpty ? null : rawFitUrlAlt,
          rawDurl: rawDurl.isEmpty ? null : rawDurl,
          rawFileKey: rawFileKey.isEmpty ? null : rawFileKey,
          distanceKm: detailDistanceKm,
          timeSeconds: detailTimeSeconds,
        ),
      );
      if (result.length >= maxResults) break;
    }
    return OneLapActivityQuery(
      activities: result,
      serverReturned: items.length,
      outOfRange: outOfRange,
      invalid: invalid,
      pagesFetched: pagesFetched,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );
  }

  Future<_ActivitiesPage> _fetchActivitiesPayload({
    required int page,
    required int limit,
    required String startDate,
    required String endDate,
  }) async {
    final Response<dynamic> response = await _withAuthenticatedOtmRequest(
      (String token) => _dio.post<dynamic>(
        '$otmBaseUrl/api/otm/ride_record/list',
        data: <String, dynamic>{
          'page': page,
          'limit': limit,
          'start_date': startDate,
          'end_date': endDate,
        },
        options: Options(headers: <String, String>{'Authorization': token}),
      ),
    );

    final dynamic payload = response.data;
    if (payload is! Map<String, dynamic>) {
      throw Exception('OneLap activities payload is invalid');
    }

    final Object? code = payload['code'];
    if (code != 200) {
      final String message =
          '${payload['msg'] ?? payload['message'] ?? payload['error'] ?? 'unknown'}';
      if (_looksLikeRiskControl(payload, message)) {
        throw OnelapRiskControlError(message);
      }
      throw Exception('OneLap activities request failed: $message');
    }

    final dynamic data = payload['data'];
    if (data is! Map<String, dynamic>) {
      throw Exception('OneLap activities payload is invalid');
    }

    final dynamic list = data['list'];
    if (list is! List) {
      throw Exception('OneLap activities payload is invalid');
    }

    final dynamic pagination = data['pagination'];
    bool hasMore = false;
    if (pagination is Map) {
      final dynamic flag = pagination['has_more'];
      if (flag is bool) {
        hasMore = flag;
      }
    }

    return _ActivitiesPage(list: list, hasMore: hasMore);
  }

  bool _looksLikeRiskControl(Map<String, dynamic> payload, String message) {
    final Object? code = payload['code'];
    if (code == -2) {
      return true;
    }

    final String normalizedMessage = message.toLowerCase();
    final String normalizedError = '${payload['error'] ?? ''}'.toLowerCase();

    return normalizedMessage.contains('risk control') ||
        normalizedMessage.contains('risk_control') ||
        normalizedMessage.contains('风控') ||
        normalizedError.contains('risk control') ||
        normalizedError.contains('risk_control') ||
        normalizedError.contains('风控');
  }

  Future<Map<String, dynamic>> _fetchRideRecordDetail(String recordId) async {
    final Response<dynamic> response = await _withAuthenticatedOtmRequest(
      (String token) => _dio.get<dynamic>(
        '$otmBaseUrl/api/otm/ride_record/analysis/$recordId',
        options: Options(headers: <String, String>{'Authorization': token}),
      ),
    );

    final dynamic payload = response.data;
    if (payload is! Map<String, dynamic>) {
      throw Exception('OneLap detail payload is invalid');
    }

    final Object? code = payload['code'];
    if (code != 200) {
      final String message =
          '${payload['msg'] ?? payload['message'] ?? payload['error'] ?? 'unknown'}';
      if (_looksLikeRiskControl(payload, message)) {
        throw OnelapRiskControlError(message);
      }
      throw _OneLapDetailRequestFailed(
        'OneLap detail request failed: $message',
      );
    }

    final dynamic data = payload['data'];
    if (data is! Map<String, dynamic>) {
      throw Exception('OneLap detail payload is invalid');
    }

    final dynamic ridingRecord = data['ridingRecord'];
    if (ridingRecord is Map<String, dynamic>) {
      return ridingRecord;
    }

    return data;
  }

  String _buildSourceFilename(Map<String, dynamic> raw, String startTime) {
    final String name = '${raw['name'] ?? ''}'.trim();
    if (name.isNotEmpty) {
      return name;
    }
    return startTime;
  }

  /// 列表项的时间字段并不稳定：实测 `start_time` 完全不存在，
  /// `created_at` 可能是占位值 `1970-01-01 08:00:00`，历史数据里也出现过
  /// 秒 / 毫秒时间戳。这里统一成北京时间墙钟的 `yyyy-MM-ddTHH:mm:ss`
  /// （不带时区后缀，与 OneLap 自身返回的本地时间口径一致），
  /// 无法识别时返回空串，由调用方计入 invalid 而不是静默丢弃。
  String _parseStartTime(Map<String, dynamic> raw) {
    for (final String key in _startTimeKeys) {
      final String parsed = _coerceTimeValue(raw[key]);
      if (parsed.isNotEmpty) return parsed;
    }
    return '';
  }

  static const List<String> _startTimeKeys = <String>[
    'start_time',
    'startRidingTime',
    'start_riding_time',
    'created_at',
    'createdAt',
  ];

  String _coerceTimeValue(Object? value) {
    if (value == null) return '';
    if (value is num) return _epochToBeijingIso(value.toInt());

    final String text = '$value'.trim();
    if (text.isEmpty) return '';
    if (RegExp(r'^\d{10}$|^\d{13}$').hasMatch(text)) {
      return _epochToBeijingIso(int.parse(text));
    }
    // OneLap 把空时间写成 Unix 纪元，即北京时间的 1970-01-01 08:00:00。
    if (text.startsWith('1970-01-01')) return '';
    return text;
  }

  String _epochToBeijingIso(int value) {
    final int millis = value > 9999999999 ? value : value * 1000;
    final DateTime utc = DateTime.fromMillisecondsSinceEpoch(
      millis,
      isUtc: true,
    );
    final DateTime beijing = utc.add(const Duration(hours: 8));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${beijing.year}-${two(beijing.month)}-${two(beijing.day)}'
        'T${two(beijing.hour)}:${two(beijing.minute)}:${two(beijing.second)}';
  }

  String _formatDate(DateTime value) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}-'
        '${two(value.month)}-${two(value.day)}';
  }

  /// 取出 `yyyy-MM-dd`（兼容 `yyyy/MM/dd`），失败返回空串。
  String _dateOnly(String value) {
    final match = RegExp(
      r'^(\d{4})[-/](\d{2})[-/](\d{2})',
    ).firstMatch(value.trim());
    if (match == null) return '';
    return '${match.group(1)}-${match.group(2)}-${match.group(3)}';
  }

  (String, String) _buildRecordIdentity(Map<String, dynamic> raw) {
    final fileKey = '${raw['fileKey'] ?? ''}'.trim();
    if (fileKey.isNotEmpty) return ('fileKey:$fileKey', fileKey);

    final fitUrl = '${raw['fit_url'] ?? ''}'.trim();
    if (fitUrl.isNotEmpty) return ('fitUrl:$fitUrl', fitUrl);

    final fitUrlAlt = '${raw['fitUrl'] ?? ''}'.trim();
    if (fitUrlAlt.isNotEmpty) return ('fitUrl:$fitUrlAlt', fitUrlAlt);

    final durl = '${raw['durl'] ?? ''}'.trim();
    if (durl.isNotEmpty) return ('durl:$durl', durl);

    return ('', '');
  }

  String _normalizeFitFilename(String value) {
    var text = value.trim();
    if (text.isEmpty) text = 'activity.fit';

    // Extract filename from URL path
    final uri = Uri.tryParse(text);
    var filename = (uri != null && uri.path.isNotEmpty)
        ? uri.path.split('/').last
        : text.split('/').last;

    filename = filename.replaceAll(RegExp(r'[<>:"/\\|?*]+'), '_').trim();
    if (filename.isEmpty) filename = 'activity';
    if (!filename.toLowerCase().endsWith('.fit')) filename = '$filename.fit';
    return filename;
  }

  Future<bool> _isValidFitContent(File file) async {
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        if (await raf.length() < 14) return false;
        await raf.setPosition(8);
        final Uint8List magic = Uint8List(4);
        await raf.readInto(magic);
        return magic[0] == 0x2E &&
            magic[1] == 0x46 &&
            magic[2] == 0x49 &&
            magic[3] == 0x54;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  String _selectDownloadUrl({
    required String rawDurl,
    required String rawFitUrl,
    required String rawFitUrlAlt,
    required String recordKey,
  }) {
    if (rawDurl.isNotEmpty) return rawDurl;
    if (rawFitUrl.isNotEmpty) return rawFitUrl;
    if (rawFitUrlAlt.isNotEmpty) return rawFitUrlAlt;
    if (recordKey.startsWith('fileKey:')) {
      return recordKey.substring('fileKey:'.length);
    }
    return '';
  }

  Future<File> downloadFit(
    String fitUrl,
    String sourceFilename,
    Directory outputDir, {
    OneLapActivity? activity,
  }) async {
    final List<String> downloadUrls = _buildDownloadUrls(
      fitUrl,
      activity: activity,
    );

    final safeName = _normalizeFitFilename(sourceFilename);
    await outputDir.create(recursive: true);
    final targetPath = File('${outputDir.path}/$safeName');

    // Download to temp file
    final tempPath = File(
      '${outputDir.path}/.${safeName}_${DateTime.now().millisecondsSinceEpoch}.tmp',
    );
    try {
      bool downloaded = false;
      final String? recordId = activity?.recordId?.trim();
      if (recordId != null && recordId.isNotEmpty) {
        try {
          await _downloadViaRecordId(
            recordId,
            tempPath,
            allowHostFallback: downloadUrls.isEmpty,
          );
          downloaded = true;
        } on DioException catch (error) {
          if (_isAuthFailureStatus(error.response?.statusCode) ||
              downloadUrls.isEmpty) {
            rethrow;
          }
        } on _RecordIdFitEmptyBodyError {
          rethrow;
        }
      }

      DioException? lastError;
      if (!downloaded) {
        for (var i = 0; i < downloadUrls.length; i++) {
          final String downloadUrl = downloadUrls[i];
          try {
            await _dio.download(downloadUrl, tempPath.path);
            lastError = null;
            if (await _isValidFitContent(tempPath)) {
              downloaded = true;
              break;
            }
            if (await tempPath.exists()) {
              await tempPath.delete().catchError((_) => tempPath);
            }
          } on DioException catch (e) {
            lastError = e;
            final int? statusCode = e.response?.statusCode;
            final bool canFallback =
                statusCode != null &&
                statusCode != 200 &&
                (i < downloadUrls.length - 1 || activity != null);
            if (!canFallback) rethrow;
            if (await tempPath.exists()) {
              await tempPath.delete().catchError((_) => tempPath);
            }
          }
        }
      }

      if (!downloaded && activity != null) {
        await _downloadViaOtmFallback(activity, tempPath);
        downloaded = true;
        lastError = null;
      }

      if (lastError != null) throw lastError;
    } catch (_) {
      await tempPath.delete().catchError((_) => tempPath);
      rethrow;
    }

    // SHA-256 dedup
    final tempBytes = await tempPath.readAsBytes();
    final tempHash = sha256.convert(tempBytes).toString();

    if (await targetPath.exists()) {
      final existingHash = sha256
          .convert(await targetPath.readAsBytes())
          .toString();
      if (existingHash == tempHash) {
        await tempPath.delete();
        return targetPath;
      }
      // Different content — find a unique name
      var index = 2;
      while (true) {
        final stem = safeName.replaceAll(
          RegExp(r'\.fit$', caseSensitive: false),
          '',
        );
        final candidate = File('${outputDir.path}/$stem-$index.fit');
        if (!await candidate.exists()) {
          await tempPath.rename(candidate.path);
          return candidate;
        }
        final candidateHash = sha256
            .convert(await candidate.readAsBytes())
            .toString();
        if (candidateHash == tempHash) {
          await tempPath.delete();
          return candidate;
        }
        index++;
      }
    }

    await tempPath.rename(targetPath.path);
    return targetPath;
  }

  Future<void> _downloadViaRecordId(
    String recordId,
    File tempPath, {
    required bool allowHostFallback,
  }) async {
    Future<Response<List<int>>> fetchFromBaseUrl(String baseUrl) {
      return _withAuthenticatedOtmRequest(
        (String token) => _dio.get<List<int>>(
          '$baseUrl/api/otm/ride_record/analysis/fit_content/$recordId',
          options: Options(
            headers: <String, String>{'Authorization': token},
            responseType: ResponseType.bytes,
          ),
        ),
      );
    }

    Response<List<int>> response;
    try {
      response = await fetchFromBaseUrl(otmBaseUrl);
    } on DioException catch (originalError) {
      if (allowHostFallback && _shouldFallbackRecordIdFitHost(originalError)) {
        try {
          response = await fetchFromBaseUrl(_recordIdFallbackBaseUrl);
        } on DioException catch (fallbackError) {
          if (_isAuthFailureStatus(fallbackError.response?.statusCode)) {
            rethrow;
          }
          throw _withRecordIdFallbackDiagnostics(
            originalError,
            fallbackError,
            recordId,
          );
        }
      } else {
        rethrow;
      }
    }

    final List<int> bytes = response.data ?? <int>[];
    if (bytes.isEmpty) {
      throw const _RecordIdFitEmptyBodyError();
    }
    _throwIfErrorBody(
      bytes,
      response.headers,
      'recordId FIT endpoint returned an error body',
    );
    await tempPath.writeAsBytes(bytes, flush: true);
  }

  bool _shouldFallbackRecordIdFitHost(DioException error) {
    final int? statusCode = error.response?.statusCode;
    return statusCode != null &&
        !_isAuthFailureStatus(statusCode) &&
        statusCode >= HttpStatus.internalServerError &&
        geoFallbackBaseUrls.isNotEmpty;
  }

  DioException _withRecordIdFallbackDiagnostics(
    DioException originalError,
    DioException fallbackError,
    String recordId,
  ) {
    final Uri fallbackUri = Uri.parse(
      '$_recordIdFallbackBaseUrl/api/otm/ride_record/analysis/fit_content/$recordId',
    );
    final int? fallbackStatusCode = fallbackError.response?.statusCode;
    final String? fallbackContentType = fallbackError.response?.headers.value(
      Headers.contentTypeHeader,
    );
    final String fallbackStatusLabel = fallbackStatusCode == null
        ? 'status unknown'
        : 'status $fallbackStatusCode';
    final String fallbackContentTypeLabel =
        (fallbackContentType == null || fallbackContentType.isEmpty)
        ? 'content-type unknown'
        : 'content-type $fallbackContentType';

    return DioException(
      requestOptions: originalError.requestOptions,
      response: originalError.response,
      type: originalError.type,
      error: originalError.error,
      stackTrace: originalError.stackTrace,
      message:
          'HTTP ${originalError.response?.statusCode} | URL: ${originalError.requestOptions.uri} | '
          'Fallback host attempt: ${fallbackUri.toString()} | '
          '$fallbackStatusLabel | $fallbackContentTypeLabel',
    );
  }

  Future<void> _downloadViaOtmFallback(
    OneLapActivity activity,
    File tempPath,
  ) async {
    final String? filePath = _otmFitPath(activity);
    if (filePath == null || filePath.isEmpty) {
      throw Exception('OTM fallback requires fileKey or fitUrl path');
    }

    final String encodedPath = base64.encode(utf8.encode(filePath));
    final Response<List<int>> response = await _withAuthenticatedOtmRequest(
      (String token) => _getOtmFitContent(encodedPath, token),
    );

    final List<int> bytes = response.data ?? <int>[];
    if (bytes.isEmpty) {
      throw Exception('OTM fallback download returned empty body');
    }
    _throwIfErrorBody(
      bytes,
      response.headers,
      'OTM fallback returned an error body',
    );
    await tempPath.writeAsBytes(bytes, flush: true);
  }

  void _throwIfErrorBody(List<int> bytes, Headers headers, String message) {
    final String contentType =
        headers.value(Headers.contentTypeHeader)?.toLowerCase() ?? '';
    if (contentType.contains('application/json') ||
        contentType.contains('text/html') ||
        contentType.contains('text/plain')) {
      throw Exception(message);
    }

    final String? decoded = _tryDecodeUtf8(bytes);
    if (decoded == null) {
      return;
    }

    final String trimmed = decoded.trimLeft();
    if (trimmed.startsWith('{') ||
        trimmed.startsWith('[') ||
        trimmed.startsWith('<!doctype html') ||
        trimmed.startsWith('<html') ||
        trimmed.startsWith('<?xml') ||
        trimmed.startsWith('<body')) {
      throw Exception(message);
    }
  }

  String? _tryDecodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(Uint8List.fromList(bytes), allowMalformed: false);
    } on FormatException {
      return null;
    }
  }

  Future<Response<List<int>>> _getOtmFitContent(
    String encodedPath,
    String token,
  ) {
    return _dio.get<List<int>>(
      '$otmBaseUrl/api/otm/ride_record/analysis/fit_content/$encodedPath',
      options: Options(
        headers: <String, String>{'Authorization': token},
        responseType: ResponseType.bytes,
      ),
    );
  }

  Future<T> _withAuthenticatedOtmRequest<T>(
    Future<T> Function(String token) request,
  ) async {
    final String initialToken = await _fetchOtmToken();
    try {
      return await request(initialToken);
    } on DioException catch (error) {
      if (!_isAuthFailureStatus(error.response?.statusCode)) {
        rethrow;
      }
    }

    final bool refreshed = await _refreshOtmToken();
    if (refreshed) {
      try {
        return await request(_token!);
      } on DioException catch (error) {
        if (!_isAuthFailureStatus(error.response?.statusCode)) {
          rethrow;
        }
      }
    }

    _token = null;
    _refreshToken = null;
    await login();
    return request(_token!);
  }

  bool _isAuthFailureStatus(int? statusCode) {
    return statusCode == HttpStatus.unauthorized ||
        statusCode == HttpStatus.forbidden;
  }

  Future<bool> _refreshOtmToken() async {
    final String refreshToken = _refreshToken?.trim() ?? '';
    if (refreshToken.isEmpty) {
      return false;
    }

    try {
      final Response<dynamic> response = await _dio.post(
        '$baseUrl/api/token',
        data: <String, String>{
          'token': refreshToken,
          'from': 'web',
          'to': 'web',
        },
      );
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      return _cacheAuthFromRefreshPayload(response.data);
    } on DioException {
      return false;
    }
  }

  String? _otmFitPath(OneLapActivity activity) {
    final List<String?> candidates = <String?>[
      activity.rawFileKey,
      activity.rawFitUrl,
      activity.rawFitUrlAlt,
      activity.fitUrl,
    ];

    for (final String? candidate in candidates) {
      final String value = candidate?.trim() ?? '';
      if (value.isEmpty) continue;
      if (value.startsWith('geo/')) return value;
      if (_isOtmMatchIdentifier(value)) return value;
      if (_isBareOnelapLogFilename(value)) return value;
      final Uri? uri = Uri.tryParse(value);
      if (uri != null && uri.path.startsWith('/geo/')) {
        return uri.path.replaceFirst(RegExp(r'^/'), '');
      }
    }
    return null;
  }

  bool _isOtmMatchIdentifier(String value) {
    if (!RegExp(
      r'^MATCH_\d{6,}-\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-log\.st$',
    ).hasMatch(value)) {
      return false;
    }
    if (value.contains(RegExp(r'\s'))) return false;
    if (value.contains('/')) return false;
    if (value.contains('?') || value.contains('#')) return false;

    final Uri? uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return false;
    if (value.startsWith('/')) return false;

    return true;
  }

  /// OneLap 新版记录可能把 fileKey 存成裸文件名（如
  /// `ONELAP_677767-2026-10-18-20-33-08.st`），不带 `geo/` 前缀。
  /// `fit_content/{base64(fileKey)}` 同样能把它转换成 FIT，所以这里接受
  /// 这种新的 ONELAP_ 前缀文件名；但必须排除完整 URL（例如签名后
  /// 的 durl）和无法识别的标识，避免把任意字符串当路径做 base64 编码。
  bool _isBareOnelapLogFilename(String value) {
    if (value.contains('/') || value.contains('\\')) return false;
    if (value.contains('?') || value.contains('#')) return false;

    final Uri? uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return false;

    return RegExp(
      r'^ONELAP_\d+-\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}\.(?:st|fit)$',
    ).hasMatch(value);
  }

  Future<String> _fetchOtmToken() async {
    final String? token = _token;
    if (token != null && token.isNotEmpty) {
      return token;
    }

    await login();
    return _token!;
  }

  bool _cacheAuthFromRefreshPayload(dynamic payload) {
    if (payload is! Map<String, dynamic>) {
      return false;
    }
    if (payload['code'] != 200) {
      return false;
    }

    final Object? rawData = payload['data'];
    final Map<String, dynamic> data = rawData is Map<String, dynamic>
        ? rawData
        : <String, dynamic>{};
    final String token = '${data['token'] ?? ''}'.trim();
    if (token.isEmpty) {
      return false;
    }

    _token = token;

    final String refreshedToken = '${data['refresh_token'] ?? ''}'.trim();
    if (refreshedToken.isNotEmpty) {
      _refreshToken = refreshedToken;
    }

    return true;
  }

  void _cacheAuthFromLoginPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != 0 && code != 200) {
      throw Exception(
        'OneLap login failed: ${payload['msg'] ?? payload['message'] ?? payload['error'] ?? 'unknown'}',
      );
    }

    final Object? rawData = payload['data'];
    final Map<String, dynamic> data;
    if (rawData is Map<String, dynamic>) {
      data = rawData;
    } else if (rawData is List && rawData.isNotEmpty && rawData.first is Map) {
      data = Map<String, dynamic>.from(rawData.first as Map);
    } else {
      data = <String, dynamic>{};
    }

    final String token = '${data['token'] ?? ''}'.trim();
    final String refreshToken = '${data['refresh_token'] ?? ''}'.trim();
    if (token.isEmpty || refreshToken.isEmpty) {
      throw Exception('OneLap login response missing token fields');
    }

    _token = token;
    _refreshToken = refreshToken;
  }

  List<String> _buildDownloadUrls(String fitUrl, {OneLapActivity? activity}) {
    final List<String> urls = <String>[];

    void addCandidates(String candidate) {
      for (final String url in _expandDownloadUrls(candidate)) {
        if (!urls.contains(url)) {
          urls.add(url);
        }
      }
    }

    addCandidates(fitUrl);
    if (activity != null) {
      final String? rawFitUrl = activity.rawFitUrl;
      if (rawFitUrl != null && rawFitUrl.trim().isNotEmpty) {
        addCandidates(rawFitUrl);
      }
      final String? rawFitUrlAlt = activity.rawFitUrlAlt;
      if (rawFitUrlAlt != null && rawFitUrlAlt.trim().isNotEmpty) {
        addCandidates(rawFitUrlAlt);
      }
      final String? rawDurl = activity.rawDurl;
      if (rawDurl != null && rawDurl.trim().isNotEmpty) {
        addCandidates(rawDurl);
      }
      final String? rawFileKey = activity.rawFileKey;
      if (rawFileKey != null && rawFileKey.trim().isNotEmpty) {
        addCandidates(rawFileKey);
      }
    }

    return urls;
  }

  List<String> _expandDownloadUrls(String fitUrl) {
    final String value = fitUrl.trim();
    if (value.isEmpty) {
      return <String>[];
    }

    if (value.startsWith('http://') || value.startsWith('https://')) {
      return <String>[value];
    }

    final Uri baseUri = Uri.parse(baseUrl);
    final Uri relativeUri = Uri.parse(
      value.startsWith('/') ? value : '/$value',
    );
    final String normalizedPath = relativeUri.path.replaceFirst(
      RegExp(r'^/'),
      '',
    );
    final List<String> urls = <String>[
      baseUri.resolveUri(relativeUri).toString(),
    ];

    if (normalizedPath.startsWith('geo/')) {
      for (final String fallbackBaseUrl in geoFallbackBaseUrls) {
        final Uri fallbackBaseUri = Uri.parse(fallbackBaseUrl);
        final Uri fallbackUri = fallbackBaseUri.resolveUri(relativeUri);
        final String fallbackUrl = fallbackUri.toString();
        if (!urls.contains(fallbackUrl)) {
          urls.add(fallbackUrl);
        }
      }
    }
    return urls;
  }
}
