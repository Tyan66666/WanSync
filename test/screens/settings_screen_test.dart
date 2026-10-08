import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelap_strava_sync/models/app_config.dart';
import 'package:onelap_strava_sync/screens/settings_screen.dart';
import 'package:onelap_strava_sync/services/settings_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([Map<String, String>? initialValues])
    : _values = Map<String, String>.from(initialValues ?? <String, String>{});

  final Map<String, String> _values;

  @override
  Future<Map<String, String>> readAll() async {
    return Map<String, String>.from(_values);
  }

  @override
  Future<String?> read({required String key}) async {
    return _values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }
}

class ThrowOnWriteSettingsStore extends InMemorySettingsStore {
  ThrowOnWriteSettingsStore([super.initialValues]);

  @override
  Future<void> write({required String key, required String value}) {
    throw Exception('save failed');
  }
}

class DelayedReadSettingsStore extends InMemorySettingsStore {
  DelayedReadSettingsStore(this._readCompleter, [super.initialValues]);

  final Completer<void> _readCompleter;

  @override
  Future<Map<String, String>> readAll() async {
    await _readCompleter.future;
    return super.readAll();
  }
}

class PendingWrite {
  PendingWrite({
    required this.key,
    required this.value,
    required this.completer,
  });

  final String key;
  final String value;
  final Completer<void> completer;
}

class ControlledWriteSettingsStore extends InMemorySettingsStore {
  ControlledWriteSettingsStore([super.initialValues]);

  final List<PendingWrite> writes = <PendingWrite>[];

  @override
  Future<void> write({required String key, required String value}) {
    final Completer<void> completer = Completer<void>();
    writes.add(PendingWrite(key: key, value: value, completer: completer));
    return completer.future.then((_) {
      _values[key] = value;
    });
  }
}

class FailControlledWriteSettingsStore extends ControlledWriteSettingsStore {
  FailControlledWriteSettingsStore([super.initialValues]);

  final Set<int> failingWriteIndexes = <int>{};

  @override
  Future<void> write({required String key, required String value}) {
    final int writeIndex = writes.length;
    final Completer<void> completer = Completer<void>();
    writes.add(PendingWrite(key: key, value: value, completer: completer));
    return completer.future.then((_) {
      if (failingWriteIndexes.contains(writeIndex)) {
        throw Exception('save failed');
      }
      _values[key] = value;
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder fieldWithLabel(String labelText) {
    return find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == labelText,
      description: 'TextField($labelText)',
    );
  }

  void useLargeTestViewport(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> enterVisibleText(
    WidgetTester tester,
    String labelText,
    String value,
  ) async {
    final Finder field = fieldWithLabel(labelText);
    await tester.ensureVisible(field);
    await tester.enterText(field, value);
  }

  Finder buttonWithText(String text) {
    final Finder elevated = find.widgetWithText(ElevatedButton, text);
    if (elevated.evaluate().isNotEmpty) {
      return elevated;
    }

    final Finder outlined = find.widgetWithText(OutlinedButton, text);
    if (outlined.evaluate().isNotEmpty) {
      return outlined;
    }

    return find.text(text);
  }

  Finder gcjCorrectionSwitch() {
    return find.descendant(
      of: find.widgetWithText(SwitchListTile, 'Strava 上传前将 GCJ-02 转为 WGS84'),
      matching: find.byType(Switch),
    );
  }

  Finder platformSwitch(String platformTitle) {
    return find.descendant(
      of: find.widgetWithText(ListTile, platformTitle),
      matching: find.byType(Switch),
    );
  }

  Future<void> tapVisibleText(WidgetTester tester, String text) async {
    final Finder target = buttonWithText(text);
    await tester.ensureVisible(target);
    await tester.tap(target, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  bool hasFocusedEditableText(WidgetTester tester) {
    return find
        .byType(EditableText)
        .evaluate()
        .map(
          (element) =>
              tester.widget<EditableText>(find.byWidget(element.widget)),
        )
        .any((editableText) => editableText.focusNode.hasFocus);
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('preserves entered Strava credentials after successful auth', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    final InMemorySettingsStore store = InMemorySettingsStore(<String, String>{
      SettingsService.keyUploadToStrava: 'true',
      SettingsService.keyLookbackDays: '3',
    });
    final SettingsService settingsService = SettingsService(store: store);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsService: settingsService,
          authorizeStrava: (String clientId, String clientSecret) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder stravaCard = find.ancestor(
      of: find.text('Strava'),
      matching: find.byType(Card),
    );
    await tester.ensureVisible(stravaCard);
    await tester.tap(stravaCard);
    await tester.pumpAndSettle();

    await tester.enterText(fieldWithLabel('Client ID（客户端ID）'), '12345');
    await tester.enterText(
      fieldWithLabel('Client Secret（客户端密钥）'),
      'secret-xyz',
    );

    await tapVisibleText(tester, '授权 Strava');

    final Map<String, String> settings = await settingsService.loadSettings();
    expect(settings[SettingsService.keyStravaClientId], '12345');
    expect(settings[SettingsService.keyStravaClientSecret], 'secret-xyz');
  });

  testWidgets('save OneLap credentials validates and persists on success', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          validateOneLapLogin: (String username, String password) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await enterVisibleText(tester, 'OneLap 用户名', 'solo-user');
    await enterVisibleText(tester, 'OneLap 密码', 'solo-pass');

    await tapVisibleText(tester, '保存 OneLap 账号');

    expect(find.text('OneLap 账号已保存'), findsOneWidget);

    final Map<String, String> settings = await SettingsService().loadSettings();
    expect(settings[SettingsService.keyOneLapUsername], 'solo-user');
    expect(settings[SettingsService.keyOneLapPassword], 'solo-pass');
  });

  testWidgets('save OneLap credentials also validates current input', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    String? validatedUsername;
    String? validatedPassword;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          validateOneLapLogin: (String username, String password) async {
            validatedUsername = username;
            validatedPassword = password;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await enterVisibleText(tester, 'OneLap 用户名', 'verify-user');
    await enterVisibleText(tester, 'OneLap 密码', 'verify-pass');

    await tapVisibleText(tester, '保存 OneLap 账号');

    expect(validatedUsername, 'verify-user');
    expect(validatedPassword, 'verify-pass');

    final Map<String, String> settings = await SettingsService().loadSettings();
    expect(settings[SettingsService.keyOneLapUsername], 'verify-user');
    expect(settings[SettingsService.keyOneLapPassword], 'verify-pass');
  });

  testWidgets(
    'save OneLap credentials shows validating state while request is in flight',
    (WidgetTester tester) async {
      useLargeTestViewport(tester);

      final Completer<void> validationCompleter = Completer<void>();

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            validateOneLapLogin: (String username, String password) {
              return validationCompleter.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await enterVisibleText(tester, 'OneLap 用户名', 'slow-user');
      await enterVisibleText(tester, 'OneLap 密码', 'slow-pass');

      await tester.tap(buttonWithText('保存 OneLap 账号'));
      await tester.pump();

      expect(find.text('验证中...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      final ElevatedButton button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, '验证中...'),
      );
      expect(button.onPressed, isNull);

      validationCompleter.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'failed OneLap validation keeps previous credentials and restores idle state',
    (WidgetTester tester) async {
      useLargeTestViewport(tester);

      FlutterSecureStorage.setMockInitialValues(<String, String>{
        SettingsService.keyOneLapUsername: 'stable-user',
        SettingsService.keyOneLapPassword: 'stable-pass',
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            validateOneLapLogin: (String username, String password) async {
              throw Exception('invalid credentials');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await enterVisibleText(tester, 'OneLap 用户名', 'wrong-user');
      await enterVisibleText(tester, 'OneLap 密码', 'wrong-pass');

      await tapVisibleText(tester, '保存 OneLap 账号');

      expect(
        find.text('OneLap 登录验证失败: Exception: invalid credentials'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(find.text('OneLap 账号已保存'), findsNothing);
      expect(find.text('保存 OneLap 账号'), findsOneWidget);
      expect(find.text('验证中...'), findsNothing);

      final Map<String, String> settings = await SettingsService()
          .loadSettings();
      expect(settings[SettingsService.keyOneLapUsername], 'stable-user');
      expect(settings[SettingsService.keyOneLapPassword], 'stable-pass');
    },
  );

  testWidgets('empty OneLap credentials do not show saved success state', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          validateOneLapLogin: (String username, String password) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tapVisibleText(tester, '保存 OneLap 账号');

    expect(find.text('请先填写 OneLap 用户名和密码'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(find.text('OneLap 账号已保存'), findsNothing);
  });

  testWidgets('persistence failure after OneLap validation shows save error', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    final SettingsService settingsService = SettingsService(
      store: ThrowOnWriteSettingsStore(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settingsService: settingsService,
          validateOneLapLogin: (String username, String password) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await enterVisibleText(tester, 'OneLap 用户名', 'persist-user');
    await enterVisibleText(tester, 'OneLap 密码', 'persist-pass');

    await tapVisibleText(tester, '保存 OneLap 账号');

    expect(find.text('设置保存失败: Exception: save failed'), findsOneWidget);
    expect(find.text('OneLap 登录验证失败: Exception: save failed'), findsNothing);
    expect(find.text('OneLap 账号已保存'), findsNothing);
  });

  testWidgets('save sync settings persists lookback days only', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    FlutterSecureStorage.setMockInitialValues(<String, String>{
      SettingsService.keyOneLapUsername: 'stable-user',
      SettingsService.keyLookbackDays: '3',
    });

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    await enterVisibleText(tester, '同步最近几天（默认 3）', '7');

    await tapVisibleText(tester, '保存同步设置');

    expect(find.text('同步设置已保存'), findsOneWidget);

    final Map<String, String> settings = await SettingsService().loadSettings();
    expect(settings[SettingsService.keyLookbackDays], '7');
    expect(settings[SettingsService.keyOneLapUsername], 'stable-user');
  });

  testWidgets('rewrite switch loads from stored settings', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    FlutterSecureStorage.setMockInitialValues(<String, String>{
      SettingsService.keyGcjCorrectionEnabled: 'true',
    });

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Strava 上传前将 GCJ-02 转为 WGS84'), findsOneWidget);
    expect(
      find.text('仅对 Strava 生效；行者、Intervals.icu、Outbase 上传原始文件'),
      findsOneWidget,
    );

    final Switch rewriteSwitch = tester.widget<Switch>(gcjCorrectionSwitch());
    expect(rewriteSwitch.value, isTrue);
  });

  testWidgets('toggling rewrite switch and saving sync settings persists it', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    FlutterSecureStorage.setMockInitialValues(<String, String>{
      SettingsService.keyLookbackDays: '3',
      SettingsService.keyGcjCorrectionEnabled: 'false',
    });

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(gcjCorrectionSwitch());
    await tester.tap(gcjCorrectionSwitch());
    await tester.pumpAndSettle();

    await enterVisibleText(tester, '同步最近几天（默认 3）', '7');
    await tapVisibleText(tester, '保存同步设置');

    final Map<String, String> settings = await SettingsService().loadSettings();
    expect(settings[SettingsService.keyLookbackDays], '7');
    expect(settings[SettingsService.keyGcjCorrectionEnabled], 'true');
  });

  testWidgets('tapping rewrite switch immediately persists GCJ setting', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    final InMemorySettingsStore store = InMemorySettingsStore(<String, String>{
      SettingsService.keyGcjCorrectionEnabled: 'false',
      SettingsService.keyLookbackDays: '3',
    });
    final SettingsService settingsService = SettingsService(store: store);

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settingsService: settingsService)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(gcjCorrectionSwitch());
    await tester.tap(gcjCorrectionSwitch());
    await tester.pumpAndSettle();

    final Map<String, String> settings = await settingsService.loadSettings();
    expect(settings[SettingsService.keyGcjCorrectionEnabled], 'true');
    expect(settings[SettingsService.keyLookbackDays], '3');
  });

  testWidgets('rapid rewrite toggles persist the latest value in order', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    final ControlledWriteSettingsStore store =
        ControlledWriteSettingsStore(<String, String>{
          SettingsService.keyGcjCorrectionEnabled: 'false',
          SettingsService.keyLookbackDays: '3',
        });
    final SettingsService settingsService = SettingsService(store: store);

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settingsService: settingsService)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(gcjCorrectionSwitch());
    await tester.tap(gcjCorrectionSwitch());
    await tester.pump();

    expect(store.writes, hasLength(1));
    expect(store.writes[0].key, SettingsService.keyGcjCorrectionEnabled);
    expect(store.writes[0].value, 'true');

    await tester.tap(gcjCorrectionSwitch());
    await tester.pump();

    final Switch rewriteSwitch = tester.widget<Switch>(gcjCorrectionSwitch());
    expect(rewriteSwitch.value, isFalse);
    expect(store.writes, hasLength(1));

    store.writes[0].completer.complete();
    await tester.pump();

    expect(store.writes, hasLength(2));
    expect(store.writes[1].key, SettingsService.keyGcjCorrectionEnabled);
    expect(store.writes[1].value, 'false');

    store.writes[1].completer.complete();
    await tester.pumpAndSettle();

    final Map<String, String> settings = await settingsService.loadSettings();
    expect(settings[SettingsService.keyGcjCorrectionEnabled], 'false');
  });

  testWidgets(
    'failed queued rewrite save falls back to last confirmed persisted state',
    (WidgetTester tester) async {
      useLargeTestViewport(tester);

      final FailControlledWriteSettingsStore store =
          FailControlledWriteSettingsStore(<String, String>{
            SettingsService.keyGcjCorrectionEnabled: 'false',
            SettingsService.keyLookbackDays: '3',
          });
      final SettingsService settingsService = SettingsService(store: store);

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(settingsService: settingsService)),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(gcjCorrectionSwitch());
      await tester.tap(gcjCorrectionSwitch());
      await tester.pump();

      await tester.tap(gcjCorrectionSwitch());
      await tester.pump();

      store.writes[0].completer.complete();
      await tester.pump();

      expect(store.writes, hasLength(2));
      store.failingWriteIndexes.add(1);
      store.writes[1].completer.complete();
      await tester.pumpAndSettle();

      final Switch rewriteSwitch = tester.widget<Switch>(gcjCorrectionSwitch());
      expect(rewriteSwitch.value, isTrue);
      expect(find.text('设置保存失败: Exception: save failed'), findsOneWidget);

      final Map<String, String> settings = await settingsService.loadSettings();
      expect(settings[SettingsService.keyGcjCorrectionEnabled], 'true');
    },
  );

  testWidgets(
    'failed rewrite switch persistence reverts switch and shows error',
    (WidgetTester tester) async {
      useLargeTestViewport(tester);

      final SettingsService settingsService = SettingsService(
        store: ThrowOnWriteSettingsStore(<String, String>{
          SettingsService.keyGcjCorrectionEnabled: 'false',
          SettingsService.keyLookbackDays: '3',
        }),
      );

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(settingsService: settingsService)),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(gcjCorrectionSwitch());
      await tester.tap(gcjCorrectionSwitch());
      await tester.pumpAndSettle();

      final Switch rewriteSwitch = tester.widget<Switch>(gcjCorrectionSwitch());
      expect(rewriteSwitch.value, isFalse);
      expect(find.text('设置保存失败: Exception: save failed'), findsOneWidget);
    },
  );

  testWidgets('submitting lookback days field saves sync settings', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    FlutterSecureStorage.setMockInitialValues(<String, String>{
      SettingsService.keyLookbackDays: '3',
    });

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    final Finder field = fieldWithLabel('同步最近几天（默认 3）');
    await tester.ensureVisible(field);
    await tester.enterText(field, '5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('同步设置已保存'), findsOneWidget);

    final Map<String, String> settings = await SettingsService().loadSettings();
    expect(settings[SettingsService.keyLookbackDays], '5');
  });

  testWidgets('invalid lookback days shows error and does not persist', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    FlutterSecureStorage.setMockInitialValues(<String, String>{
      SettingsService.keyLookbackDays: '3',
    });

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    await enterVisibleText(tester, '同步最近几天（默认 3）', '0');
    await tapVisibleText(tester, '保存同步设置');

    expect(find.text('请输入大于 0 的整数天数'), findsOneWidget);

    final Map<String, String> settings = await SettingsService().loadSettings();
    expect(settings[SettingsService.keyLookbackDays], '3');
  });

  testWidgets('sync settings save failure shows error and keeps value', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    final SettingsService settingsService = SettingsService(
      store: ThrowOnWriteSettingsStore(<String, String>{
        SettingsService.keyLookbackDays: '3',
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settingsService: settingsService)),
    );
    await tester.pumpAndSettle();

    await enterVisibleText(tester, '同步最近几天（默认 3）', '6');
    await tapVisibleText(tester, '保存同步设置');

    expect(find.text('设置保存失败: Exception: save failed'), findsOneWidget);
    expect(find.text('同步设置已保存'), findsNothing);

    final Map<String, String> settings = await settingsService.loadSettings();
    expect(settings[SettingsService.keyLookbackDays], '3');
  });

  testWidgets('successful OneLap save dismisses keyboard focus', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          validateOneLapLogin: (String username, String password) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await enterVisibleText(tester, 'OneLap 用户名', 'focus-user');
    await enterVisibleText(tester, 'OneLap 密码', 'focus-pass');

    final Finder passwordField = fieldWithLabel('OneLap 密码');
    await tester.tap(passwordField);
    await tester.pump();
    expect(hasFocusedEditableText(tester), isTrue);

    await tapVisibleText(tester, '保存 OneLap 账号');

    expect(hasFocusedEditableText(tester), isFalse);
  });

  testWidgets('saving sync settings dismisses keyboard focus', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    final Finder field = fieldWithLabel('同步最近几天（默认 3）');
    await tester.tap(field);
    await tester.pump();
    expect(hasFocusedEditableText(tester), isTrue);

    await tester.enterText(field, '6');
    await tapVisibleText(tester, '保存同步设置');

    expect(hasFocusedEditableText(tester), isFalse);
  });

  testWidgets('disposing settings screen during load does not throw', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    final Completer<void> readCompleter = Completer<void>();
    final SettingsService settingsService = SettingsService(
      store: DelayedReadSettingsStore(readCompleter),
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settingsService: settingsService)),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    readCompleter.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping upload to Strava toggle immediately persists setting', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    final InMemorySettingsStore store = InMemorySettingsStore(<String, String>{
      SettingsService.keyUploadToStrava: 'true',
      SettingsService.keyUploadToXingzhe: 'true',
      SettingsService.keyLookbackDays: '3',
    });
    final SettingsService settingsService = SettingsService(store: store);

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settingsService: settingsService)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(platformSwitch('Strava'));
    await tester.tap(platformSwitch('Strava'));
    await tester.pumpAndSettle();

    final Map<String, String> settings = await settingsService.loadSettings();
    expect(settings[SettingsService.keyUploadToStrava], 'false');
  });

  testWidgets('tapping upload to Xingzhe toggle immediately persists setting', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    final InMemorySettingsStore store = InMemorySettingsStore(<String, String>{
      SettingsService.keyUploadToStrava: 'true',
      SettingsService.keyUploadToXingzhe: 'false',
      SettingsService.keyLookbackDays: '3',
    });
    final SettingsService settingsService = SettingsService(store: store);

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settingsService: settingsService)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(platformSwitch('行者'));
    await tester.tap(platformSwitch('行者'));
    await tester.pumpAndSettle();

    final Map<String, String> settings = await settingsService.loadSettings();
    expect(settings[SettingsService.keyUploadToXingzhe], 'true');
  });

  testWidgets(
    'tapping upload to Intervals.icu toggle immediately persists setting',
    (WidgetTester tester) async {
      useLargeTestViewport(tester);

      final InMemorySettingsStore store =
          InMemorySettingsStore(<String, String>{
            SettingsService.keyUploadToStrava: 'true',
            SettingsService.keyUploadToXingzhe: 'false',
            SettingsService.keyUploadToIntervalsIcu: 'false',
            SettingsService.keyLookbackDays: '3',
          });
      final SettingsService settingsService = SettingsService(store: store);

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(settingsService: settingsService)),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(platformSwitch('Intervals.icu'));
      await tester.tap(platformSwitch('Intervals.icu'));
      await tester.pumpAndSettle();

      final Map<String, String> settings = await settingsService.loadSettings();
      expect(settings[SettingsService.keyUploadToIntervalsIcu], 'true');
    },
  );

  testWidgets('cannot turn off all upload platforms', (
    WidgetTester tester,
  ) async {
    useLargeTestViewport(tester);

    FlutterSecureStorage.setMockInitialValues(<String, String>{
      SettingsService.keyUploadToStrava: 'true',
      SettingsService.keyUploadToXingzhe: 'true',
      SettingsService.keyUploadToIntervalsIcu: 'true',
      SettingsService.keyLookbackDays: '3',
    });

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(platformSwitch('Strava'));
    await tester.tap(platformSwitch('Strava'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(platformSwitch('行者'));
    await tester.tap(platformSwitch('行者'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(platformSwitch('Intervals.icu'));
    await tester.tap(platformSwitch('Intervals.icu'));
    await tester.pump();

    expect(find.text('至少需要选择一个上传平台'), findsOneWidget);

    final Map<String, String> settings = await SettingsService().loadSettings();
    expect(settings[SettingsService.keyUploadToIntervalsIcu], 'true');
  });

  testWidgets(
    'failed upload toggle persistence reverts switch and shows error',
    (WidgetTester tester) async {
      useLargeTestViewport(tester);

      final SettingsService settingsService = SettingsService(
        store: ThrowOnWriteSettingsStore(<String, String>{
          SettingsService.keyUploadToStrava: 'true',
          SettingsService.keyUploadToXingzhe: 'true',
          SettingsService.keyLookbackDays: '3',
        }),
      );

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(settingsService: settingsService)),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(platformSwitch('Strava'));
      await tester.tap(platformSwitch('Strava'));
      await tester.pumpAndSettle();

      final Finder stravaCard = find.widgetWithText(ListTile, 'Strava');
      final Switch switchWidget = tester.widget<Switch>(
        find.descendant(of: stravaCard, matching: find.byType(Switch)),
      );
      expect(switchWidget.value, isTrue);
      expect(find.text('设置保存失败: Exception: save failed'), findsOneWidget);
    },
  );

  group('导出配置', () {
    late _RecordingFilePicker picker;
    late List<MethodCall> shareCalls;
    FilePicker? originalPicker;

    const MethodChannel shareChannel = MethodChannel(
      'dev.fluttercommunity.plus/share',
    );

    void usePlatform(TargetPlatform platform) {
      // 框架的不变量校验（debugAssertAllFoundationVarsUnset）发生在 tearDown 之前，
      // 必须在测试体内 try/finally 复位，参见 strava_web_login_test.dart。
      debugDefaultTargetPlatformOverride = platform;
    }

    Future<void> pumpSettingsScreen(WidgetTester tester) async {
      final SettingsService settingsService = SettingsService(
        store: InMemorySettingsStore(<String, String>{
          SettingsService.keyOneLapUsername: 'rider',
          SettingsService.keyOneLapPassword: 'secret',
          SettingsService.keyLookbackDays: '5',
        }),
      );

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(settingsService: settingsService)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> confirmExport(WidgetTester tester) async {
      await tapVisibleText(tester, '导出配置');
      expect(find.text('配置文件包含账号密码等敏感信息，请妥善保管。'), findsOneWidget);
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
    }

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'WanSync',
        packageName: 'com.example.onelap_strava_sync',
        version: '9.9.9',
        buildNumber: '99',
        buildSignature: '',
      );

      originalPicker = _currentFilePicker();
      picker = _RecordingFilePicker();
      FilePicker.platform = picker;

      shareCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (MethodCall call) async {
            shareCalls.add(call);
            return 'success';
          });
    });

    tearDown(() {
      if (originalPicker != null) {
        FilePicker.platform = originalPicker!;
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, null);
    });

    /// 非 iOS 分支会真实读写临时文件：fake async 下真实 I/O 的 Future 永不完成
    /// （_exporting 卡住 → 无限动画），必须放在 runAsync 里驱动真实事件循环。
    Future<void> exportViaShareSheet(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tapVisibleText(tester, '导出配置');
        expect(find.text('配置文件包含账号密码等敏感信息，请妥善保管。'), findsOneWidget);
        await tester.tap(find.text('继续'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        for (int i = 0; i < 200 && shareCalls.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await tester.pump();
      });
      await tester.pumpAndSettle();
    }

    /// 分享面板必须收到合法 popover 锚点：非零且落在源视图坐标系内，
    /// 否则 iPad/macOS 原生侧抛 PlatformException（本次线上报错的根因）。
    void expectValidShareSheetCall() {
      expect(picker.saveCalls, isEmpty);
      expect(shareCalls, hasLength(1));
      final MethodCall call = shareCalls.single;
      expect(call.method, 'shareFiles');

      final Map<Object?, Object?> args =
          call.arguments as Map<Object?, Object?>;
      expect(
        (args['paths']! as List<Object?>).single as String,
        endsWith('onelap_config.json'),
      );

      final double originX = args['originX']! as double;
      final double originY = args['originY']! as double;
      final double originWidth = args['originWidth']! as double;
      final double originHeight = args['originHeight']! as double;
      expect(originWidth, greaterThan(0));
      expect(originHeight, greaterThan(0));
      // 锚点必须落在源视图坐标系内，否则原生侧抛 PlatformException
      expect(originX, greaterThanOrEqualTo(0));
      expect(originY, greaterThanOrEqualTo(0));
      expect(originX + originWidth, lessThanOrEqualTo(1080));
      expect(originY + originHeight, lessThanOrEqualTo(2400));
    }

    testWidgets('iOS 走系统保存对话框而不是分享面板', (WidgetTester tester) async {
      useLargeTestViewport(tester);
      usePlatform(TargetPlatform.iOS);
      try {
        await pumpSettingsScreen(tester);

        await confirmExport(tester);

        expect(picker.saveCalls, hasLength(1));
        final _SaveFileRequest request = picker.saveCalls.single;
        expect(request.fileName, 'onelap_config.json');
        expect(request.type, FileType.custom);
        expect(request.allowedExtensions, <String>['json']);

        final Uint8List bytes = request.bytes!;
        final Map<String, dynamic> decoded =
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        expect(decoded['version'], AppConfig.currentVersion);
        expect(decoded['appVersion'], '9.9.9');
        expect(
          decoded['settings'] as Map<String, dynamic>,
          containsPair('onelap', containsPair('username', 'rider')),
        );

        // 不再走分享面板：iPad/macOS 缺少 popover 锚点会直接报 PlatformException
        expect(shareCalls, isEmpty);
        expect(find.text('配置已保存'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Android 保持分享面板（行为不变）', (WidgetTester tester) async {
      useLargeTestViewport(tester);
      usePlatform(TargetPlatform.android);
      try {
        await pumpSettingsScreen(tester);

        await exportViaShareSheet(tester);

        expectValidShareSheetCall();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('系统对话框取消时不报错也不提示已保存', (WidgetTester tester) async {
      useLargeTestViewport(tester);
      usePlatform(TargetPlatform.iOS);
      try {
        await pumpSettingsScreen(tester);
        picker.resultPath = null;

        await confirmExport(tester);

        expect(picker.saveCalls, hasLength(1));
        expect(find.text('配置已保存'), findsNothing);
        expect(find.textContaining('导出失败'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('桌面平台保留分享面板且携带非空 popover 锚点', (WidgetTester tester) async {
      useLargeTestViewport(tester);
      usePlatform(TargetPlatform.macOS);
      try {
        await pumpSettingsScreen(tester);

        await exportViaShareSheet(tester);

        expectValidShareSheetCall();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

class _SaveFileRequest {
  const _SaveFileRequest({
    required this.fileName,
    required this.type,
    required this.allowedExtensions,
    required this.bytes,
  });

  final String? fileName;
  final FileType type;
  final List<String>? allowedExtensions;
  final Uint8List? bytes;
}

class _RecordingFilePicker extends FilePicker {
  final List<_SaveFileRequest> saveCalls = <_SaveFileRequest>[];
  String? resultPath = '/tmp/onelap_config.json';

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saveCalls.add(
      _SaveFileRequest(
        fileName: fileName,
        type: type,
        allowedExtensions: allowedExtensions,
        bytes: bytes,
      ),
    );
    return resultPath;
  }
}

/// [FilePicker.platform] 默认值是 `late`，测试环境下未被插件注册时会抛异常。
FilePicker? _currentFilePicker() {
  try {
    return FilePicker.platform;
  } catch (_) {
    return null;
  }
}
