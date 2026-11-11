import '../support/memory_store.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:water/core/models.dart';
import 'package:water/core/storage.dart';

void main() {
  const a = Account(
    scope: 'student:fixture',
    token: 'fixture-only',
    origin: 'https://v3-app.lxt6.cn',
    studentId: 'fixture',
    cookies: 'tokenInfo=fixture-only',
  );
  test('live upgrade preserves both real logins, never imports a session or mock account', () async {
    final store = MemoryStore();
    final source = SessionJournal(store, AppMode.readOnly),
        target = SessionJournal(store, AppMode.manualLive);
    await source.saveAccount(WaterPlatform.bathing, a);
    await source.saveAccount(
      WaterPlatform.drinking,
      const Account(
        scope: 'phone:fixture',
        token: 'fixture-only',
        origin: 'https://userapi.qiekj.com',
      ),
    );
    await source.verifiedWrite(
      source.key(WaterPlatform.bathing, 'points'),
      'false',
    );
    await SessionJournal(store, AppMode.mock).saveAccount(
      WaterPlatform.bathing,
      const Account(
        scope: 'mock',
        token: 'fake',
        origin: 'https://v3-app.lxt6.cn',
      ),
    );
    final s = Session(
      id: 'fixture-op',
      accountScope: a.scope,
      origin: a.origin,
      platform: WaterPlatform.bathing,
      device: const Device(id: 'fixture-device', name: 'fixture'),
      stage: Stage.openAccepted,
      intentAt: DateTime.utc(2026),
      context: {'openCommunicationVal': 'fixture-A'},
    );
    await source.save(s);
    for (final p in WaterPlatform.values) {
      await target.adoptReadOnlyAccount(p);
    }
    expect((await target.account(WaterPlatform.bathing))!.scope, a.scope);
    expect(
      (await target.account(WaterPlatform.drinking))!.scope,
      'phone:fixture',
    );
    expect(
      await store.read(target.key(WaterPlatform.bathing, 'points')),
      'false',
    );
    expect(await target.load(WaterPlatform.bathing), isNull);
    expect((await source.load(WaterPlatform.bathing))!.id, s.id);
    await target.clearAccount(WaterPlatform.bathing);
    await target.adoptReadOnlyAccount(WaterPlatform.bathing);
    expect(
      await target.account(WaterPlatform.bathing),
      isNull,
      reason: 'logout must not re-import stale credentials',
    );
  });
  test(
    'existing live identity and unfinished session never overwritten',
    () async {
      final store = MemoryStore(), targetMode = AppMode.manualLive;
      final source = SessionJournal(store, AppMode.readOnly),
          target = SessionJournal(store, targetMode);
      await source.saveAccount(WaterPlatform.bathing, a);
      final pending = Session(
        id: 'pending',
        accountScope: 'student:other',
        origin: a.origin,
        platform: WaterPlatform.bathing,
        device: const Device(id: 'fixture', name: 'fixture'),
        stage: Stage.sendingOpen,
        intentAt: DateTime.utc(2026),
      );
      await target.save(pending);
      await target.adoptReadOnlyAccount(WaterPlatform.bathing);
      expect(await target.account(WaterPlatform.bathing), isNull);
      expect((await target.load(WaterPlatform.bathing))!.id, 'pending');
      await target.saveAccount(
        WaterPlatform.bathing,
        const Account(
          scope: 'student:other',
          token: 'other',
          origin: 'https://v3-app.lxt6.cn',
          studentId: 'other',
        ),
      );
      await target.adoptReadOnlyAccount(WaterPlatform.bathing);
      expect(
        (await target.account(WaterPlatform.bathing))!.scope,
        'student:other',
      );
    },
  );
  test(
    'mock and readOnly cannot adopt; write failure never loses source',
    () async {
      final store = MemoryStore(),
          source = SessionJournal(MemoryStore(), AppMode.readOnly);
      final real = SessionJournal(store, AppMode.readOnly);
      await real.saveAccount(WaterPlatform.bathing, a);
      final mock = SessionJournal(store, AppMode.mock);
      await mock.adoptReadOnlyAccount(WaterPlatform.bathing);
      expect(await mock.account(WaterPlatform.bathing), isNull);
      expect(await source.account(WaterPlatform.bathing), isNull);
      store.failWrites = true;
      await expectLater(
        SessionJournal(
          store,
          AppMode.manualLive,
        ).adoptReadOnlyAccount(WaterPlatform.bathing),
        throwsA(isA<ApiFailure>()),
      );
      expect((await real.account(WaterPlatform.bathing))!.scope, a.scope);
    },
  );
}
