import '../support/memory_store.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../support/test_dependencies.dart';

import 'package:water/core/models.dart';
import 'package:water/core/storage.dart';
import 'package:water/core/network.dart';

import '../support/fake_transport.dart';

import 'package:water/features/bathing/bathing_api.dart';
import 'package:water/features/drinking/drinking_api.dart';

Future<TestDependencies> ready({
  bool bath = false,
  DemoScenario scenario = DemoScenario.normal,
  MemoryStore? store,
  FakeTransport? fake,
}) async {
  final d = TestDependencies(
    store: store ?? MemoryStore(),
    fake: fake ?? FakeTransport(latency: Duration.zero),
  );
  await d.initialize();
  final c = bath ? d.bathing : d.drinking;
  await c.demoLogin();
  await c.selectDevice(
    bath
        ? const Device(
            id: 'mock-bath',
            name: '浴室',
            version: '01,82',
            typeId: 1,
            channelWay: 4,
          )
        : c.devices.first,
  );
  d.fake!.reset(scenario);
  return d;
}

int count(TestDependencies d, String path) =>
    d.fake!.requests.where((r) => r.path == path).length;
void main() {
  test(
    'drink full sequence, points snapshot, confirm and unique history',
    () async {
      final d = await ready();
      addTearDown(d.dispose);
      final c = d.drinking;
      await c.start();
      expect(c.session!.stage, Stage.awaitingWork);
      await c.setPoints(false);
      expect(c.usePoints, isTrue);
      await c.refreshSession();
      expect(c.session!.stage, Stage.working);
      await c.refreshSession();
      expect(c.session!.stage, Stage.completed);
      expect(c.canCreate, isFalse);
      expect(count(d, '/order/afterPay/creating'), 1);
      await c.createOrder();
      await c.createOrder();
      expect(c.session!.stage, Stage.completed);
      expect(c.history.length, 1);
      expect(count(d, '/goods/water/unlock'), 1);
      expect(count(d, '/order/afterPay/creating'), 1);
      expect(d.fake!.requests.any((e) => e.path.contains('close')), isFalse);
      await d.journal.archive(c.session!);
      final previous = c.session!;
      await d.journal.archive(
        Session(
          id: 'duplicate-local-id',
          accountScope: previous.accountScope,
          origin: previous.origin,
          platform: previous.platform,
          device: previous.device,
          stage: previous.stage,
          intentAt: previous.intentAt,
          context: {...previous.context, 'orderId': 'different-id-same-order'},
        ),
      );

      expect((await d.journal.history(WaterPlatform.drinking)).length, 1);
    },
  );
  test(
    'bath close archives immediately without querying status, one shot 20 taps',
    () async {
      final d = await ready(bath: true);
      addTearDown(d.dispose);
      final c = d.bathing;
      await Future.wait(List.generate(20, (_) => c.start()));
      expect(count(d, '/bath/valve/open'), 1);
      expect(c.canClose, isTrue);
      await Future.wait(List.generate(20, (_) => c.close()));
      expect(count(d, '/bath/valve/close'), 1);
      expect(c.session!.stage, Stage.closed);
      final close = d.fake!.requests.firstWhere(
        (e) => e.path == '/bath/valve/close',
      );
      expect(
        (jsonDecode(close.body!) as Map)['machineInfoJson']['communicationVal'],
        'demo-open-A',
      );
      await c.refreshSession();
      expect(c.session!.stage, Stage.closed);
      expect(count(d, '/bath/valve/getStatus'), 0);
      expect(c.active, isFalse);
      expect(c.canStart, isTrue);
      expect(c.history.length, 1);
    },
  );
  test(
    'successful close needs no Data, communication value, status or bill',
    () async {
      for (final payload in [null, '', <String, dynamic>{}]) {
        final d = await ready(bath: true, fake: EmptyCloseResponse(payload));
        await d.bathing.start();
        await d.bathing.refreshSession();
        expect(d.bathing.canQuery, isFalse);
        await d.bathing.close();
        await d.bathing.refreshSession();
        expect(d.bathing.session!.stage, Stage.closed);
        expect(d.bathing.history.length, 1);
        expect(d.bathing.canStart, isTrue);
        expect(count(d, '/bath/valve/getStatus'), 0);
        d.dispose();
      }
    },
  );
  test(
    'legacy accepted close records finish locally on restart without replay',
    () async {
      for (final state in ['accepted', 'missingContext', 'saveInterrupted']) {
        final store = MemoryStore();
        final original = await ready(bath: true, store: store);
        await original.bathing.start();
        await original.journal.save(
          original.bathing.session!.update(
            state == 'accepted' ? Stage.closeAccepted : Stage.uncertain,
            {
              'closeAttempted': true,
              if (state == 'missingContext')
                'reason': 'closeAcceptedMissingContext',
              if (state == 'saveInterrupted') 'closeAccepted': true,
            },
          ),
        );
        original.dispose();
        final restored = TestDependencies(
          store: store,
          fake: FakeTransport(latency: Duration.zero),
        );
        await restored.initialize();
        expect(restored.bathing.session!.stage, Stage.closed);
        expect(restored.bathing.history.length, 1);
        expect(restored.bathing.canStart, isTrue);
        expect(count(restored, '/bath/valve/getStatus'), 0);
        expect(count(restored, '/bath/valve/open'), 0);
        expect(count(restored, '/bath/valve/close'), 0);
        restored.dispose();
      }
    },
  );
  for (final scenario in [DemoScenario.lostOpen, DemoScenario.missingValue]) {
    test(
      'bath ${scenario.name} never opens again or queries without context',
      () async {
        final d = await ready(bath: true, scenario: scenario);
        addTearDown(d.dispose);
        final c = d.bathing;
        await c.start();
        await c.start();
        await c.close();
        await c.refreshSession();
        expect(c.session!.stage, Stage.uncertain);
        expect(c.canClose, isFalse);
        expect(count(d, '/bath/valve/open'), 1);
        expect(count(d, '/bath/valve/close'), 0);
        expect(count(d, '/bath/valve/getStatus'), 0);
      },
    );
  }
  test(
    'close lost response blocks retry and does not reuse A for query',
    () async {
      final d = await ready(bath: true);
      addTearDown(d.dispose);
      final c = d.bathing;
      await c.start();
      d.fake!.scenario = DemoScenario.lostClose;
      await c.close();
      await c.close();
      await c.refreshSession();
      expect(c.session!.stage, Stage.uncertain);
      expect(c.canClose, isFalse);
      expect(count(d, '/bath/valve/close'), 1);
      expect(count(d, '/bath/valve/getStatus'), 0);
    },
  );
  for (final scenario in [
    DemoScenario.lostOpen,
    DemoScenario.conflict,
    DemoScenario.noWork,
    DemoScenario.lostOrder,
  ]) {
    test('drink ${scenario.name} preserves uncertainty, no replay', () async {
      final d = await ready(scenario: scenario);
      addTearDown(d.dispose);
      final c = d.drinking;
      await c.start();
      await c.refreshSession();
      await c.refreshSession();
      if (scenario == DemoScenario.lostOrder) await c.createOrder();
      if (scenario == DemoScenario.noWork) c.stopPollingAtDeadline();
      await Future<void>.delayed(Duration.zero);
      await c.start();
      await c.createOrder();
      expect(c.session!.stage, Stage.uncertain);
      expect(count(d, '/goods/water/unlock'), 1);
      expect(
        count(d, '/order/afterPay/creating'),
        scenario == DemoScenario.lostOrder ? 1 : 0,
      );
    });
  }
  test('initial journal write failure blocks every command', () async {
    final store = MemoryStore();
    final d = await ready(bath: true, store: store);
    addTearDown(d.dispose);
    store.failWrites = true;
    await d.bathing.start();
    expect(count(d, '/bath/valve/open'), 0);
    expect(d.bathing.storageBlocked, isTrue);
    expect(d.bathing.canStart, isFalse);
  });
  test(
    'post-response storage failure retains A and manual end opportunity',
    () async {
      final store = MemoryStore();
      final fake = FailAfterOpen(store);
      final d = await ready(bath: true, store: store, fake: fake);
      addTearDown(d.dispose);
      await d.bathing.start();
      expect(d.bathing.canClose, isTrue);
      expect(d.bathing.storageBlocked, isTrue);
      await d.bathing.close();
      await d.bathing.close();
      expect(count(d, '/bath/valve/close'), 1);
    },
  );
  test('restart in every command stage never replays a write', () async {
    for (final stage in [
      Stage.preparing,
      Stage.sendingUnlock,
      Stage.creatingOrder,
      Stage.sendingOpen,
      Stage.sendingClose,
    ]) {
      final store = MemoryStore();
      final j = SessionJournal(store, AppMode.mock);
      await j.save(
        Session(
          id: 'op',
          accountScope: 'scope',
          origin: BathingApi.origin,
          platform: WaterPlatform.bathing,
          device: const Device(
            id: 'd',
            name: 'bath',
            version: '01,82',
            typeId: 1,
            channelWay: 4,
          ),
          stage: stage,
          intentAt: DateTime.now(),
          context: {'openAttempted': true},
        ),
      );
      final d = TestDependencies(
        store: store,
        fake: FakeTransport(latency: Duration.zero),
      );
      await d.initialize();
      expect(d.bathing.session!.stage, Stage.uncertain);
      expect(d.fake!.requests, isEmpty);
      d.dispose();
    }
  });
  test(
    'restore same open context, cross account rejected, no auto close',
    () async {
      final store = MemoryStore();
      final d = await ready(bath: true, store: store);
      await d.bathing.start();
      final before = count(d, '/bath/valve/close');
      d.dispose();
      final restored = TestDependencies(
        store: store,
        fake: FakeTransport(latency: Duration.zero),
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.bathing.canClose, isTrue);
      expect(count(restored, '/bath/valve/close'), before);
      await expectLater(
        restored.bathing.authenticate(
          () async => const Account(
            scope: 'student:other',
            token: 'x',
            origin: BathingApi.origin,
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(restored.bathing.account!.scope, 'student:demo-student');
      await expectLater(restored.bathing.logout(), throwsA(isA<ApiFailure>()));
    },
  );
  test('profile auth expiry retains bath session and same login keeps the end action', () async {
    final d = await ready(bath: true);
    addTearDown(d.dispose);
    final c = d.bathing;
    await c.start();
    d.fake!.scenario = DemoScenario.expired;
    await c.refreshProfile();
    expect(c.account, isNull);
    expect(c.active, isTrue);
    d.fake!.scenario = DemoScenario.normal;
    await c.demoLogin();
    await c.refreshProfile();
    expect(c.canClose, isTrue);
    expect(count(d, '/bath/valve/open'), 1);
    expect(count(d, '/bath/valve/close'), 0);
  });
  test('profile refresh cannot mutate the bath close snapshot and never reads status', () async {
    final d = await ready(
      bath: true,
      fake: FakeTransport(latency: const Duration(milliseconds: 5)),
    );
    addTearDown(d.dispose);
    final c = d.bathing;
    await c.start();
    await expectLater(
      c.selectDevice(const Device(id: 'other', name: 'other')),
      throwsA(isA<ApiFailure>()),
    );
    final reading = c.refreshProfile();
    await c.close();
    await reading;
    expect(c.session!.stage, Stage.closed);
    expect(c.session!.context['closeCommunicationVal'], 'demo-close-B');
    expect(count(d, '/bath/valve/getStatus'), 0);
    expect(c.canStart, isTrue);
  });
  test(
    'manual resolution saves evidence, clears session, never sends network',
    () async {
      final d = await ready(bath: true, scenario: DemoScenario.lostOpen);
      addTearDown(d.dispose);
      final c = d.bathing;
      await c.start();
      final n = d.fake!.requests.length;
      await c.resolveByUser();
      expect(d.fake!.requests.length, n);
      expect(c.history.single.stage, Stage.resolvedByUser);
      expect(c.history.single.context['reason'], 'startUnconfirmed');
      expect(c.canStart, isTrue);
      await c.clearHistory();
      expect(c.history, isEmpty);
    },
  );
  test('clearing completed records keeps active session', () async {
    final d = await ready(bath: true);
    addTearDown(d.dispose);
    await d.bathing.start();
    await d.bathing.clearHistory();
    expect(await d.journal.load(WaterPlatform.bathing), isNotNull);
  });
  test('corrupted journal blocks new start and preserves bytes', () async {
    final store = MemoryStore();
    final j = SessionJournal(store, AppMode.mock);
    final key = j.key(WaterPlatform.drinking, 'session');
    store.data[key] = 'corrupt';
    final d = TestDependencies(
      store: store,
      fake: FakeTransport(latency: Duration.zero),
    );
    addTearDown(d.dispose);
    await d.initialize();
    expect(d.drinking.storageBlocked, isTrue);
    expect(store.data[key], 'corrupt');
    expect(d.fake!.requests, isEmpty);
  });
  test('late order detail cannot undo user resolution', () async {
    final fake = DelayedRead('/order/detail');
    final d = await ready(fake: fake);
    addTearDown(d.dispose);
    final c = d.drinking;
    await c.start();
    c.session = c.session!.update(Stage.loadingOrder, {
      'orderId': 'fixture-id',
    });
    fake.hold = true;
    final pending = c.refreshSession();
    await fake.started.future;
    await c.resolveByUser();
    fake.release.complete();
    await pending;
    expect(c.session!.stage, Stage.resolvedByUser);
    expect(c.history.single.stage, Stage.resolvedByUser);
    expect(c.active, isFalse);
  });
  test('always uses ambient SKU even when hot water is first', () async {
    for (final reverse in [false, true]) {
      final fake = WaterSpecsTransport();
      if (reverse) fake.rows = (fake.rows as List).reversed.toList();
      final d = await ready(fake: fake);
      final c = d.drinking;
      await c.start();
      expect(c.session!.stage, Stage.awaitingWork);
      expect(c.session!.context['skuName'], '常温水');
      final body = fake.requests
          .singleWhere((r) => r.path == '/goods/water/unlock')
          .body!;
      expect(Uri.splitQueryString(body)['skuId'], 'cold');
      expect(
        fake.requests
            .where((r) => r.path == '/goods/water/sync')
            .every((r) => Uri.splitQueryString(r.body!)['skuId'] == 'cold'),
        isTrue,
      );
      await c.start();
      expect(count(d, '/goods/water/unlock'), 1);
      d.dispose();
    }
  });
  test('missing, ambiguous ambient SKU and failed precheck never enter billing preparation', () async {
    for (final condition in ['hotOnly', 'empty', 'ambiguous', 'precheck']) {
      final fake = WaterSpecsTransport();
      if (condition == 'hotOnly') {
        fake.rows = [
          {'skuId': 'hot', 'name': '热水'},
        ];
      }
      if (condition == 'empty') fake.rows = [];
      if (condition == 'ambiguous') {
        fake.rows = [
          {'skuId': 'cold1', 'name': '常温水'},
          {'skuId': 'cold2', 'name': '常温水'},
        ];
      }
      if (condition == 'precheck') fake.failPath = '/goods/water/sync';
      final d = await ready(fake: fake);
      final c = d.drinking;
      await c.start();
      expect(c.session!.stage, Stage.preflightFailed);
      expect(c.canStart, isTrue);
      expect(c.history, isEmpty);
      expect(count(d, '/goods/water/unlock'), 0);
      expect(c.session!.drinkingWriteMayHaveBeenSent, isFalse);
      d.dispose();
    }
  });
  test(
    'a lost billing preparation response stays uncertain and blocks replay',
    () async {
      final fake = WaterSpecsTransport()
        ..failPath = '/payChannelRoute/addUserAfterPayChannel';
      final d = await ready(fake: fake);
      addTearDown(d.dispose);
      await d.drinking.start();
      expect(d.drinking.session!.stage, Stage.uncertain);
      expect(d.drinking.canStart, isFalse);
      expect(d.drinking.session!.drinkingWriteMayHaveBeenSent, isTrue);
      expect(count(d, '/goods/water/unlock'), 0);
      await d.drinking.start();
      expect(fake.failedCalls, 1);
    },
  );
  test('legacy pre-unlock rejection recovers without network writes or fake order history', () async {
    for (final attempted in [false, true]) {
      final store = MemoryStore();
      final d = await ready(store: store);
      final c = d.drinking;
      final old = Session(
        id: 'legacy',
        accountScope: c.account!.scope,
        origin: c.account!.origin,
        platform: c.platform,
        device: c.device!,
        stage: Stage.uncertain,
        intentAt: DateTime.utc(2026),
        context: {
          'usePoints': true,
          'reason': 'startUnconfirmed',
          if (attempted)
            'attempted:/payChannelRoute/addUserAfterPayChannel': true,
        },
      );
      await d.journal.save(old);
      d.dispose();
      final restored = TestDependencies(
        store: store,
        fake: FakeTransport(latency: Duration.zero),
      );
      await restored.initialize();
      expect(
        restored.drinking.session!.stage,
        attempted ? Stage.uncertain : Stage.preflightFailed,
      );
      expect(restored.drinking.canStart, !attempted);
      expect(restored.drinking.history, isEmpty);
      expect(
        restored.fake!.requests.any(
          (r) =>
              const RequestPolicy(AppMode.mock).check(r).effect ==
              Effect.billingCommand,
        ),
        isFalse,
      );
      restored.dispose();
    }
  });
  test(
    'SKU decoder accepts numeric IDs and deduplicates, rejects ambiguous data',
    () {
      expect(
        DrinkingApi.parseSkus([
          {'skuId': 123, 'name': '热水'},
          {'skuId': '123', 'name': '热水'},
        ]).length,
        1,
      );
      for (final data in [
        [],
        {},
        [
          {'skuId': {}, 'name': '热水'},
        ],
        [
          {'skuId': 'same', 'name': '热水'},
          {'skuId': 'same', 'name': '常温水'},
        ],
      ]) {
        expect(() => DrinkingApi.parseSkus(data), throwsA(isA<ApiFailure>()));
      }
    },
  );
  test(
    'existing hot-water session retains its original SKU on read-only recovery',
    () async {
      final store = MemoryStore();
      final original = await ready(store: store);
      final c = original.drinking;
      await original.journal.save(
        Session(
          id: 'existing-hot-session',
          accountScope: c.account!.scope,
          origin: c.account!.origin,
          platform: c.platform,
          device: c.device!,
          stage: Stage.working,
          intentAt: DateTime.now().toUtc(),
          context: {
            'usePoints': true,
            'skuId': 'hot',
            'skuName': '热水',
            'unlockAttempted': true,
            'initialOrderNo': 'existing-order',
            'everWorked': true,
          },
        ),
      );
      original.dispose();
      final restored = TestDependencies(
        store: store,
        fake: FakeTransport(latency: Duration.zero),
      );
      await restored.initialize();
      expect(restored.drinking.session!.context['skuId'], 'hot');
      await restored.drinking.refreshSession();
      await restored.drinking.start();
      final sync = restored.fake!.requests.singleWhere(
        (r) => r.path == '/goods/water/sync',
      );
      expect(Uri.splitQueryString(sync.body!)['skuId'], 'hot');
      expect(
        restored.fake!.requests.any((r) => r.path == '/goods/water/unlock'),
        isFalse,
      );
      restored.dispose();
    },
  );
  test(
    'silent unchanged polling does not publish loading or metadata changes',
    () async {
      final d = await ready(fake: StatusSequenceFake([0, 2, 2, 0]));
      addTearDown(d.dispose);
      final c = d.drinking;
      await c.start();
      await c.refreshSession(silent: true);
      expect(c.session!.stage, Stage.working);
      var changes = 0;
      void listener() {
        changes++;
      }

      c.addListener(listener);
      await c.refreshSession(silent: true);
      expect(changes, 0);
      expect(c.readBusy, isFalse);
      expect(count(d, '/order/afterPay/creating'), 0);
      await c.refreshSession(silent: true);
      expect(c.session!.stage, Stage.completed);
      expect(count(d, '/order/afterPay/creating'), 1);
      await c.refreshSession(silent: true);
      await c.createOrder();
      expect(count(d, '/order/afterPay/creating'), 1);
      c.removeListener(listener);
    },
  );
  test('background status change waits for successful foreground read before automatic order', () async {
    final fake = StatusSequenceFake([0, 2, 0, 0]);
    final d = await ready(fake: fake);
    addTearDown(d.dispose);
    final c = d.drinking;
    await c.start();
    await c.refreshSession(silent: true);
    c.setForeground(false);
    await c.refreshSession(silent: true);
    expect(c.session!.stage, Stage.completionUnconfirmed);
    expect(count(d, '/order/afterPay/creating'), 0);
    c.setForeground(true);
    fake.failRead = true;
    await c.refreshSession(silent: true);
    expect(count(d, '/order/afterPay/creating'), 0);
    fake.failRead = false;
    await c.refreshSession(silent: true);
    expect(c.session!.stage, Stage.completed);
    expect(count(d, '/order/afterPay/creating'), 1);
  });
  test(
    'missing status does not turn a working session into an automatic order',
    () async {
      final d = await ready(fake: StatusSequenceFake([0, 2, null]));
      addTearDown(d.dispose);
      await d.drinking.start();
      await d.drinking.refreshSession(silent: true);
      await d.drinking.refreshSession(silent: true);
      expect(d.drinking.session!.stage, Stage.uncertain);
      expect(count(d, '/order/afterPay/creating'), 0);
    },
  );
  test(
    'restored automatic session never repeats an attempted creating request',
    () async {
      final store = MemoryStore();
      final d = await ready(store: store, scenario: DemoScenario.lostOrder);
      await d.drinking.start();
      await d.drinking.refreshSession(silent: true);
      await d.drinking.refreshSession(silent: true);
      expect(d.drinking.session!.context['creatingAttempted'], isTrue);
      d.dispose();
      final restored = TestDependencies(
        store: store,
        fake: FakeTransport(latency: Duration.zero),
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      await restored.drinking.refreshSession(silent: true);
      await restored.drinking.createOrder();
      expect(count(restored, '/order/afterPay/creating'), 0);
      expect(restored.drinking.active, isTrue);
    },
  );
  test('restored explicitly authorized order can finish after a read without reopening water', () async {
    final store = MemoryStore();
    final d = await ready(store: store);
    await d.drinking.start();
    await d.drinking.refreshSession(silent: true);
    expect(d.drinking.session!.stage, Stage.working);
    d.dispose();
    final restored = TestDependencies(
      store: store,
      fake: StatusSequenceFake([0]),
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(count(restored, '/order/afterPay/creating'), 0);
    await restored.drinking.refreshSession(silent: true);
    expect(restored.drinking.session!.stage, Stage.completed);
    expect(count(restored, '/order/afterPay/creating'), 1);
    expect(count(restored, '/goods/water/unlock'), 0);
  });
}

class FailAfterOpen extends FakeTransport {
  final MemoryStore store;
  FailAfterOpen(this.store) : super(latency: Duration.zero);
  @override
  Future<WireResponse> send(WireRequest r) async {
    final response = await super.send(r);
    if (r.path == '/bath/valve/open') store.failWrites = true;
    return response;
  }
}

class DelayedRead extends FakeTransport {
  final String path;
  bool hold = false;
  final started = Completer<void>(), release = Completer<void>();
  DelayedRead(this.path) : super(latency: Duration.zero);
  @override
  Future<WireResponse> send(WireRequest request) async {
    if (hold && request.path == path) {
      started.complete();
      await release.future;
    }
    return super.send(request);
  }
}

class WaterSpecsTransport extends FakeTransport {
  Object? rows = [
    {'skuId': 'hot', 'name': '热水'},
    {'skuId': 'cold', 'name': '常温水'},
  ];
  String? failPath;
  int failedCalls = 0;
  WaterSpecsTransport() : super(latency: Duration.zero);
  @override
  Future<WireResponse> send(WireRequest r) async {
    if (r.path == failPath) {
      failedCalls++;
      throw const ApiFailure('fixture network loss', kind: FailureKind.network);
    }
    if (r.path == '/goods/normal/skus') {
      requests.add(r);
      return WireResponse({'code': 200, 'data': rows});
    }
    return super.send(r);
  }
}

class StatusSequenceFake extends FakeTransport {
  final List<int?> statuses;
  int index = 0;
  bool failRead = false;
  StatusSequenceFake(this.statuses) : super(latency: Duration.zero);
  @override
  Future<WireResponse> send(WireRequest r) async {
    if (r.path == '/goods/water/sync') {
      if (failRead) {
        throw const ApiFailure('fixture read loss', kind: FailureKind.network);
      }
      requests.add(r);
      final status =
          statuses[index < statuses.length ? index++ : statuses.length - 1];
      return WireResponse({
        'code': 200,
        'data': {'workStatus': ?status},
      });
    }
    return super.send(r);
  }
}

class EmptyCloseResponse extends FakeTransport {
  final Object? payload;
  EmptyCloseResponse(this.payload) : super(latency: Duration.zero);
  @override
  Future<WireResponse> send(WireRequest r) async {
    if (r.path == '/bath/valve/close') {
      requests.add(r);
      return WireResponse({'Code': 0, 'Data': payload});
    }
    return super.send(r);
  }
}
