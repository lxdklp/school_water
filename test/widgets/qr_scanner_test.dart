import '../support/memory_store.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../support/test_dependencies.dart';

import 'package:water/app/app_shell.dart';
import 'package:water/core/models.dart';

import '../support/fake_transport.dart';

import 'package:water/features/bathing/presentation/qr_scanner_page.dart';

Barcode qr(String s) => Barcode(rawValue: s, format: BarcodeFormat.qrCode);

class FakeScanner extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  int starts = 0, stops = 0, disposals = 0;
  bool denied = false;
  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    if (denied) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      );
    }
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.unavailable,
      size: Size(320, 400),
      numberOfCameras: 1,
      initialDeviceOrientation: DeviceOrientation.portraitUp,
    );
  }

  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  test('one QR result, duplicate frames suppressed; invalid and multi-code input rejected', () {
    final gate = QrResultGate();
    expect(
      gate.accept([
        const Barcode(rawValue: 'abc', format: BarcodeFormat.code128),
      ]),
      isNull,
    );
    expect(gate.accept([qr('  ')]), isNull);
    expect(() => gate.accept([qr('a'), qr('b')]), throwsA(isA<ApiFailure>()));
    expect(() => gate.accept([qr('x' * 4097)]), throwsA(isA<ApiFailure>()));
    expect(
      gate.accept([
        qr('https://example.test/?q=中文+&a=1'),
        qr('https://example.test/?q=中文+&a=1'),
      ]),
      'https://example.test/?q=中文+&a=1',
    );
    expect(gate.accept([qr('other')]), isNull);
  });
  testWidgets(
    'scan fills complete text, resolves once, confirms selection, never starts',
    (tester) async {
      final d = TestDependencies(
        store: MemoryStore(),
        fake: FakeTransport(latency: Duration.zero),
      );
      await d.initialize();
      await d.bathing.demoLogin();
      const raw = 'https://example.test/?q=中文+&value=/?=';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BathDeviceSheet(
              controller: d.bathing,
              scan: (_) async => raw,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('扫描二维码'));
      await tester.pumpAndSettle();
      final request = d.fake!.requests.singleWhere(
        (r) => r.path == '/mgapp/machine/getInfoByQRCode',
      );
      expect(request.uri.queryParameters['qrcode'], raw);
      expect(d.bathing.device, isNull);
      expect(find.text('使用此设备'), findsOneWidget);
      expect(
        d.fake!.requests.any((r) => r.path == '/bath/valve/open'),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      d.dispose();
    },
  );
  testWidgets('cancel scan keeps input and sends no parse request', (
    tester,
  ) async {
    final d = TestDependencies(
      store: MemoryStore(),
      fake: FakeTransport(latency: Duration.zero),
    );
    await d.initialize();
    await d.bathing.demoLogin();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BathDeviceSheet(controller: d.bathing, scan: (_) async => null),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'previous input');
    await tester.tap(find.text('扫描二维码'));
    await tester.pumpAndSettle();
    expect(find.text('previous input'), findsOneWidget);
    expect(d.fake!.requests.any((r) => r.path.contains('QRCode')), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    d.dispose();
  });
  for (final denied in [false, true]) {
    testWidgets('camera denied=$denied, lifecycle and release', (tester) async {
      final original = MobileScannerPlatform.instance,
          fake = FakeScanner()..denied = denied;
      MobileScannerPlatform.instance = fake;
      MobileScannerController.resetPlatformSessionOwner();
      await tester.pumpWidget(const MaterialApp(home: QrScannerPage()));
      await tester.pumpAndSettle();
      expect(fake.starts, 1);
      if (denied) {
        expect(find.textContaining('未获得相机权限'), findsOneWidget);
        expect(find.text('返回手动输入'), findsOneWidget);
      } else {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pumpAndSettle();
        expect(fake.stops, greaterThanOrEqualTo(1));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(fake.starts, 2);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(fake.disposals, greaterThanOrEqualTo(1));
      await fake.captures.close();
      MobileScannerPlatform.instance = original;
    });
  }
}
