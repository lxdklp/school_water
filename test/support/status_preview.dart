import 'dart:async';

import 'package:flutter/material.dart';
import 'package:water/app/app_shell.dart';
import 'package:water/app/water_controller.dart';
import 'package:water/core/models.dart';

import 'test_dependencies.dart';
import 'fake_transport.dart';
import 'memory_store.dart';

/// Each preview has its own fake transport and volatile store. It cannot alter
/// the app's current journal or construct a real network client.
class DemoStatusPreview extends StatefulWidget {
  final Stage stage;
  const DemoStatusPreview({super.key, required this.stage});
  @override
  State<DemoStatusPreview> createState() => _DemoStatusPreviewState();
}

class _DemoStatusPreviewState extends State<DemoStatusPreview> {
  late final TestDependencies dependencies;
  WaterController? controller;
  bool disposed = false;
  @override
  void initState() {
    super.initState();
    dependencies = TestDependencies(
      store: MemoryStore(),
      fake: FakeTransport(latency: Duration.zero),
    );
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    await dependencies.initialize();
    final bath = {
      Stage.sendingOpen,
      Stage.openAccepted,
      Stage.running,
      Stage.sendingClose,
      Stage.closeAccepted,
      Stage.closed,
      Stage.uncertain,
      Stage.resolvedByUser,
    }.contains(widget.stage);
    final c = bath ? dependencies.bathing : dependencies.drinking;
    await c.demoLogin();
    await c.selectDevice(
      bath
          ? const Device(
              id: 'demo-bath-A7FA',
              name: '宿舍浴室',
              version: '01,82',
              typeId: 1,
              channelWay: 4,
            )
          : c.devices.first,
    );
    c.session = Session(
      id: newId(),
      accountScope: c.account!.scope,
      origin: c.account!.origin,
      platform: c.platform,
      device: c.device!,
      stage: widget.stage,
      intentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
      context: {
        'usePoints': true,
        if (!bath) 'autoCreateOrder': true,
        'skuId': 'demo-sku',
        'initialOrderNo': 'demo-order',
        'everWorked': true,
        if (bath && widget.stage != Stage.uncertain)
          'openCommunicationVal': 'demo-open-A',
        if ({
          Stage.sendingClose,
          Stage.closeAccepted,
          Stage.closed,
        }.contains(widget.stage))
          'closeAttempted': true,
        if ({Stage.closeAccepted, Stage.closed}.contains(widget.stage))
          'closeCommunicationVal': 'demo-close-B',
        if (widget.stage == Stage.uncertain) 'reason': 'demoResponseLost',
        if (widget.stage == Stage.completed)
          'detail': {
            'tradeOrderItem': [
              {'originPrice': '0.12'},
            ],
            'promotionList': [
              {'promotionType': 8, 'discountAmount': '0.11'},
            ],
          },
      },
    );
    c.busy = {
      Stage.preparing,
      Stage.sendingUnlock,
      Stage.creatingOrder,
      Stage.loadingOrder,
      Stage.sendingOpen,
      Stage.sendingClose,
    }.contains(widget.stage);
    if (disposed) {
      dependencies.dispose();
      return;
    }
    setState(() => controller = c);
  }

  @override
  void dispose() {
    disposed = true;
    if (controller != null) dependencies.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('演示状态预览')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('独立演示数据 · 不影响当前会话'),
          ),
          Expanded(
            child: controller == null
                ? const Center(child: CircularProgressIndicator())
                : ListenableBuilder(
                    listenable: controller!,
                    builder: (_, _) => WaterPage(controller: controller!),
                  ),
          ),
        ],
      ),
    ),
  );
}
