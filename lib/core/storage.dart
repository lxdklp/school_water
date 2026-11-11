import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';
import 'network.dart';

abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureStore implements KeyValueStore {
  final FlutterSecureStorage storage;
  const SecureStore([this.storage = const FlutterSecureStorage()]);
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

class SessionJournal {
  final KeyValueStore store;
  final String namespace;
  final AppMode mode;
  SessionJournal(this.store, this.mode) : namespace = 'water.v1.${mode.name}';
  String key(WaterPlatform p, String part) => '$namespace.${p.name}.$part';
  Future<void> verifiedWrite(String key, String value) async {
    try {
      await store.write(key, value);
      if (await store.read(key) != value) throw StateError('readback');
    } catch (_) {
      throw const ApiFailure('安全存储写入失败，恢复能力受影响', kind: FailureKind.storage);
    }
  }

  /// One-time upgrade for the user's authenticated readOnly trial. Never
  /// imports mock data, overwrites an account, or transfers an active session.
  Future<void> adoptReadOnlyAccount(WaterPlatform platform) async {
    if (mode != AppMode.manualLive) return;
    final marker = key(platform, 'readOnlyAccountImported');
    if (await store.read(marker) != null) return;
    if (await account(platform) == null) {
      final source = SessionJournal(store, AppMode.readOnly);
      final previous = await source.account(platform);
      final pending = await load(platform);
      if (previous != null &&
          (pending == null ||
              (pending.accountScope == previous.scope &&
                  pending.origin == previous.origin))) {
        final validOrigin = platform == WaterPlatform.drinking
            ? previous.origin == 'https://userapi.qiekj.com'
            : businessOrigin(previous.origin) == previous.origin &&
                  previous.studentId != null &&
                  previous.scope == 'student:${previous.studentId}';
        if (!validOrigin) {
          throw const ApiFailure('已有账号资料不完整，请重新登录', kind: FailureKind.storage);
        }
        for (final part in [
          'selection',
          'points',
          'recent.${previous.scope}',
        ]) {
          final target = key(platform, part);
          if (await store.read(target) != null) continue;
          final raw = await store.read(source.key(platform, part));
          if (raw != null) await verifiedWrite(target, raw);
        }
        // Account last: all imported data must be durable before using it.
        await saveAccount(platform, previous);
      }
    }
    // Logout must never silently import an older credential on the next boot.
    await verifiedWrite(marker, '1');
  }

  Future<void> save(Session s) =>
      verifiedWrite(key(s.platform, 'session'), s.encode());
  Future<Session?> load(WaterPlatform p) async {
    final raw = await store.read(key(p, 'session'));
    if (raw == null) return null;
    try {
      final s = Session.fromJson(objectMap(jsonDecode(raw)));
      if (s.platform != p) throw StateError('platform');
      return s;
    } catch (_) {
      throw const ApiFailure(
        '未完成会话数据损坏，已阻止新的开始。请保留数据并检查官方客户端',
        kind: FailureKind.storage,
      );
    }
  }

  Future<Account?> account(WaterPlatform p) async {
    final raw = await store.read(key(p, 'account'));
    return raw == null ? null : Account.fromJson(objectMap(jsonDecode(raw)));
  }

  Future<void> saveAccount(WaterPlatform p, Account a) =>
      verifiedWrite(key(p, 'account'), jsonEncode(a.toJson()));
  Future<void> clearAccount(WaterPlatform p) => store.delete(key(p, 'account'));
  Future<List<Session>> history(WaterPlatform p) async {
    final raw = await store.read(key(p, 'history'));
    if (raw == null) return [];
    try {
      final j = objectMap(jsonDecode(raw));
      if (j['schemaVersion'] != 1) throw StateError('version');
      return (j['items'] as List)
          .map((e) => Session.fromJson(objectMap(e)))
          .toList();
    } catch (_) {
      throw const ApiFailure('本地记录损坏，已保留原数据', kind: FailureKind.storage);
    }
  }

  Future<void> archive(Session s) async {
    if (!s.finished || s.stage == Stage.preflightFailed) {
      throw StateError('Cannot archive a session without completed usage');
    }
    final list = await history(s.platform);
    list.removeWhere(
      (e) =>
          e.id == s.id ||
          (s.context['initialOrderNo'] != null &&
              e.context['initialOrderNo'] == s.context['initialOrderNo']) ||
          (s.context['orderId'] != null &&
              e.context['orderId'] == s.context['orderId']),
    );
    list.insert(0, s);
    list.sort((a, b) => b.intentAt.compareTo(a.intentAt));
    await verifiedWrite(
      key(s.platform, 'history'),
      jsonEncode({
        'schemaVersion': 1,
        'items': list.take(200).map((e) => e.toJson()).toList(),
      }),
    );
    await store.delete(key(s.platform, 'session'));
  }

  Future<void> clearHistory(WaterPlatform p) => store.delete(key(p, 'history'));
}
