import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/models.dart';

/// Accept one complete QR payload exactly once. Never follows URLs or infers a
/// device ID. The returned text must still pass the platform's device parser.
class QrResultGate {
  bool _consumed = false;
  String? accept(Iterable<Barcode> barcodes) {
    if (_consumed) return null;
    final values = barcodes
        .where((b) => b.format == BarcodeFormat.qrCode)
        .map((b) => b.rawValue?.trim())
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet();
    if (values.isEmpty) return null;
    if (values.length != 1) throw const ApiFailure('画面中有多个二维码，请只对准一个设备二维码');
    final result = input(values.single);
    _consumed = true;
    return result;
  }
}

class QrScannerPage extends StatefulWidget {
  final MobileScannerController? controller;
  const QrScannerPage({super.key, this.controller});
  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage>
    with WidgetsBindingObserver {
  late final MobileScannerController controller;
  final gate = QrResultGate();
  bool _returned = false, _starting = false, _foreground = true;
  String? hint;

  @override
  void initState() {
    super.initState();
    controller =
        widget.controller ??
        MobileScannerController(
          autoStart: false,
          formats: const [BarcodeFormat.qrCode],
          facing: CameraFacing.back,
          detectionSpeed: DetectionSpeed.noDuplicates,
          returnImage: false,
        );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    if (!mounted ||
        _returned ||
        _starting ||
        !_foreground ||
        controller.value.isRunning) {
      return;
    }
    _starting = true;
    try {
      await controller.start();
      if ((!mounted || !_foreground || _returned) &&
          controller.value.isRunning) {
        await controller.stop();
      }
    } catch (_) {
      // The controller exposes a typed error to errorBuilder. Never print data.
      if (mounted) setState(() => hint = '相机启动失败，请检查权限后重试');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop() async {
    try {
      await controller.stop();
    } catch (_) {
      /* Disposing still releases the camera. */
    }
  }

  void _detect(BarcodeCapture capture) {
    if (_returned || !mounted || !_foreground) return;
    try {
      final result = gate.accept(capture.barcodes);
      if (result == null) return;
      _returned = true;
      unawaited(_finish(result));
    } on ApiFailure catch (e) {
      setState(() => hint = e.message);
    }
  }

  Future<void> _finish(String result) async {
    await _stop();
    if (mounted) Navigator.pop(context, result);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      if (controller.value.hasCameraPermission) unawaited(_start());
    } else {
      unawaited(_stop());
    }
  }

  @override
  void dispose() {
    _returned = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(controller.dispose());
    super.dispose();
  }

  Widget _cameraError(BuildContext context, MobileScannerException error) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final unsupported = error.errorCode == MobileScannerErrorCode.unsupported;
    return Container(
      color: Theme.of(context).colorScheme.surface,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              denied
                  ? Icons.no_photography_outlined
                  : Icons.camera_alt_outlined,
              size: 40,
            ),
            const SizedBox(height: 16),
            Text(
              denied
                  ? '未获得相机权限，请在系统设置中允许“校园用水”使用相机，或返回粘贴二维码内容。'
                  : unsupported
                  ? '此设备无法使用相机扫码，请返回粘贴二维码内容。'
                  : '相机暂时不可用，请重试或返回粘贴二维码内容。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (!unsupported)
              OutlinedButton(onPressed: _start, child: const Text('重新开启相机')),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回手动输入'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('扫描浴室二维码'),
      actions: [
        ValueListenableBuilder<MobileScannerState>(
          valueListenable: controller,
          builder: (_, state, _) => IconButton(
            tooltip: state.torchState == TorchState.on ? '关闭手电筒' : '打开手电筒',
            onPressed:
                state.isRunning && state.torchState != TorchState.unavailable
                ? () async {
                    try {
                      await controller.toggleTorch();
                    } catch (_) {}
                  }
                : null,
            icon: Icon(
              state.torchState == TorchState.on
                  ? Icons.flash_on
                  : Icons.flash_off,
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('对准浴室设备二维码，识别后将解析设备信息。'),
          ),
          Expanded(
            child: MobileScanner(
              controller: controller,
              useAppLifecycleState: false,
              tapToFocus: true,
              onDetect: _detect,
              errorBuilder: _cameraError,
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Semantics(liveRegion: true, child: Text(hint!)),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回粘贴二维码内容'),
            ),
          ),
        ],
      ),
    ),
  );
}
