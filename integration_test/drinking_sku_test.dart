import '../test/support/memory_store.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:water/app/app.dart';

import '../test/support/test_dependencies.dart';

import 'package:water/core/models.dart';
import 'package:water/core/network.dart';

import '../test/support/fake_transport.dart';

class MultiSkuFake extends FakeTransport {
  MultiSkuFake() : super(latency: Duration.zero);
  int reads = 0;
  @override
  Future<WireResponse> send(WireRequest r) async {
    if (r.path == '/goods/normal/skus') {
      requests.add(r);
      return const WireResponse({
        'code': 200,
        'data': [
          {'skuId': 'mock-hot', 'name': '热水'},
          {'skuId': 'mock-cold', 'name': '常温水'},
        ],
      });
    }
    if (r.path == '/goods/water/sync') {
      requests.add(r);
      const states = [0, 2, 2, 0];
      final state = states[reads < states.length ? reads++ : states.length - 1];
      return WireResponse({
        'code': 200,
        'data': {'workStatus': state},
      });
    }
    return super.send(r);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('ambient water only with fake billing', (tester) async {
    final fake = MultiSkuFake();
    final d = TestDependencies(store: MemoryStore(), fake: fake);
    await d.initialize();
    await d.drinking.demoLogin();
    await d.drinking.selectDevice(d.drinking.devices.first);
    await tester.pumpWidget(WaterApp(dependencies: d, initialize: false));
    await tester.pumpAndSettle();
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('开始喝水'));
    await tester.tap(find.text('开始喝水'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('选择水温'), findsNothing);
    expect(find.text('刷新状态'), findsNothing);
    expect(find.text('正在读取状态'), findsNothing);
    expect(d.drinking.session!.context['skuId'], 'mock-cold');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(d.drinking.session!.stage, Stage.working);
    await binding.takeScreenshot('drinking-silent-working');
    for (
      var i = 0;
      i < 40 && d.drinking.session?.stage != Stage.completed;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(d.drinking.session!.stage, Stage.completed);
    expect(
      fake.requests.where((r) => r.path == '/goods/water/unlock').length,
      1,
    );
    expect(
      fake.requests.where((r) => r.path == '/order/afterPay/creating').length,
      1,
    );
    expect(find.text('确认现场结束并生成订单'), findsNothing);
    expect(find.text('刷新状态'), findsNothing);
    await binding.takeScreenshot('drinking-automatic-order-saved');
    await tester.pumpWidget(const SizedBox.shrink());
    d.dispose();
  });
}
