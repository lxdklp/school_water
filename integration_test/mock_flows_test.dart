import '../test/support/memory_store.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:water/app/app.dart';

import '../test/support/test_dependencies.dart';

import 'package:water/core/models.dart';
import 'package:water/core/storage.dart';

import '../test/support/fake_transport.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('platform mock flows, screenshots and secure-store readback', (
    tester,
  ) async {
    const secure = SecureStore();
    final key = 'water.mock.integration.${newId()}';
    await secure.write(key, 'fixture');
    expect(await secure.read(key), 'fixture');
    await secure.delete(key);
    final d = TestDependencies(
      store: MemoryStore(),
      fake: FakeTransport(latency: Duration.zero),
    );
    await d.initialize();
    await tester.pumpWidget(WaterApp(dependencies: d, initialize: false));
    await tester.pumpAndSettle();
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('mobile-logged-out');
    await d.drinking.demoLogin();
    await tester.pumpAndSettle();
    expect(find.byTooltip('设置'), findsNothing);
    expect(find.textContaining('演示'), findsNothing);
    await tester.tap(find.text('选择饮水机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('教学楼饮水机'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('mobile-drinking-light');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    await binding.takeScreenshot('mobile-drinking-dark');
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('开始喝水'));
    await tester.tap(find.text('开始喝水'));
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(d.drinking.active, isTrue);
    await tester.tap(find.text('洗澡'));
    await tester.pumpAndSettle();
    await d.bathing.demoLogin();
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加设备'));
    await tester.pumpAndSettle();
    expect(find.text('填入演示设备'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextField, '粘贴二维码内容'),
      'fixture-qr',
    );
    await tester.enterText(find.widgetWithText(TextField, '本地备注（可选）'), '宿舍浴室');
    await tester.pumpAndSettle();
    await tester.tap(find.text('解析设备'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('使用此设备'));
    await tester.tap(find.text('使用此设备'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('mobile-bathing-light');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    await binding.takeScreenshot('mobile-bathing-dark');
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('开始洗澡'));
    await tester.tap(find.text('开始洗澡'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('确认开始'), findsNothing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(d.bathing.canClose, isTrue);
    await binding.takeScreenshot('bathing-single-tap-start');
    await tester.ensureVisible(find.text('结束洗澡'));
    await tester.tap(find.text('结束洗澡'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(d.bathing.session!.stage, Stage.closed);
    expect(d.bathing.canStart, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('刷新状态'), findsNothing);
    expect(find.text('我已在官方客户端确认结束'), findsNothing);
    expect(
      d.fake!.requests.where((r) => r.path == '/bath/valve/getStatus'),
      isEmpty,
    );
    await binding.takeScreenshot('bathing-directly-ended');
    expect(
      d.fake!.requests.where((r) => r.path == '/bath/valve/open').length,
      1,
    );
    expect(
      d.fake!.requests.where((r) => r.path == '/bath/valve/close').length,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    d.dispose();
  });
}
