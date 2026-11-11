import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/money.dart';
import '../features/drinking/drinking_api.dart';
import '../features/bathing/presentation/qr_scanner_page.dart';
import 'app_dependencies.dart';
import 'water_controller.dart';
import 'login_sheet.dart';

String stageText(Stage stage) => switch (stage) {
  Stage.preflightFailed => '未发送开水指令，请检查提示后重试',
  Stage.preparing => '正在准备本次取水',
  Stage.sendingUnlock => '正在发送开水指令',
  Stage.awaitingWork => '已提交开水请求',
  Stage.working => '设备正在工作',
  Stage.completionUnconfirmed => '使用状态已变化，正在处理本次订单',
  Stage.creatingOrder => '正在生成本次订单',
  Stage.loadingOrder => '正在读取订单详情',
  Stage.completed => '订单已保存',
  Stage.sendingOpen => '正在发送开始指令',
  Stage.openAccepted => '洗澡进行中',
  Stage.running => '洗澡进行中',
  Stage.sendingClose => '正在发送结束指令',
  Stage.closeAccepted => '正在保存本次记录',
  Stage.closed => '洗澡已结束',
  Stage.uncertain => '状态待确认，请检查现场设备或官方客户端',
  Stage.resolvedByUser => '用户已确认结束',
};

Future<bool> confirm(
  BuildContext context,
  String title,
  String message, {
  String action = '确认',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
Future<void> report(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiFailure ? e.message : '操作未完成，请稍后查看')),
      );
    }
  }
}

class AppShell extends StatefulWidget {
  final AppDependencies dependencies;
  const AppShell({super.key, required this.dependencies});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 0;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.dependencies.drinking,
      widget.dependencies.bathing,
    ]),
    builder: (context, _) {
      final ds = widget.dependencies;
      final c = index == 0 ? ds.drinking : ds.bathing;
      return Scaffold(
        appBar: AppBar(
          title: Text(index == 0 ? '喝水' : '洗澡'),
          actions: [
            IconButton(
              tooltip: '账号',
              onPressed: () => showAccount(context, c),
              icon: const Icon(Icons.account_circle_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: index,
                  children: [
                    WaterPage(controller: ds.drinking),
                    WaterPage(controller: ds.bathing),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (value) => setState(() => index = value),
          destinations: [
            NavigationDestination(
              icon: _navIcon(Icons.local_drink_outlined, ds.drinking.active),
              selectedIcon: _navIcon(Icons.local_drink, ds.drinking.active),
              label: '喝水',
            ),
            NavigationDestination(
              icon: _navIcon(Icons.shower_outlined, ds.bathing.active),
              selectedIcon: _navIcon(Icons.shower, ds.bathing.active),
              label: '洗澡',
            ),
          ],
        ),
      );
    },
  );
  Widget _navIcon(IconData icon, bool active) => Semantics(
    label: active ? '有未完成用水' : null,
    child: Badge(isLabelVisible: active, smallSize: 6, child: Icon(icon)),
  );
}

class PageBody extends StatelessWidget {
  final List<Widget> children;
  const PageBody({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: ListView(padding: const EdgeInsets.all(16), children: children),
    ),
  );
}

class WaterPage extends StatelessWidget {
  final WaterController controller;
  const WaterPage({super.key, required this.controller});
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final t = Theme.of(context).textTheme;
    if (!c.initialized) return const Center(child: CircularProgressIndicator());
    final body = PageBody(
      children: [
        if (c.account != null && !c.isBath)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                Text('积分 ${c.balance['integral'] ?? '—'}'),
                Text('可抵扣 ¥${moneyText(c.balance['integralAmount'])}'),
                Text('小票 ¥${moneyText(c.balance['tokenCoin'], cents: true)}'),
              ],
            ),
          ),
        const SizedBox(height: 24),
        if (c.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: ErrorNotice(message: c.error!),
          ),
        if (c.account == null && !c.active) ...[
          const SizedBox(height: 24),
          Icon(
            c.isBath ? Icons.shower_outlined : Icons.local_drink_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            c.isBath ? '登录后选择浴室设备' : '登录后查看历史饮水机',
            textAlign: TextAlign.center,
            style: t.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            c.isBath ? '粘贴设备二维码内容，解析后使用。' : '使用胖乖生活账号，保留你的积分抵扣选择。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => showAccount(context, c),
            child: Text(c.isBath ? '登录 lxt6 洗澡账号' : '登录胖乖生活'),
          ),
        ] else ...[
          DeviceCard(controller: c),
          if (c.account == null || !c.sameAccount)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton(
                onPressed: () => showAccount(context, c),
                child: const Text('使用原账号重新登录'),
              ),
            ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(c.isBath ? '最近操作' : '最近订单', style: t.titleMedium),
            ),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => HistoryPage(controller: c),
                ),
              ),
              child: const Text('查看全部'),
            ),
          ],
        ),
        Text(
          c.isBath ? '仅本 App 保存的操作记录' : '仅本 App 保存的订单',
          style: t.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (c.history.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('暂无本地记录'),
          ),
        for (final s in c.history.take(3)) HistoryTile(session: s),
      ],
    );
    if (c.isBath) return body;
    return RefreshIndicator(
      onRefresh: () async {
        if (c.active) {
          await c.refreshSession();
        } else {
          await c.refreshProfile();
        }
      },
      child: body,
    );
  }
}

class ErrorNotice extends StatelessWidget {
  final String message;
  const ErrorNotice({super.key, required this.message});
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    ),
  );
}

Future<void> beginWater(BuildContext context, WaterController c) =>
    report(context, () async {
      if (!c.canStart) return;
      await c.start();
    });

class DeviceCard extends StatelessWidget {
  final WaterController controller;
  const DeviceCard({super.key, required this.controller});
  @override
  Widget build(BuildContext context) {
    final c = controller, s = controller.session;
    final t = Theme.of(context).textTheme;
    final status = s == null
        ? c.device == null
              ? '尚未选择设备'
              : c.isBath
              ? '设备已选择，尚未开始'
              : '设备已选择，等待开始'
        : stageText(s.stage);
    return Card.filled(
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('当前设备', style: t.titleMedium)),
                TextButton(
                  onPressed: c.active || c.busy || c.account == null
                      ? null
                      : () => selectDeviceSheet(context, c),
                  child: Text(c.device == null ? '选择' : '更换'),
                ),
              ],
            ),
            if (c.device != null) ...[
              Text(c.device!.name, style: t.titleLarge),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '设备编号末尾 ${c.device!.id.substring(c.device!.id.length > 4 ? c.device!.id.length - 4 : 0)}',
                  style: t.bodyMedium,
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      '${c.device!.id}${c.isBath ? '\n版本 ${c.device!.version ?? '未知'} · 类型 ${c.device!.typeId ?? '未知'}' : ''}',
                    ),
                  ),
                ],
              ),
            ],
            if (!c.isBath && s?.context['skuName'] is String)
              Text('本次水温：${s!.context['skuName']}'),
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              child: Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(status, style: t.bodyLarge),
                      if (c.active)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: ElapsedTime(start: s!.intentAt),
                        ),
                      if (c.storageBlocked)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('存储异常，恢复能力受影响。请核对现场设备。'),
                        ),
                      if (s?.stage == Stage.resolvedByUser)
                        const Text('此状态由用户确认，未经服务端终态验证'),
                    ],
                  ),
                ),
              ),
            ),
            if (!c.isBath)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('使用积分抵扣'),
                value: c.usePoints,
                onChanged: c.active || c.busy ? null : c.setPoints,
              ),
            if (c.busy)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(),
              ),
            if (!c.active) ...[
              if (c.device == null)
                FilledButton(
                  onPressed: c.account == null || c.busy
                      ? null
                      : () => selectDeviceSheet(context, c),
                  child: Text(c.isBath ? '添加设备' : '选择饮水机'),
                )
              else
                FilledButton(
                  onPressed: c.canStart ? () => beginWater(context, c) : null,
                  child: Text(c.isBath ? '开始洗澡' : '开始喝水'),
                ),
              if (c.isBath && c.device != null && !c.device!.bathSupported)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('仅支持已确认的 01,82 / 4G 洗浴设备，此设备仅供预览'),
                ),
              if (!c.isBath && c.device == null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('暂无历史饮水机时，请先在官方客户端使用一次后刷新'),
                ),
            ],
            if (c.canClose)
              FilledButton(onPressed: c.close, child: const Text('结束洗澡')),
            if (c.canCreate && !c.autoCreateAllowed)
              FilledButton(
                onPressed: c.createOrder,
                child: const Text('继续生成本次订单'),
              ),
            if (c.active) ...[
              const SizedBox(height: 8),
              if (c.isBath && s?.stage == Stage.uncertain && !c.canClose)
                TextButton(
                  onPressed: c.busy ? null : c.resolveByUser,
                  child: const Text('结束本次记录'),
                ),
              TextButton(
                onPressed: () => showSessionDetails(context, s!),
                child: const Text('查看本次详情'),
              ),
              if (!c.isBath &&
                  (s?.stage == Stage.uncertain ||
                      s?.context['autoCreateOrder'] != true))
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () async {
                          if (await confirm(
                            context,
                            '标记为用户确认结束',
                            '仅在你已在现场或官方客户端确认本次用水结束后使用。此操作只保存本地标记，不会发送结束指令，也不代表服务端已关闭或结算。',
                            action: '我已确认结束',
                          )) {
                            await c.resolveByUser();
                          }
                        },
                  child: const Text('我已在官方客户端确认结束'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class ElapsedTime extends StatefulWidget {
  final DateTime start;
  const ElapsedTime({super.key, required this.start});
  @override
  State<ElapsedTime> createState() => _ElapsedTimeState();
}

class _ElapsedTimeState extends State<ElapsedTime> with WidgetsBindingObserver {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      timer?.cancel();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = DateTime.now()
        .difference(widget.start)
        .inSeconds
        .clamp(0, 99999999);
    return Text(
      '本地经过 ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} · 非计费时长',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

Future<void> selectDeviceSheet(BuildContext context, WaterController c) async {
  if (c.isBath) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => BathDeviceSheet(controller: c),
    );
  } else {
    await c.refreshProfile();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .5,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Text('选择饮水机', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 16),
            if (c.devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('暂无历史饮水机，请先在官方客户端使用一次后刷新'),
              ),
            for (final d in c.devices)
              ListTile(
                leading: const Icon(Icons.local_drink_outlined),
                title: Text(d.name),
                onTap: () => report(ctx, () async {
                  await c.selectDevice(d);
                  if (ctx.mounted) Navigator.pop(ctx);
                }),
              ),
            TextButton(
              onPressed: () => report(ctx, c.refreshProfile),
              child: const Text('刷新'),
            ),
          ],
        ),
      ),
    );
  }
}

class BathDeviceSheet extends StatefulWidget {
  final WaterController controller;
  final Future<String?> Function(BuildContext)? scan;
  const BathDeviceSheet({super.key, required this.controller, this.scan});
  @override
  State<BathDeviceSheet> createState() => _BathDeviceSheetState();
}

class _BathDeviceSheetState extends State<BathDeviceSheet> {
  Future<void> _resolve() async {
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
      resolved = null;
    });
    try {
      final d = await widget.controller.resolveDevice(qr.text, note.text);
      if (mounted) setState(() => resolved = d);
    } catch (e) {
      if (mounted) {
        setState(() => error = e is ApiFailure ? e.message : '解析失败，请重试');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _scan() async {
    if (busy) return;
    FocusScope.of(context).unfocus();
    setState(() => busy = true);
    try {
      final value =
          await (widget.scan?.call(context) ??
              Navigator.of(context).push<String>(
                MaterialPageRoute(builder: (_) => const QrScannerPage()),
              ));
      if (!mounted || value == null) return;
      qr.text = value;
      await _resolve();
    } catch (_) {
      if (mounted) setState(() => error = '扫码未完成，请重试或粘贴二维码内容');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  final qr = TextEditingController(), note = TextEditingController();
  Device? resolved;
  String? error;
  bool busy = false;
  @override
  void dispose() {
    qr.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 16,
      right: 16,
      top: 24,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('添加浴室设备', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫描二维码'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: qr,
              enabled: !busy,
              maxLength: 4096,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '粘贴二维码内容',
                alignLabelWithHint: true,
              ),
              onChanged: (_) => setState(() => resolved = null),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              enabled: !busy,
              maxLength: 120,
              decoration: const InputDecoration(labelText: '本地备注（可选）'),
              onChanged: (_) => setState(() => resolved = null),
            ),
            if (error != null) ErrorNotice(message: error!),
            OutlinedButton(
              onPressed: busy ? null : _resolve,
              child: Text(busy ? '正在解析' : '解析设备'),
            ),
            if (resolved != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                '设备编号 ${resolved!.id}\n版本 ${resolved!.version ?? '未知'} · 类型 ${resolved!.typeId ?? '未知'}',
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => report(context, () async {
                  await widget.controller.rememberDevice(resolved!);
                  if (context.mounted) Navigator.pop(context);
                }),
                child: const Text('使用此设备'),
              ),
            ],
            if (widget.controller.devices.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text('最近设备'),
              for (final d in widget.controller.devices)
                ListTile(
                  title: Text(d.name),
                  subtitle: Text('版本 ${d.version ?? '未知'}'),
                  onTap: () => report(context, () async {
                    await widget.controller.selectDevice(d);
                    if (context.mounted) Navigator.pop(context);
                  }),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

String dateText(DateTime date) {
  final d = date.toLocal();
  return '${d.month}月${d.day}日 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class HistoryTile extends StatelessWidget {
  final Session session;
  const HistoryTile({super.key, required this.session});
  @override
  Widget build(BuildContext context) {
    final detail = session.platform == WaterPlatform.drinking
        ? session.context['detail']
        : null;
    final items = detail is Map ? detail['tradeOrderItem'] : null;
    final originalPrice =
        items is List && items.length == 1 && items.single is Map
        ? moneyText((items.single as Map)['originPrice'])
        : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(session.device.name),
      subtitle: Text(
        '${stageText(session.stage)}\n${dateText(session.intentAt)}',
      ),
      trailing: originalPrice == null
          ? const Icon(Icons.chevron_right)
          : Text('¥$originalPrice'),
      onTap: () => showSessionDetails(context, session),
    );
  }
}

class HistoryPage extends StatelessWidget {
  final WaterController controller;
  const HistoryPage({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => Scaffold(
      appBar: AppBar(title: Text(controller.isBath ? '本地操作记录' : '本地订单')),
      body: SafeArea(
        child: PageBody(
          children: [
            Text(
              controller.isBath ? '仅本 App 保存的操作记录，不代表完整平台账单' : '仅本 App 保存的订单',
            ),
            const SizedBox(height: 16),
            if (controller.history.isEmpty) const Text('暂无本地记录'),
            for (final s in controller.history) HistoryTile(session: s),
          ],
        ),
      ),
    ),
  );
}

Future<void> showSessionDetails(
  BuildContext context,
  Session s,
) => Navigator.push<void>(
  context,
  MaterialPageRoute<void>(
    builder: (ctx) {
      final detail = s.context['detail'];
      final failedStep = s.context['failedStep'];
      final amount = detail is Map<String, dynamic>
          ? calculatedPayment(detail)
          : null;
      return Scaffold(
        appBar: AppBar(title: const Text('本次详情')),
        body: SafeArea(
          child: PageBody(
            children: [
              Text(s.device.name, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              Text(stageText(s.stage)),
              if (failedStep != null)
                Text('失败步骤：${drinkingStepName(failedStep)}'),
              if (s.context['skuName'] is String)
                Text('水温：${s.context['skuName']}'),
              const SizedBox(height: 12),
              Text(dateText(s.intentAt)),
              const SizedBox(height: 12),
              if (s.platform == WaterPlatform.drinking)
                Text('积分抵扣：${s.context['usePoints'] == true ? '开启' : '关闭'}'),
              if (s.context['initialOrderNo'] != null)
                SelectableText('订单号 ${s.context['initialOrderNo']}'),
              if (s.context['orderId'] != null)
                SelectableText('订单 ID ${s.context['orderId']}'),
              if (s.platform == WaterPlatform.drinking && detail is Map) ...[
                const SizedBox(height: 24),
                const Text('订单明细'),
                for (final item in detail['tradeOrderItem'] as List? ?? [])
                  Text('原价 ¥${moneyText((item as Map)['originPrice'])}'),
                for (final p in detail['promotionList'] as List? ?? [])
                  Text(
                    '优惠类型 ${(p as Map)['promotionType'] ?? '未知'}：¥${moneyText(p['discountAmount'])}',
                  ),
                const SizedBox(height: 12),
                Text(
                  amount == null ? '金额资料不完整，暂不可汇总' : '估算实付 ¥$amount · 按订单明细计算',
                ),
              ],
              if (s.stage == Stage.resolvedByUser)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('已保留原有不确定原因；用户确认不等于服务端终态或费用结算'),
                ),
              if (s.context['reason'] != null)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('此会话曾有未确认结果，请以现场及官方客户端为准。'),
                ),
              const SizedBox(height: 16),
              Text('本地操作 ID ${s.id}', style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
        ),
      );
    },
  ),
);
