import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/storage.dart';
import '../features/drinking/drinking_api.dart';
import '../features/bathing/bathing_api.dart';

class WaterController extends ChangeNotifier {
  final WaterPlatform platform;
  final SessionJournal journal;
  final DrinkingApi drinking;
  final BathingApi bathing;
  final AppMode mode;
  Account? account;
  Device? device;
  Session? session;
  List<Device> devices = [];
  List<Session> history = [];
  Map<String, dynamic> balance = {};
  String? error;
  bool initialized = false,
      busy = false,
      readBusy = false,
      storageBlocked = false,
      usePoints = true;
  int _generation = 0;
  bool _foreground = true;
  void setForeground(bool value) {
    _foreground = value;
  }

  bool get autoCreateAllowed =>
      !isBath &&
      active &&
      session!.context['autoCreateOrder'] == true &&
      session!.context['creatingAttempted'] != true;

  WaterController({
    required this.platform,
    required this.journal,
    required this.drinking,
    required this.bathing,
    required this.mode,
  });
  bool get isBath => platform == WaterPlatform.bathing;
  bool get active => session != null && !session!.finished;
  bool get sameAccount =>
      session == null ||
      (account?.scope == session!.accountScope &&
          account?.origin == session!.origin);
  bool get canStart =>
      initialized &&
      !storageBlocked &&
      account != null &&
      sameAccount &&
      device != null &&
      !active &&
      !busy &&
      !readBusy &&
      (!isBath || device!.bathSupported) &&
      mode != AppMode.readOnly;
  bool get canClose =>
      isBath &&
      active &&
      sameAccount &&
      account != null &&
      !busy &&
      session!.context['openCommunicationVal'] != null &&
      session!.context['closeAttempted'] != true &&
      mode != AppMode.readOnly;
  bool get canCreate =>
      !isBath &&
      session?.stage == Stage.completionUnconfirmed &&
      session!.context['everWorked'] == true &&
      session!.context['conflict'] != true &&
      session!.context['initialOrderNo'] != null &&
      session!.context['creatingAttempted'] != true &&
      !busy &&
      !storageBlocked &&
      sameAccount &&
      account != null &&
      mode != AppMode.readOnly;
  bool get canQuery =>
      !isBath &&
      active &&
      sameAccount &&
      account != null &&
      !readBusy &&
      !busy &&
      (session!.context['skuId'] != null ||
          session!.context['orderId'] != null);

  Future<void> initialize() async {
    try {
      await journal.adoptReadOnlyAccount(platform);
      session = await journal.load(platform);
      account = await journal.account(platform);
      history = await journal.history(platform);
      final raw = await journal.store.read(journal.key(platform, 'selection'));
      if (raw != null) {
        final j = objectMap(jsonDecode(raw));
        if (j['scope'] == account?.scope) {
          device = Device.fromJson(objectMap(j['device']));
        }
      }
      final points = await journal.store.read(journal.key(platform, 'points'));
      usePoints = points != 'false';
      if (session != null) {
        device = session!.device;
        // Older versions waited for an unsupported status query after a
        // successful close. Complete those records locally without any replay.
        if (isBath &&
            !session!.finished &&
            (session!.stage == Stage.closeAccepted ||
                session!.context['closeAccepted'] == true ||
                session!.context['reason'] == 'closeAcceptedMissingContext')) {
          session = session!.update(Stage.closed, {
            'completionSource': 'closeAccepted',
            'completedAt':
                session!.context['closeResponseReceivedAt'] ??
                DateTime.now().toUtc().toIso8601String(),
          });
          await journal.save(session!);
        }
        if (!isBath &&
            !session!.drinkingWriteMayHaveBeenSent &&
            session!.context['usePoints'] is bool &&
            (session!.stage == Stage.preparing ||
                (session!.stage == Stage.uncertain &&
                    session!.context['reason'] == 'startUnconfirmed'))) {
          session = session!.update(Stage.preflightFailed, {
            'previousReason': session!.context['reason'],
            'reason': 'preflightRejected',
            'failedStep':
                session!.context['step'] ??
                (session!.context['skuId'] == null ? 'skus' : 'preflight'),
          });
          await journal.save(session!);
        }

        if (!session!.finished &&
            [
              Stage.preparing,
              Stage.sendingUnlock,
              Stage.creatingOrder,
              Stage.sendingOpen,
              Stage.sendingClose,
            ].contains(session!.stage)) {
          session = session!.update(Stage.uncertain, {
            'reason': 'interrupted',
            'recovered': true,
          });
          await journal.save(session!);
        }
        if (session!.finished && session!.stage != Stage.preflightFailed) {
          await journal.archive(session!);
          history = await journal.history(platform);
        }
      }
    } catch (_) {
      storageBlocked = true;
      error = '本地数据读取失败，已阻止新开始。请保留数据并核对官方客户端';
    }
    initialized = true;
    notifyListeners();
    if (account != null && !storageBlocked) await refreshProfile();
  }

  Future<void> setPoints(bool value) async {
    if (active || busy) return;
    usePoints = value;
    notifyListeners();
    try {
      await journal.verifiedWrite(journal.key(platform, 'points'), '$value');
    } catch (e) {
      _error(e);
    }
  }

  Future<void> authenticate(Future<Account> Function() login) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final a = await login();
      if (active &&
          (a.scope != session!.accountScope || a.origin != session!.origin)) {
        throw const ApiFailure('有未完成会话，请使用原账号重新登录');
      }
      await journal.saveAccount(platform, a);
      if (account?.scope != a.scope) {
        device = active ? session!.device : null;
        devices = [];
        balance = {};
      }
      account = a;
      _generation++;
    } catch (e) {
      _error(e);
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
    await refreshProfile();
  }

  Future<void> logout() async {
    if (active || busy) throw const ApiFailure('请先处理未完成会话，再退出或更换账号');
    await journal.clearAccount(platform);
    await journal.store.delete(journal.key(platform, 'selection'));
    account = null;
    device = null;
    devices = [];
    balance = {};
    _generation++;
    notifyListeners();
  }

  Future<void> selectDevice(Device value) async {
    if (active || busy || account == null) throw const ApiFailure('请先处理当前会话');
    await journal.verifiedWrite(
      journal.key(platform, 'selection'),
      jsonEncode({'scope': account!.scope, 'device': value.toJson()}),
    );
    device = value;
    session = null;
    error = null;
    _generation++;
    notifyListeners();
  }

  Future<void> refreshProfile() async {
    if (account == null || readBusy) return;
    final a = account!, gen = _generation;
    readBusy = true;
    notifyListeners();
    try {
      if (isBath) {
        await bathing.call('/user/basic/getUserInfo', {}, account: a);
        if (gen != _generation) return;
        final raw = await journal.store.read(
          journal.key(platform, 'recent.${a.scope}'),
        );
        if (raw != null) {
          devices = (jsonDecode(raw) as List)
              .map((e) => Device.fromJson(objectMap(e)))
              .toList();
        }
      } else {
        final b = objectMap(
          await drinking.call('/user/balance', {}, token: a.token),
        );
        final ds = await drinking.devices(a);
        if (gen != _generation) return;
        balance = b;
        devices = ds;
      }
      error = null;
    } catch (e) {
      if (gen == _generation) await _handle(e);
    } finally {
      readBusy = false;
      notifyListeners();
    }
  }

  Future<Device> resolveDevice(String qr, String note) async {
    if (active || busy || account == null) {
      throw const ApiFailure('请先登录并处理未完成会话');
    }
    final a = account!, gen = _generation;
    final d = await bathing.resolve(a, qr, note);
    if (gen != _generation || active) throw const ApiFailure('账号或会话已变化，请重新解析');
    return d;
  }

  Future<void> rememberDevice(Device d) async {
    await selectDevice(d);
    devices = [d, ...devices.where((e) => e.id != d.id)].take(12).toList();
    await journal.verifiedWrite(
      journal.key(platform, 'recent.${account!.scope}'),
      jsonEncode(devices.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  void _error(Object e) {
    error = e is ApiFailure ? e.message : '操作未能确认，请检查官方客户端';
    notifyListeners();
  }

  Future<void> _handle(Object e) async {
    if (e is ApiFailure && e.kind == FailureKind.storage) storageBlocked = true;
    if (e is ApiFailure && e.kind == FailureKind.auth) {
      account = null;
      _generation++;
      try {
        await journal.clearAccount(platform);
      } catch (_) {
        /* Keep session, never replay. */
      }
    }
    _error(e);
  }

  Future<void> _save(
    Stage next, [
    Map<String, dynamic> fields = const {},
    bool silent = false,
  ]) async {
    final changed = session!.stage != next;
    session = session!.update(next, fields);
    if (!silent || changed) notifyListeners();
    try {
      await journal.save(session!);
    } catch (_) {
      storageBlocked = true;
      rethrow;
    }
  }

  Future<void> _uncertain(Object e, String reason) async {
    if (session != null && !session!.finished) {
      session = session!.update(Stage.uncertain, {
        'reason': reason,
        'failedStep': session!.context['step'],
        'failedStage': session!.stage.name,
        'failureKind': e is ApiFailure ? e.kind.name : 'unknown',
        'failureCode': e is ApiFailure ? e.code : null,
      });
      try {
        await journal.save(session!);
      } catch (_) {
        storageBlocked = true;
      }
    }
    await _handle(e);
  }

  Future<void> _finish(
    Stage stage, [
    Map<String, dynamic> fields = const {},
  ]) async {
    await _save(stage, {
      ...fields,
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    });
    await journal.archive(session!);
    history = await journal.history(platform);
    notifyListeners();
  }

  Future<void> start() async {
    if (!canStart) return;
    busy = true;
    error = null;
    final a = account!, d = device!;
    session = Session(
      id: newId(),
      accountScope: a.scope,
      origin: a.origin,
      platform: platform,
      device: d,
      stage: isBath ? Stage.sendingOpen : Stage.preparing,
      intentAt: DateTime.now().toUtc(),
      context: {
        'usePoints': usePoints,
        if (isBath) 'studentId': a.studentId,
        if (!isBath) ...{'step': 'skus', 'autoCreateOrder': true},
      },
    );
    notifyListeners();
    try {
      // Initial intent must be durable before ANY new operation.
      await journal.save(session!);
      if (isBath) {
        await _save(Stage.sendingOpen, {
          'openAttempted': true,
          'requestStartedAt': DateTime.now().toUtc().toIso8601String(),
        });
        final data = objectMap(
          await bathing.call(
            '/bath/valve/open',
            BathingApi.openBody(d),
            method: 'POST',
            account: a,
          ),
        );
        await _save(Stage.openAccepted, {
          'responseReceivedAt': DateTime.now().toUtc().toIso8601String(),
          'openCommunicationVal': scalarId(data['communicationVal']),
          'offline': data['offline'],
        });
        if (scalarId(data['communicationVal']) == null ||
            data['offline'] != 0) {
          await _save(Stage.uncertain, {
            'reason': scalarId(data['communicationVal']) == null
                ? 'openAcceptedMissingContext'
                : 'openAcceptedStatusUnknown',
          });
        }
      } else {
        final choices = await drinking.skus(a, d);
        final selected = DrinkingApi.ambientSku(choices);
        final sku = selected.id;
        await _save(Stage.preparing, {
          'skuId': sku,
          'skuName': selected.name,
          'step': 'sync',
        });
        final pre = objectMap(
          await drinking.call('/goods/water/sync', {
            'skuId': sku,
          }, token: a.token),
        );
        if (pre['workStatus'] == null || pre['workStatus'].toString() == '2') {
          throw const ApiFailure('无法确认设备可用，或设备正在使用');
        }
        await _save(Stage.preparing, {'step': 'details'});
        final details = objectMap(
          await drinking.call('/goods/normal/details', {
            'goodsId': d.id,
          }, token: a.token),
        );
        final imei = requiredId(details['imei']);
        await _save(Stage.preparing, {'imei': imei});
        for (final step in [
          '/userIntegral/checkUserIsRisk',
          '/payChannelRoute/addUserAfterPayChannel',
          '/orderRisk/isCheckLocation',
        ]) {
          await _save(Stage.preparing, {
            'attempted:$step': true,
            'step': step.split('/').last,
          });
          await drinking.call(step, {
            if (step.contains('addUser')) 'method': '15',
            if (step.contains('isCheck')) ...{
              'categoryCode': '04',
              'imei': imei,
            },
          }, token: a.token);
        }
        await _save(Stage.sendingUnlock, {
          'step': 'unlock',
          'unlockAttempted': true,
          'requestStartedAt': DateTime.now().toUtc().toIso8601String(),
        });
        final data = objectMap(
          await drinking.call('/goods/water/unlock', {
            'skuId': sku,
            'promotions': DrinkingApi.promotions(
              session!.context['usePoints'] == true,
            ),
          }, token: a.token),
        );
        await _save(Stage.awaitingWork, {
          'initialOrderNo': requiredId(data['orderNo']),
          'responseReceivedAt': DateTime.now().toUtc().toIso8601String(),
        });
      }
    } catch (e) {
      if (e is ApiFailure && e.kind == FailureKind.storage) {
        storageBlocked = true;
      }
      if (!isBath && !session!.drinkingWriteMayHaveBeenSent) {
        try {
          await _save(Stage.preflightFailed, {
            'reason': 'preflightRejected',
            'failedStep': session!.context['step'],
            'failureKind': e is ApiFailure ? e.kind.name : 'unknown',
            'failureCode': e is ApiFailure ? e.code : null,
          });
        } catch (_) {
          storageBlocked = true;
        }
        await _handle(e);
      } else {
        await _uncertain(e, 'startUnconfirmed');
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> close() async {
    if (!canClose) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      // Existing valid open context keeps an end action even if storage fails.
      try {
        await _save(Stage.sendingClose, {
          'closeAttempted': true,
          'closeRequestStartedAt': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (_) {
        error = '安全存储不可用，本次结束结果需在现场核对';
      }
      final data = await bathing.call(
        '/bath/valve/close',
        BathingApi.closeBody(session!),
        method: 'POST',
        account: account!,
      );
      // A successful envelope is the complete close contract. Data may be
      // absent and no server status or bill is required to finish the app flow.
      await _save(Stage.closeAccepted, {
        'closeAccepted': true,
        if (data is Map && scalarId(data['communicationVal']) != null)
          'closeCommunicationVal': scalarId(data['communicationVal']),
        'closeResponseReceivedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await _finish(Stage.closed, {'completionSource': 'closeAccepted'});
    } catch (e) {
      await _uncertain(e, 'closeUnconfirmed');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> refreshSession({bool silent = false}) async {
    if (!canQuery) return;
    readBusy = true;
    final old = session!, a = account!, gen = _generation;
    if (!silent) notifyListeners();
    var readSucceeded = false;
    try {
      if (old.context['orderId'] != null) {
        await _loadOrder(a);
      } else {
        final data = objectMap(
          await drinking.call('/goods/water/sync', {
            'skuId': requiredId(old.context['skuId']),
          }, token: a.token),
        );
        if (session?.id != old.id ||
            session?.finished == true ||
            gen != _generation ||
            session?.context['creatingAttempted'] !=
                old.context['creatingAttempted'] ||
            busy) {
          return;
        }
        final identify = scalarId(data['identify']);
        final status = int.tryParse(scalarId(data['workStatus']) ?? '');
        if (status == null) {
          await _save(Stage.uncertain, {'reason': 'missingWorkStatus'}, silent);
          return;
        }
        if (identify != null &&
            old.context['initialOrderNo'] != null &&
            identify != old.context['initialOrderNo']) {
          await _save(Stage.uncertain, {
            'conflict': true,
            'observedIdentify': identify,
            'reason': 'orderConflict',
          }, silent);
        } else if (status == 2 &&
            old.context['initialOrderNo'] != null &&
            old.context['creatingAttempted'] != true) {
          await _save(Stage.working, {
            'everWorked': true,
            'lastReadAt': DateTime.now().toUtc().toIso8601String(),
            'lastConfirmedState': '2',
          }, silent);
        } else if (old.context['everWorked'] == true &&
            old.context['conflict'] != true &&
            old.context['creatingAttempted'] != true) {
          await _save(Stage.completionUnconfirmed, {
            'observedIdentify': identify,
            'lastReadAt': DateTime.now().toUtc().toIso8601String(),
          }, silent);
        } else {
          await _save(
            old.stage == Stage.awaitingWork
                ? Stage.awaitingWork
                : Stage.uncertain,
            {'reason': 'workNotObserved'},
            silent,
          );
        }
      }
      readSucceeded = true;
      final hadError = error != null;
      error = null;
      if (silent && hadError) notifyListeners();
    } catch (e) {
      if (gen == _generation &&
          session?.id == old.id &&
          session?.finished != true) {
        await _handle(e);
      }
    } finally {
      readBusy = false;
      if (!silent || session?.finished == true) notifyListeners();
    }
    if (readSucceeded && _foreground && autoCreateAllowed && canCreate) {
      await createOrder(automatic: true);
    }
  }

  Future<void> createOrder({bool automatic = false}) async {
    if (!canCreate || (automatic && (!_foreground || !autoCreateAllowed))) {
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _save(Stage.creatingOrder, {
        'step': 'creating',
        'creatingAttempted': true,
        'completionTrigger': automatic ? 'observedStatusChange' : 'userResume',
      });
      final data = objectMap(
        await drinking.call('/order/afterPay/creating', {
          'orderNo': requiredId(session!.context['initialOrderNo']),
        }, token: account!.token),
      );
      await _save(Stage.loadingOrder, {
        'orderId': requiredId(data['orderId']),
        'step': 'detail',
      });
      await _loadOrder(account!);
    } catch (e) {
      await _uncertain(e, 'orderUnconfirmed');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _loadOrder(Account a) async {
    final expected = session!, gen = _generation;
    final detail = objectMap(
      await drinking.call('/order/detail', {
        'orderId': requiredId(session!.context['orderId']),
      }, token: a.token),
    );
    if (session?.id != expected.id ||
        gen != _generation ||
        session?.finished == true) {
      return;
    }
    if (detail['tradeOrderItem'] is! List) {
      throw const ApiFailure('订单明细不完整', kind: FailureKind.protocol);
    }
    await _finish(Stage.completed, {'detail': detail});
  }

  Future<void> resolveByUser() async {
    if (!active || busy) return;
    _generation++; // Invalidate in-flight reads before the local resolution.
    busy = true;
    notifyListeners();
    try {
      await _finish(Stage.resolvedByUser, {
        'resolution': isBath ? '用户结束本次本地记录' : '用户在现场或官方客户端确认结束',
      });
    } catch (e) {
      _error(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void stopPollingAtDeadline() {
    if (!active || isBath) return;
    unawaited(
      _uncertain(const ApiFailure('轮询已截止，请手动刷新并核对官方客户端'), 'pollingDeadline'),
    );
  }

  Future<void> clearHistory() async {
    await journal.clearHistory(platform);
    history = [];
    notifyListeners();
  }
}
