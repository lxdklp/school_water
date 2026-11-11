import '../support/memory_store.dart';
import '../support/signing_fixtures.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:water/core/models.dart';
import 'package:water/core/network.dart';
import 'package:water/core/money.dart';
import 'package:water/core/storage.dart';

import '../support/fake_transport.dart';

import 'package:water/features/drinking/drinking_api.dart';
import 'package:water/features/bathing/bathing_api.dart';

void main() {
  final clock = DateTime.fromMillisecondsSinceEpoch(1790000000000);
  group('missing signing configuration', () {
    test('empty keys reject calls before reaching the transport', () async {
      final transport = FakeTransport();
      final drinking = DrinkingApi(transport, signingSecret: '');
      final bathing = BathingApi(transport, signingKey: '  ');
      await expectLater(
        drinking.call('/user/balance', {}, token: 'fixture'),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        bathing.call('/user/basic/getUserInfo', {}),
        throwsA(isA<ApiFailure>()),
      );
      expect(transport.requests, isEmpty);
    });
  });
  group('wire signing and encoding', () {
    test('lxt prod ghost vectors, zero padding and range', () {
      expect(BathingApi.ghost(0x01A1A246F1CD), '4801A1A246F1CD78');
      expect(BathingApi.ghost(0x01A1A2470228), 'B501A1A24702286F');
      expect(BathingApi.ghost(0), '0000000000000000');
      expect(() => BathingApi.ghost(-1), throwsFormatException);
      expect(
        BathingApi.sign('schoolList=1', key: fixtureBathingKey),
        'ce22173aa34a8fafa70ecfdb4d2a0d84',
      );
    });
    test(
      'encrypted login exact outer bytes and sign, isolated auth headers',
      () {
        final api = BathingApi(
          FakeTransport(),
          signingKey: fixtureBathingKey,
          now: () => clock,
        );
        final r = api.build(
          '/user/login/userLoginV2',
          {
            'studentMobile': '13000000000',
            'loginPassword': '123456',
            'code': '0000',
            'topservice': true,
          },
          method: 'POST',
          auth: true,
        );
        expect(r.path, '/user/login/userLoginV2WithEncrypt');
        expect(
          r.body,
          '{"data":"eyJzdHVkZW50TW9iaWxlIjoiMTMwMDAwMDAwMDAiLCJsb2dpblBhc3N3b3JkIjoiMTIzNDU2IiwiY29kZSI6IjAwMDAiLCJ0b3BzZXJ2aWNlIjp0cnVlfQ=="}',
        );
        expect(r.headers['X-Sign'], 'dd897ea7b85c0059950ad96bac51b525');
        expect(r.signPayload, r.body);
        expect(r.headers.keys, isNot(contains('x-token')));
        expect(r.headers['X-B3-TraceId']!.length, 32);
        expect(r.headers['X-B3-SpanId']!.length, 32);
      },
    );
    test('GET signs raw ordered text, sends query encoded once', () {
      final api = BathingApi(
        FakeTransport(),
        signingKey: fixtureBathingKey,
        now: () => clock,
      );
      final r = api.build('/mgapp/machine/getInfoByQRCode', {
        'qrcode': 'https://例子.test/a?b=中文+&x=/?=',
        'b': 2,
        'a': 1,
      });
      expect(r.signPayload, 'qrcode=https://例子.test/a?b=中文+&x=/?=&b=2&a=1');
      expect(r.uri.queryParameters['qrcode'], 'https://例子.test/a?b=中文+&x=/?=');
      expect(
        r.headers['X-Sign'],
        BathingApi.sign(r.signPayload, key: fixtureBathingKey),
      );
      expect(r.query.indexOf('&b=2'), lessThan(r.query.indexOf('&a=1')));
    });
    test('drinking promotions in form, raw auth, fixed header contract', () {
      final api = DrinkingApi(
        FakeTransport(),
        signingSecret: fixtureDrinkingSecret,
        now: () => clock,
      );
      final r = api.build('/goods/water/unlock', {
        'skuId': 'sku+中文',
        'promotions': DrinkingApi.promotions(true),
      }, token: 'token==');
      final form = Uri.splitQueryString(r.body!);
      expect(form['skuId'], 'sku+中文');
      expect(form['token'], 'token==');
      final ps = jsonDecode(form['promotions']!) as List;
      expect(ps.map((e) => e['promotionType']), ['-6', '-7', '8']);
      expect(ps[0]['oldPromotionId'], '');
      expect(ps[2]['oldPromotionId'], '0');
      expect(r.headers['Authorization'], 'token==');
      expect(
        r.headers['sign'],
        'fcaa570a37ee5d028c7aa3d48db30dde71f718653b3e9a16d8b067b4de736b86',
      );
      expect(r.headers['Version'], '1.60.3');
      expect(
        r.signPayload.endsWith('&version=1.60.3/goods/water/unlock'),
        isTrue,
      );
      final login = api.build('/user/reg', {'phone': '1'}, token: 'old');
      expect(login.headers.containsKey('Authorization'), isFalse);
      expect(login.headers.containsKey('sign'), isFalse);
      expect(Uri.splitQueryString(login.body!).containsKey('token'), isFalse);
      expect((jsonDecode(DrinkingApi.promotions(false)) as List).length, 2);
    });
  });
  group('strict envelopes', () {
    for (final code in [0, 200]) {
      test('drinking accepts $code', () {
        expect(
          envelope(
            WireResponse({'code': code, 'data': null}),
            WaterPlatform.drinking,
          ),
          isNull,
        );
      });
    }
    for (final j in [
      {
        'code': 500,
        'data': {'token': 'x'},
      },
      {
        'data': {'id': 1},
      },
      {'code': '0', 'data': null},
    ]) {
      test('drinking rejects $j', () {
        expect(
          () => envelope(WireResponse(j), WaterPlatform.drinking),
          throwsA(isA<ApiFailure>()),
        );
      });
    }
    for (final code in [-44, -45, -301, -302, -67, 200]) {
      test('bath rejects $code despite Data', () {
        expect(
          () => envelope(
            WireResponse({
              'Code': code,
              'Data': {'id': 1},
            }),
            WaterPlatform.bathing,
          ),
          throwsA(isA<ApiFailure>()),
        );
      });
    }
    test('HTML, casing and HTTP errors stay errors', () {
      for (final r in [
        const WireResponse('<html>'),
        const WireResponse({'code': 0}),
        const WireResponse({'Code': 0}, status: 500),
      ]) {
        expect(
          () => envelope(r, WaterPlatform.bathing),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(scalarId(123), '123');
      expect(scalarId({'id': 1}), isNull);
    });
    test('error text never echoes server credential', () {
      try {
        envelope(
          const WireResponse({
            'Code': -45,
            'Message': 'secret-phone-token-cookie',
          }),
          WaterPlatform.bathing,
        );
        fail('error expected');
      } on ApiFailure catch (e) {
        expect(e.toString(), isNot(contains('secret')));
      }
    });
  });
  group('cookie and origin safety', () {
    test('multiple set cookie, equals, combined and Expires comma', () {
      final c = BathCredentials.parse([
        'tokenInfo=abc==; Expires=Wed, 21 Oct 2030 07:28:00 GMT; Path=/; HttpOnly, sid=xyz; Secure',
        'other=foo=bar; Path=/',
      ]);
      expect(c.tokenInfo, 'abc==');
      expect(c.cookiePairs, 'tokenInfo=abc==; sid=xyz; other=foo=bar');
      expect(c.cookiePairs, isNot(contains('Expires')));
      expect(
        () => BathCredentials.parse(['sid=x']),
        throwsA(isA<ApiFailure>()),
      );
    });
    test('business origin rejects injection, falls back only if missing', () {
      expect(businessOrigin(null), BathingApi.origin);
      expect(
        businessOrigin('https://school.lxt6.cn/'),
        'https://school.lxt6.cn',
      );
      for (final v in [
        '',
        'http://v3-app.lxt6.cn',
        'https://user:pass@v3-app.lxt6.cn',
        'https://v3-app.lxt6.cn.evil.test',
        'https://v3-app.lxt6.cn?x=1',
        'https://v3-app.lxt6.cn/a',
        'https://topservice.lxt6.cn',
        'https://v3-app.lxt6.cn:8443',
      ]) {
        expect(() => businessOrigin(v), throwsA(isA<ApiFailure>()));
      }
    });
    test('no communication value, no status request', () async {
      final t = FakeTransport(latency: Duration.zero);
      final api = BathingApi(t, signingKey: fixtureBathingKey);
      final s = Session(
        id: 'op',
        accountScope: 'a',
        origin: BathingApi.origin,
        platform: WaterPlatform.bathing,
        device: const Device(id: 'device', name: 'bath'),
        stage: Stage.uncertain,
        intentAt: clock,
      );
      expect(
        () => api.status(
          const Account(scope: 'a', token: 'x', origin: BathingApi.origin),
          s,
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(t.requests, isEmpty);
      expect(
        const UnknownBathStatusDecoder().decode({'status': 0, 'closed': true}),
        BathStatus.unknown,
      );
    });
    test(
      'frame vector preserves actual offsets and rejects unsupported bath',
      () {
        const qr =
            'A1B2C3D4E5F6A515ABCD21EE400F1010101234567890ABCDEF1122334400';
        final result = previewFrame(qr);
        expect(result['machineId'], '1234567890ABCDEF');
        expect(result['deviceVer'], '03,00');
        expect(
          () => BathingApi.openBody(
            Device(
              id: result['machineId']!,
              name: 'preview',
              version: result['deviceVer'],
              typeId: 3,
              channelWay: 4,
            ),
          ),
          throwsA(isA<ApiFailure>()),
        );
        for (final raw in ['abc', 'Z' * 64, '00' * 32]) {
          expect(() => previewFrame(raw), throwsFormatException);
        }
      },
    );
  });
  test('readOnly blocks every registered billing path before transport', () {
    for (final e in endpoints.where(
      (e) =>
          [Effect.billingCommand, Effect.billingPreparation].contains(e.effect),
    )) {
      final r = WireRequest(
        platform: e.platform,
        method: e.method,
        origin: e.platform == WaterPlatform.drinking
            ? DrinkingApi.origin
            : BathingApi.origin,
        path: e.path,
        headers: {},
      );
      expect(
        () => const RequestPolicy(AppMode.readOnly).check(r),
        throwsA(isA<ApiFailure>()),
      );
    }
    final read = DrinkingApi(
      FakeTransport(),
      signingSecret: fixtureDrinkingSecret,
    ).build('/user/balance', {}, token: 't');
    expect(
      const RequestPolicy(AppMode.readOnly).check(read).effect,
      Effect.read,
    );
    expect(
      () => const RequestPolicy(AppMode.manualLive).check(
        const WireRequest(
          platform: WaterPlatform.bathing,
          method: 'GET',
          origin: 'https://evil.test',
          path: '/bath/valve/getStatus',
          headers: {},
        ),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      () => const RequestPolicy(AppMode.manualLive).check(
        const WireRequest(
          platform: WaterPlatform.bathing,
          method: 'GET',
          origin: BathingApi.origin,
          path: '/bath/valve/open',
          headers: {},
        ),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(() => LiveTransport(AppMode.mock), throwsStateError);
  });
  test('exact decimal HALF_UP, sub-cent discount, unknown totals', () {
    expect((Money.parse('0.12') - Money.parse('0.11')).display, '0.01');
    expect(
      (Money.parse('0.12') - Money.parse('0.11') - Money.parse('0.001'))
          .display,
      '0.01',
    );
    expect(Money.parse('0.005').display, '0.01');
    expect(Money.parse('-0.005').display, '-0.01');
    expect(Money.parse('50').divide100().display, '0.50');
    expect(
      calculatedPayment({
        'tradeOrderItem': [
          {'originPrice': '0.12'},
        ],
        'promotionList': [
          {'promotionType': 8, 'discountAmount': '0.11'},
        ],
      }),
      '0.01',
    );
    for (final detail in [
      {
        'tradeOrderItem': [
          {'originPrice': '1'},
        ],
      },
      {
        'tradeOrderItem': [{}, {}],
        'promotionList': [],
      },
      {
        'tradeOrderItem': [
          {'originPrice': '1'},
        ],
        'promotionList': [
          {'promotionType': 8, 'discountAmount': '0.1'},
          {'promotionType': 8, 'discountAmount': '0.1'},
        ],
      },
    ]) {
      expect(calculatedPayment(detail), isNull);
    }
  });
  test('storage versions, corruption, namespace and failure', () async {
    final store = MemoryStore();
    final j = SessionJournal(store, AppMode.mock);
    final s = Session(
      id: 'op',
      accountScope: 'scope',
      origin: BathingApi.origin,
      platform: WaterPlatform.bathing,
      device: const Device(id: 'd', name: 'd'),
      stage: Stage.openAccepted,
      intentAt: clock,
      context: {'openCommunicationVal': 'A'},
    );
    await j.save(s);
    expect(
      (await j.load(WaterPlatform.bathing))!.context['openCommunicationVal'],
      'A',
    );
    expect(
      await SessionJournal(store, AppMode.readOnly).load(WaterPlatform.bathing),
      isNull,
    );
    store.failWrites = true;
    await expectLater(j.save(s), throwsA(isA<ApiFailure>()));
    store.failWrites = false;
    store.data[j.key(WaterPlatform.bathing, 'session')] = 'broken';
    await expectLater(
      j.load(WaterPlatform.bathing),
      throwsA(isA<ApiFailure>()),
    );
  });
}
