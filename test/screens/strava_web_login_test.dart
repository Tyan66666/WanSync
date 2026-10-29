import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:onelap_strava_sync/screens/strava_web_login_screen.dart';

class _FakeWebViewPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements WebViewPlatform {
  _FakePlatformWebViewController? lastController;
  _FakePlatformNavigationDelegate? lastDelegate;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _FakePlatformWebViewController(params);
    lastController = controller;
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    final delegate = _FakePlatformNavigationDelegate(params);
    lastDelegate = delegate;
    return delegate;
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformWebViewWidget(params);
  }

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) {
    return _FakePlatformCookieManager(params);
  }
}

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  String? lastUserAgent;
  String javaScriptResult = '';
  final List<String> loadedUrls = <String>[];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams request) async {
    loadedUrls.add(request.uri.toString());
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> setUserAgent(String? userAgent) async {
    lastUserAgent = userAgent;
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    return javaScriptResult;
  }
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  NavigationRequestCallback? onNavigationRequest;
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    this.onPageStarted = onPageStarted;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const SizedBox();
  }
}

class _FakePlatformCookieManager extends PlatformWebViewCookieManager {
  _FakePlatformCookieManager(super.params) : super.implementation();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWebViewPlatform fakePlatform;

  Future<void> pumpLoginScreen(
    WidgetTester tester, {
    ValueChanged<String>? onLoginSuccess,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StravaWebLoginScreen(onLoginSuccess: onLoginSuccess ?? (_) {}),
      ),
    );
    await tester.pump();
  }

  setUp(() {
    fakePlatform = _FakeWebViewPlatform();
    WebViewPlatform.instance = fakePlatform;
  });

  group('buildLoginUserAgent', () {
    test('iOS 生成与系统版本一致的 Safari UA', () {
      expect(
        buildLoginUserAgent(
          platform: TargetPlatform.iOS,
          operatingSystemVersion: 'Version 26.1 (Build 23B85)',
        ),
        'Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/26.1 Mobile/15E148 Safari/604.1',
      );
    });

    test('iOS 版本字符串解析不到时回退到自洽的 18.0，而不是拼出脏 UA', () {
      for (final input in <String>['', 'unknown', 'Version 9.3 (Build 1)']) {
        final ua = buildLoginUserAgent(
          platform: TargetPlatform.iOS,
          operatingSystemVersion: input,
        );
        expect(ua, contains('iPhone; CPU iPhone OS 18_0 like Mac OS X'));
        expect(ua, contains('Version/18.0'));
      }
    });

    test('Android 保持原有 Chrome UA 不变', () {
      expect(
        buildLoginUserAgent(
          platform: TargetPlatform.android,
          operatingSystemVersion: '14',
        ),
        kAndroidLoginUserAgent,
      );
    });
  });

  testWidgets('iOS 平台使用自洽的 Safari UA（不再冒充 Android Chrome）', (
    WidgetTester tester,
  ) async {
    // 这里在测试体内复位：框架的不变量校验发生在 tearDown 之前。
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pumpLoginScreen(tester);

      final ua = fakePlatform.lastController!.lastUserAgent!;
      expect(ua, contains('iPhone; CPU iPhone OS '));
      expect(
        ua,
        matches(RegExp(r'Version/\d+\.\d+ Mobile/15E148 Safari/604\.1')),
      );
      expect(ua, isNot(contains('Android')));
      expect(ua, isNot(contains('Chrome')));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android 平台沿用 Chrome UA', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpLoginScreen(tester);

      expect(
        fakePlatform.lastController!.lastUserAgent,
        kAndroidLoginUserAgent,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('打开登录页时请求的是 Strava 登录地址', (WidgetTester tester) async {
    await pumpLoginScreen(tester);

    expect(fakePlatform.lastController!.loadedUrls, <String>[kStravaLoginUrl]);
  });

  testWidgets('shows app bar with title and close button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: StravaWebLoginScreen(onLoginSuccess: (_) {})),
    );
    await tester.pump();

    expect(find.text('登录 Strava'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('close button pops with false', (WidgetTester tester) async {
    bool? popResult;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popResult = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => StravaWebLoginScreen(onLoginSuccess: (_) {}),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(popResult, false);
  });

  testWidgets('login success reads cookies via native channel and pops true', (
    WidgetTester tester,
  ) async {
    final List<MethodCall> calls = [];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('onelap_strava_sync/cookie'),
          (MethodCall call) async {
            calls.add(call);
            if (call.method == 'getCookies') {
              return '_strava_session=abc123; other=value';
            }
            return null;
          },
        );

    await tester.pumpWidget(
      MaterialApp(home: StravaWebLoginScreen(onLoginSuccess: (_) {})),
    );
    await tester.pump();

    // No login triggered yet — verify mock registered
    expect(calls, isEmpty);

    // Clean up
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('onelap_strava_sync/cookie'),
          null,
        );
  });

  testWidgets('导航到 /dashboard 时取 cookie、回调并 pop(true)', (
    WidgetTester tester,
  ) async {
    final List<MethodCall> calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('onelap_strava_sync/cookie'),
          (MethodCall call) async {
            calls.add(call);
            return '_strava_session=abc123; other=value';
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('onelap_strava_sync/cookie'),
            null,
          ),
    );

    bool? popResult;
    String? receivedCookies;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popResult = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => StravaWebLoginScreen(
                    onLoginSuccess: (cookies) => receivedCookies = cookies,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    final decision = await fakePlatform.lastDelegate!.onNavigationRequest!(
      const NavigationRequest(
        url: 'https://www.strava.com/dashboard',
        isMainFrame: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(decision, NavigationDecision.prevent);
    expect(calls.single.method, 'getCookies');
    expect(receivedCookies, '_strava_session=abc123; other=value');
    expect(popResult, isTrue);
  });

  testWidgets('识别到 Google 拦截页时显示兜底提示，可返回登录页或忽略', (WidgetTester tester) async {
    await pumpLoginScreen(tester);
    fakePlatform.lastController!.javaScriptResult = '"google_blocked"';

    fakePlatform.lastDelegate!.onPageFinished!(
      'https://accounts.google.com/signin/rejected?x=1',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();

    expect(find.textContaining('Google 不允许在应用内登录'), findsOneWidget);
    expect(find.text('返回登录页'), findsOneWidget);

    await tester.tap(find.text('返回登录页'));
    await tester.pump();
    expect(fakePlatform.lastController!.loadedUrls.last, kStravaLoginUrl);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(find.textContaining('Google 不允许在应用内登录'), findsNothing);
  });

  testWidgets('识别到 Google 通行密钥页时提示改用邮箱验证码', (WidgetTester tester) async {
    await pumpLoginScreen(tester);
    fakePlatform.lastController!.javaScriptResult = '"google_passkey"';

    fakePlatform.lastDelegate!.onPageFinished!(
      'https://accounts.google.com/v3/signin/challenge/pk',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();

    expect(find.textContaining('通行密钥'), findsOneWidget);
    expect(find.textContaining('6 位验证码'), findsOneWidget);
  });

  testWidgets('识别到 Apple 跨设备登录页时提示改用邮箱密码', (WidgetTester tester) async {
    await pumpLoginScreen(tester);
    fakePlatform.lastController!.javaScriptResult = '"apple_cross_device"';

    fakePlatform.lastDelegate!.onPageFinished!(
      'https://appleid.apple.com/auth/authorize?x=1',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();

    expect(find.textContaining('通过 iPhone 登录'), findsOneWidget);
  });

  testWidgets('普通页面不触发兜底提示', (WidgetTester tester) async {
    await pumpLoginScreen(tester);
    fakePlatform.lastController!.javaScriptResult = '"google_blocked"';

    fakePlatform.lastDelegate!.onPageFinished!('https://www.strava.com/login');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();

    expect(find.textContaining('Google 不允许在应用内登录'), findsNothing);
  });
}
