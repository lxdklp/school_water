import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/models.dart';
import 'water_controller.dart';
import 'app_shell.dart' show confirm, report, ErrorNotice;

Future<void> showAccount(BuildContext context, WaterController c) async {
  if (c.account != null) {
    final exit = await confirm(
      context,
      c.isBath ? 'lxt6 洗澡账号' : '胖乖生活账号',
      c.active ? '当前有未完成会话，请先处理会话，再退出或更换账号。' : '当前账号已登录。退出只影响此平台。',
      action: c.active ? '返回' : '退出账号',
    );
    if (exit && !c.active && context.mounted) await report(context, c.logout);
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => LoginSheet(controller: c),
  );
}

class LoginSheet extends StatefulWidget {
  final WaterController controller;
  const LoginSheet({super.key, required this.controller});
  @override
  State<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<LoginSheet> {
  final account = TextEditingController(),
      code = TextEditingController(),
      password = TextEditingController(),
      token = TextEditingController();
  String? error, captchaAccount, smsStatus;
  Uint8List? image;
  bool busy = false, obscure = true;
  int seconds = 0, captchaGeneration = 0;
  Timer? countdown;
  @override
  void dispose() {
    countdown?.cancel();
    for (final c in [account, code, password, token]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {bool pop = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      if (pop && mounted && widget.controller.account != null) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e is ApiFailure ? e.message : '操作未完成，请检查输入');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _captcha() async {
    final generation = ++captchaGeneration;
    final a = account.text.trim();
    setState(() {
      image = null;
      captchaAccount = null;
      code.clear();
    });
    await _run(() async {
      final bytes = await widget.controller.bathing.captcha(a);
      if (mounted &&
          generation == captchaGeneration &&
          account.text.trim() == a) {
        setState(() {
          image = bytes;
          captchaAccount = a;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 24,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: SingleChildScrollView(
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  c.isBath ? '登录 lxt6' : '登录胖乖生活',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                if (c.active) ...[
                  const Text('有未完成会话，只能使用原账号重新登录。Token 导入无法证明同一账号，不能继承会话。'),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: account,
                  enabled: !busy,
                  maxLength: c.isBath ? 128 : 32,
                  keyboardType: c.isBath
                      ? TextInputType.text
                      : TextInputType.phone,
                  autofillHints: const [AutofillHints.username],
                  decoration: InputDecoration(
                    labelText: c.isBath ? '账号' : '手机号',
                  ),
                  onChanged: (_) {
                    captchaGeneration++;
                    setState(() {
                      image = null;
                      captchaAccount = null;
                      code.clear();
                    });
                  },
                ),
                const SizedBox(height: 12),
                if (c.isBath) ...[
                  TextField(
                    controller: password,
                    enabled: !busy,
                    obscureText: obscure,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: '密码',
                      suffixIcon: IconButton(
                        tooltip: obscure ? '显示密码' : '隐藏密码',
                        onPressed: () => setState(() => obscure = !obscure),
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (image != null)
                    Semantics(
                      label: '图形验证码，点击刷新',
                      button: true,
                      child: InkWell(
                        onTap: busy ? null : _captcha,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Image.memory(
                            image!,
                            height: 64,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Text('图片无效，请刷新'),
                          ),
                        ),
                      ),
                    ),
                  OutlinedButton(
                    onPressed: busy ? null : _captcha,
                    child: const Text('刷新图形验证码'),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: code,
                  enabled: !busy,
                  maxLength: 32,
                  keyboardType: TextInputType.text,
                  decoration: InputDecoration(
                    labelText: c.isBath ? '图形验证码' : '短信验证码',
                  ),
                  autofillHints: c.isBath
                      ? null
                      : const [AutofillHints.oneTimeCode],
                ),
                if (!c.isBath)
                  OutlinedButton(
                    onPressed: busy || seconds > 0
                        ? null
                        : () => _run(() async {
                            await c.drinking.sendCode(account.text);
                            if (!mounted) return;
                            setState(() {
                              seconds = 60;
                              smsStatus = '短信发送请求已受理，请查看手机短信。';
                            });
                            countdown?.cancel();
                            countdown = Timer.periodic(
                              const Duration(seconds: 1),
                              (timer) {
                                if (!mounted) {
                                  timer.cancel();
                                  return;
                                }
                                setState(() => seconds--);
                                if (seconds <= 0) timer.cancel();
                              },
                            );
                          }),
                    child: Text(seconds > 0 ? '${seconds}s 后重新发送' : '发送短信验证码'),
                  ),
                if (smsStatus != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(liveRegion: true, child: Text(smsStatus!)),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: ErrorNotice(message: error!),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => _run(() async {
                          if (c.isBath &&
                              (image == null ||
                                  captchaAccount != account.text.trim())) {
                            throw const ApiFailure('请先获取此账号的图形验证码');
                          }
                          final p = password.text, v = code.text;
                          password.clear();
                          code.clear();
                          await c.authenticate(
                            () => c.isBath
                                ? c.bathing.login(account.text, p, v)
                                : c.drinking.login(account.text, v),
                          );
                        }, pop: true),
                  child: Text(busy ? '正在登录' : '登录'),
                ),
                if (!c.isBath)
                  ExpansionTile(
                    title: const Text('Token 登录'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      TextField(
                        controller: token,
                        obscureText: true,
                        maxLength: 4096,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '粘贴 Token',
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: busy || c.active
                            ? null
                            : () => _run(() async {
                                final t = token.text;
                                token.clear();
                                await c.authenticate(
                                  () => c.drinking.importToken(t),
                                );
                              }, pop: true),
                        child: const Text('验证并登录'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
