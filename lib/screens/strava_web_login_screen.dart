import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Strava 登录页。
const String kStravaLoginUrl = 'https://www.strava.com/login';

/// Android 上使用的 Chrome UA（Android 真机实测可用，保持不变）。
const String kAndroidLoginUserAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';

/// 构造与当前平台「自洽」的 User-Agent。
///
/// 为什么必须分平台（在 iPhone 17 模拟器上用真 WKWebView 实测，见
/// `tool/strava_login_probe.dart`）：
///
/// 1. iOS 上沿用 Android Chrome UA 会让指纹自相矛盾：
///    `navigator.userAgent` 自称 Android 14 / Chrome 125，而
///    `navigator.vendor == 'Apple Computer, Inc.'`、
///    `navigator.platform == 'iPhone'`、
///    `navigator.userAgentData == undefined`、`window.chrome == undefined`。
///    Google 的「此浏览器或应用可能不安全」判定会命中该组合。
/// 2. 同一个 UA 还会改变 Apple 登录页给出的入口：浏览器自称 Android 时，
///    Apple 只给「通过 iPhone 登录」（需要另一台设备配合，在应用内永远走不完）；
///    换成 iOS UA 后改回「邮箱/密码」与「通行密钥」。
/// 3. Strava 自身也按 UA 分叉（同一页面两种 UA 下 reCAPTCHA site key 不同，
///    实测 `6LenbGQq…` vs `6LdrImMr…`），所以 iOS 应当拿到 iOS 分支。
///
/// UA 里的 `AppleWebKit/605.1.15`、`Mobile/15E148`、`Safari/604.1` 取自
/// 实测的 WKWebView 默认 UA（`UA_VARIANT=none` 那组），版本号取自系统版本，
/// 避免出现「声称的 iOS 版本」与「真实系统」不一致的新破绽。
String buildLoginUserAgent({
  required TargetPlatform platform,
  required String operatingSystemVersion,
}) {
  if (platform != TargetPlatform.iOS) return kAndroidLoginUserAgent;

  final match = RegExp(r'(\d+)[._](\d+)').firstMatch(operatingSystemVersion);
  final parsedMajor = int.tryParse(match?.group(1) ?? '');
  final parsedMinor = int.tryParse(match?.group(2) ?? '');
  // 解析失败或版本号明显不合理（<15，iOS 15 之前的 WKWebView 语义不同）时
  // 回退到一个「存在且自洽」的版本，而不是把脏字符串塞进 UA。
  // major/minor 必须成对回退，否则会拼出主机上不存在的版本组合。
  final bool versionUsable =
      parsedMajor != null &&
      parsedMajor >= 15 &&
      parsedMinor != null &&
      parsedMinor >= 0 &&
      parsedMinor <= 99;
  final int major = versionUsable ? parsedMajor : 18;
  final int minor = versionUsable ? parsedMinor : 0;

  return 'Mozilla/5.0 (iPhone; CPU iPhone OS ${major}_$minor like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) '
      'Version/$major.$minor Mobile/15E148 Safari/604.1';
}

/// 页面侧探测：识别三种「在应用内注定走不通」的软肋页面。
/// 返回 `google_blocked` / `google_passkey` / `apple_cross_device` / 空串。
///
/// 用文案匹配而不是 URL 精确匹配，因为各家的拦截页路径会变，文案相对稳定；
/// 域名过滤保证不会误命中普通页面。
const String kLoginHintProbeScript = r'''
(function () {
  var host = location.host;
  var href = location.href;
  var text = (document.body ? String(document.body.innerText || '') : '').toLowerCase();
  function has() {
    for (var i = 0; i < arguments.length; i++) {
      if (text.indexOf(String(arguments[i]).toLowerCase()) >= 0) return true;
    }
    return false;
  }
  if (host.indexOf('accounts.google.com') >= 0) {
    if (href.indexOf('/rejected') >= 0 || has('可能不安全', 'not secure', "couldn't sign you in", '无法让你登录')) {
      return 'google_blocked';
    }
    if (has('通行密钥', 'passkey', '其他设备')) return 'google_passkey';
  }
  if (host.indexOf('appleid.apple.com') >= 0 &&
      has('通过 iphone 登录', 'sign in with iphone', '需要安装 ios')) {
    return 'apple_cross_device';
  }
  return '';
})()
''';

/// 兜底文案：把「为什么不行 + 现在该怎么做」讲清楚。
String? loginHintForMarker(String marker) {
  switch (marker) {
    case 'google_blocked':
      return 'Google 不允许在应用内登录。请改用邮箱登录：输入 Strava 账号邮箱 →'
          '点「继续」→ 填入邮件里的 6 位验证码。';
    case 'google_passkey':
      return 'Google 要求使用通行密钥，应用内无法完成。请改用邮箱登录：'
          '输入 Strava 账号邮箱 → 点「继续」→ 填入邮件里的 6 位验证码。';
    case 'apple_cross_device':
      return '「通过 iPhone 登录」需要在另一台设备上确认，应用内无法完成。'
          '请改用 Apple 账号的邮箱和密码登录。';
    default:
      return null;
  }
}

class StravaWebLoginScreen extends StatefulWidget {
  final void Function(String cookies) onLoginSuccess;

  const StravaWebLoginScreen({super.key, required this.onLoginSuccess});

  @override
  State<StravaWebLoginScreen> createState() => _StravaWebLoginScreenState();
}

class _StravaWebLoginScreenState extends State<StravaWebLoginScreen> {
  static const _cookieChannel = MethodChannel('onelap_strava_sync/cookie');
  late final WebViewController _controller;
  bool _loading = true;
  bool _didComplete = false;
  String? _hint;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        buildLoginUserAgent(
          platform: defaultTargetPlatform,
          operatingSystemVersion: Platform.operatingSystemVersion,
        ),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (url) {
            if (mounted) setState(() => _loading = false);
            _probeHint(url);
          },
          onNavigationRequest: (request) {
            final uri = Uri.parse(request.url);
            if (uri.path.contains('/dashboard') ||
                uri.path.contains('/athlete')) {
              _handleLoginSuccess();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (error) {
            if (!_didComplete && mounted && error.isForMainFrame == true) {
              final url = error.url ?? '';
              if (url.contains('google.com') &&
                  error.errorCode == -1 &&
                  error.description.contains('403')) {
                _showHint(loginHintForMarker('google_blocked'));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('页面加载失败: ${error.description}'),
                    action: SnackBarAction(
                      label: '重试',
                      onPressed: () => _controller.reload(),
                    ),
                  ),
                );
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(kStravaLoginUrl));
  }

  void _showHint(String? hint) {
    if (hint == null || !mounted || _hint == hint) return;
    setState(() => _hint = hint);
  }

  /// 页面加载完成后延迟探测：Google/Apple 的页面是前端渲染的，
  /// `onPageFinished` 触发时文案可能还没出现，所以延后一次再读。
  Future<void> _probeHint(String url) async {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    if (!host.contains('google.com') && !host.contains('apple.com')) return;

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted || _didComplete) return;
    try {
      final result = await _controller.runJavaScriptReturningResult(
        kLoginHintProbeScript,
      );
      final marker = result.toString().replaceAll('"', '').trim();
      _showHint(loginHintForMarker(marker));
    } catch (_) {
      // 探测失败不影响登录主流程，静默忽略。
    }
  }

  Future<void> _handleLoginSuccess() async {
    if (_didComplete) return;
    _didComplete = true;

    String cookieString;
    try {
      cookieString =
          await _cookieChannel.invokeMethod<String>(
            'getCookies',
            'https://www.strava.com',
          ) ??
          '';
    } catch (_) {
      final result = await _controller.runJavaScriptReturningResult(
        'document.cookie',
      );
      cookieString = result.toString();
    }

    if (mounted) {
      widget.onLoginSuccess(cookieString);
      Navigator.of(context).pop(true);
    }
  }

  Widget _buildHintBanner(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _hint!,
              style: TextStyle(
                fontSize: 12,
                color: colors.onSecondaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: () =>
                _controller.loadRequest(Uri.parse(kStravaLoginUrl)),
            child: const Text('返回登录页'),
          ),
          IconButton(
            icon: const Icon(Icons.clear, size: 16),
            tooltip: '忽略',
            onPressed: () => setState(() => _hint = null),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录 Strava'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Column(
        children: [
          if (_hint != null) _buildHintBanner(context),
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
