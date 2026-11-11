import '../support/status_preview.dart';
import '../support/memory_store.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:water/app/app.dart';
import 'package:water/app/login_sheet.dart';

import '../support/test_dependencies.dart';

import 'package:water/app/app_theme.dart';
import 'package:water/core/models.dart';
import 'package:water/core/network.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets(
    'login, device selection, single tap starts and tab retains session',
    (tester) async {
      final d = TestDependencies(
        store: MemoryStore(),
        fake: FakeTransport(latency: Duration.zero),
      );
      await d.initialize();
      await tester.pumpWidget(WaterApp(dependencies: d, initialize: false));
      await tester.pumpAndSettle();
      expect(find.byTooltip('设置'), findsNothing);
      expect(find.textContaining('演示'), findsNothing);
      await tester.tap(find.text('登录胖乖生活'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '手机号'),
        '13000000000',
      );
      await tester.enterText(find.widgetWithText(TextField, '短信验证码'), '123456');
      await tester.ensureVisible(find.text('登录'));
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择饮水机'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('教学楼饮水机'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('开始喝水'));
      await tester.tap(find.text('开始喝水'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(d.drinking.active, isTrue);
      await tester.tap(find.text('洗澡'));
      await tester.pump();
      await tester.tap(find.text('喝水').last);
      await tester.pump();
      expect(d.drinking.active, isTrue);
      expect(
        d.fake!.requests.where((e) => e.path == '/goods/water/unlock').length,
        1,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      expect(d.drinking.active, isTrue);
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
      await tester.pumpWidget(const SizedBox.shrink());
      d.dispose();
    },
  );
  for (final size in [const Size(320, 700), const Size(1100, 850)]) {
    for (final dark in [false, true]) {
      testWidgets('${size.width} width, dark=$dark, 2x text and long name', (
        tester,
      ) async {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        final d = TestDependencies(
          store: MemoryStore(),
          fake: FakeTransport(latency: Duration.zero),
        );
        await d.initialize();
        await d.drinking.demoLogin();
        await d.drinking.selectDevice(
          const Device(
            id: 'demo-long-device',
            name: '教学楼一楼走廊靠近图书馆入口的饮水设备名称很长的测试设备',
          ),
        );
        await tester.pumpWidget(WaterApp(dependencies: d, initialize: false));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('开始喝水'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('开始喝水'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        d.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.platformDispatcher.clearPlatformBrightnessTestValue();
      });
    }
  }
  test('theme dynamic only Android and only complete pair', () {
    final l = ColorScheme.fromSeed(seedColor: Colors.green),
        b = ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
        );
    expect(
      waterTheme(
        Brightness.light,
        lightDynamic: l,
        darkDynamic: b,
        platform: TargetPlatform.android,
      ).colorScheme,
      l,
    );
    expect(
      waterTheme(
        Brightness.dark,
        lightDynamic: l,
        darkDynamic: b,
        platform: TargetPlatform.android,
      ).colorScheme,
      b,
    );
    for (final p in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      expect(
        waterTheme(
          Brightness.light,
          lightDynamic: l,
          darkDynamic: b,
          platform: p,
        ).colorScheme,
        ColorScheme.fromSeed(seedColor: pinkSeed),
      );
    }
    expect(
      waterTheme(
        Brightness.light,
        lightDynamic: l,
        platform: TargetPlatform.android,
      ).colorScheme,
      ColorScheme.fromSeed(seedColor: pinkSeed),
    );
  });
  testWidgets(
    'bath starts and ends with single taps without status, money or confirmation',
    (tester) async {
      final d = TestDependencies(
        store: MemoryStore(),
        fake: FakeTransport(latency: Duration.zero),
      );
      await d.initialize();
      await d.bathing.demoLogin();
      await tester.pumpWidget(WaterApp(dependencies: d, initialize: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('洗澡'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加设备'));
      await tester.pumpAndSettle();
      expect(find.text('填入演示设备'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, '粘贴二维码内容'),
        'fixture-qr',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('解析设备'));
      await tester.pumpAndSettle();
      expect(
        d.fake!.requests.where((e) => e.path == '/bath/valve/open'),
        isEmpty,
      );
      await tester.ensureVisible(find.text('使用此设备'));
      await tester.tap(find.text('使用此设备'));
      await tester.pumpAndSettle();
      expect(find.text('设备已选择，尚未开始'), findsOneWidget);
      await tester.ensureVisible(find.text('开始洗澡'));
      await tester.tap(find.text('开始洗澡'));
      await tester.tap(find.text('开始洗澡'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('确认开始'), findsNothing);
      expect(d.bathing.canClose, isTrue);
      expect(find.text('刷新状态'), findsNothing);
      expect(find.text('我已在官方客户端确认结束'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        d.fake!.requests.where((r) => r.path == '/bath/valve/open').length,
        1,
      );
      await tester.ensureVisible(find.text('结束洗澡'));
      await tester.tap(find.text('结束洗澡'));
      await tester.pumpAndSettle();
      expect(d.bathing.session!.stage, Stage.closed);
      expect(d.bathing.active, isFalse);
      expect(find.text('开始洗澡'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('刷新状态'), findsNothing);
      expect(find.text('我已在官方客户端确认结束'), findsNothing);
      expect(find.text('未提供结算账单'), findsNothing);
      expect(
        d.fake!.requests.where((r) => r.path == '/bath/valve/getStatus'),
        isEmpty,
      );
      expect(
        d.fake!.requests.where((r) => r.path == '/bath/valve/close').length,
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      d.dispose();
    },
  );
  testWidgets('all stage previews stay isolated and render at 320dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    for (final stage in Stage.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: DemoStatusPreview(key: ValueKey(stage), stage: stage),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull, reason: stage.name);
      expect(find.text('独立演示数据 · 不影响当前会话'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  testWidgets('SMS login uses the normal UI with an isolated fake transport', (
    tester,
  ) async {
    final d = TestDependencies(fake: FakeTransport(latency: Duration.zero));
    await d.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LoginSheet(controller: d.drinking)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('演示'), findsNothing);
    expect(find.textContaining('模拟'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextField, '手机号'),
      '13000000000',
    );
    await tester.ensureVisible(find.text('发送短信验证码'));
    await tester.tap(find.text('发送短信验证码'));
    await tester.pump();
    expect(find.text('短信发送请求已受理，请查看手机短信。'), findsOneWidget);
    expect(
      d.fake!.requests.where((r) => r.path == '/common/sms/sendCode').length,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    d.dispose();
  });
  testWidgets('single tap uses ambient water without any confirmation dialog', (
    tester,
  ) async {
    final fake = WaterChoiceFake();
    final d = TestDependencies(store: MemoryStore(), fake: fake);
    await d.initialize();
    await d.drinking.demoLogin();
    await d.drinking.selectDevice(d.drinking.devices.first);
    await tester.pumpWidget(WaterApp(dependencies: d, initialize: false));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('开始喝水'));
    await tester.tap(find.text('开始喝水'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('选择水温'), findsNothing);
    expect(find.text('刷新状态'), findsNothing);
    expect(find.text('正在读取状态'), findsNothing);
    expect(find.text('我已在官方客户端确认结束'), findsNothing);
    expect(d.drinking.session!.context['skuId'], 'cold');
    expect(d.drinking.session!.context['skuName'], '常温水');
    expect(
      fake.requests.where((r) => r.path == '/goods/water/unlock').length,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    d.dispose();
  });
  testWidgets(
    'timer keeps polling after unchanged silent response and automatically archives once',
    (tester) async {
      final fake = WidgetPollingFake();
      final d = TestDependencies(store: MemoryStore(), fake: fake);
      await d.initialize();
      await d.drinking.demoLogin();
      await d.drinking.selectDevice(d.drinking.devices.first);
      await tester.pumpWidget(WaterApp(dependencies: d, initialize: false));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('开始喝水'));
      await tester.tap(find.text('开始喝水'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
      }
      expect(d.drinking.session!.stage, Stage.completed);
      expect(
        fake.requests.where((r) => r.path == '/order/afterPay/creating').length,
        1,
      );
      expect(find.text('确认现场结束并生成订单'), findsNothing);
      expect(find.text('刷新状态'), findsNothing);
      expect(find.text('正在读取状态'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      d.dispose();
    },
  );
}

class WaterChoiceFake extends FakeTransport {
  WaterChoiceFake() : super(latency: Duration.zero);
  @override
  Future<WireResponse> send(WireRequest r) async {
    if (r.path == '/goods/normal/skus') {
      requests.add(r);
      return const WireResponse({
        'code': 200,
        'data': [
          {'skuId': 'hot', 'name': '热水'},
          {'skuId': 'cold', 'name': '常温水'},
        ],
      });
    }
    return super.send(r);
  }
}

class WidgetPollingFake extends FakeTransport {
  int index = 0;
  WidgetPollingFake() : super(latency: Duration.zero);
  @override
  Future<WireResponse> send(WireRequest r) async {
    if (r.path == '/goods/water/sync') {
      requests.add(r);
      const states = [0, 2, 2, 0];
      final state = states[index < states.length ? index++ : states.length - 1];
      return WireResponse({
        'code': 200,
        'data': {'workStatus': state},
      });
    }
    return super.send(r);
  }
}
