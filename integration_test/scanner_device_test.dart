import '../test/support/memory_store.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../test/support/test_dependencies.dart';

import 'package:water/app/app_shell.dart';

import '../test/support/fake_transport.dart';

import 'package:water/features/bathing/presentation/qr_scanner_page.dart';

import 'qr_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'physical camera and native QR decoding with fake device resolution',
    (tester) async {
      final d = TestDependencies(
        store: MemoryStore(),
        fake: FakeTransport(latency: Duration.zero),
      );
      await d.initialize();
      await d.bathing.demoLogin();
      final scanner = MobileScannerController(
        autoStart: false,
        formats: const [BarcodeFormat.qrCode],
        returnImage: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('扫码离线验证')),
            body: BathDeviceSheet(
              controller: d.bathing,
              scan: (ctx) => Navigator.of(ctx).push<String>(
                MaterialPageRoute(
                  builder: (_) => QrScannerPage(controller: scanner),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('扫描二维码'));
      await tester.pump(const Duration(milliseconds: 300));
      for (
        var i = 0;
        i < 100 && !scanner.value.isRunning && scanner.value.error == null;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(scanner.value.error, isNull);
      expect(scanner.value.hasCameraPermission, isTrue);
      expect(scanner.value.isRunning, isTrue);
      // CameraX reports initialized before the capture session is configured.
      // Keep it active long enough to exercise the hardware preview session.
      await tester.pump(const Duration(seconds: 3));
      expect(scanner.value.error, isNull);
      expect(scanner.value.isRunning, isTrue);

      final file = File('${Directory.systemTemp.path}/water-qr-fixture.png');
      await file.writeAsBytes(base64Decode(qrFixtureBase64));
      final capture = await scanner.analyzeImage(
        file.path,
        formats: const [BarcodeFormat.qrCode],
      );
      await file.delete();
      expect(capture, isNotNull);
      expect(capture!.barcodes.single.rawValue, qrFixtureText);
      // Feed a result decoded by the device's actual native decoder through the
      // same UI callback as camera captures. No real device QR or server is used.
      tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
        capture,
      );
      await tester.pumpAndSettle();
      expect(find.text('使用此设备'), findsOneWidget);
      expect(scanner.value.isRunning, isFalse);
      expect(d.bathing.device, isNull);
      expect(
        d.fake!.requests
            .where((r) => r.path == '/mgapp/machine/getInfoByQRCode')
            .single
            .uri
            .queryParameters['qrcode'],
        qrFixtureText,
      );
      expect(
        d.fake!.requests.any(
          (r) => r.path == '/bath/valve/open' || r.path == '/bath/valve/close',
        ),
        isFalse,
      );
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('qr-device-preview');
      await tester.pumpWidget(const SizedBox.shrink());
      d.dispose();
    },
  );
}
