import '../support/memory_store.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:water/app/app.dart';

import '../support/test_dependencies.dart';

import 'package:water/core/models.dart';

import '../support/fake_transport.dart';

// Opt-in visual artifacts. Run with --dart-define=EXPORT_SCREENSHOTS=true.
void main() {
  const enabled = bool.fromEnvironment('EXPORT_SCREENSHOTS');
  testWidgets('export narrow and desktop rendered UI', skip: !enabled, (
    tester,
  ) async {
    final fontPath = Platform.environment['WATER_TEST_CJK_FONT'];
    await tester.runAsync(() async {
      final font = fontPath == null ? null : File(fontPath);
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        Future.value(
          ByteData.sublistView(
            await File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf')
                .readAsBytes(),
          ),
        ),
      );
      await icons.load();
      if (font != null && await font.exists()) {
        final loader = FontLoader('Roboto');
        loader.addFont(
          Future.value(ByteData.sublistView(await font.readAsBytes())),
        );
        await loader.load();
      }
    });
    final d = TestDependencies(
      store: MemoryStore(),
      fake: FakeTransport(latency: Duration.zero),
    );
    await d.initialize();
    await d.drinking.demoLogin();
    await d.drinking.selectDevice(d.drinking.devices.first);
    await d.bathing.demoLogin();
    await d.bathing.selectDevice(
      const Device(
        id: 'demo-bath-A7FA',
        name: '宿舍浴室',
        version: '01,82',
        typeId: 1,
        channelWay: 4,
      ),
    );
    final key = GlobalKey();
    for (final size in [const Size(320, 780), const Size(1100, 850)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: WaterApp(dependencies: d, initialize: false),
        ),
      );
      await tester.pumpAndSettle();
      for (final dark in [false, true]) {
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File(
            'docs/screenshots/${size.width.toInt()}-${dark ? 'dark' : 'light'}.png',
          ).writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    d.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });
}
