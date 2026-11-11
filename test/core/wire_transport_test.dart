import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:water/core/models.dart';
import 'package:water/core/network.dart';

import '../support/fake_transport.dart';
import '../support/signing_fixtures.dart';

import 'package:water/features/drinking/drinking_api.dart';
import 'package:water/features/bathing/bathing_api.dart';

class CaptureAdapter implements HttpClientAdapter {
  int calls = 0, status = 200;
  RequestOptions? last;
  List<int> bytes = [];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    last = options;
    bytes = requestStream == null
        ? []
        : await requestStream.expand((e) => e).toList();
    return ResponseBody.fromString(
      '{"Code":0,"data":null}',
      status,
      headers: {
        'content-type': ['application/json'],
        'set-cookie': ['tokenInfo=mock==; HttpOnly'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'final adapter body bytes match the signed JSON, GET URL and form',
    () async {
      final capture = CaptureAdapter(), dio = Dio();
      dio.httpClientAdapter = capture;
      final transport = LiveTransport(AppMode.manualLive, client: dio);
      final bath = BathingApi(FakeTransport(), signingKey: fixtureBathingKey);
      final r = bath.build(
        '/bath/valve/open',
        BathingApi.openBody(
          const Device(
            id: 'test-only',
            name: 'fixture',
            version: '01,82',
            typeId: 1,
            channelWay: 4,
          ),
        ),
        method: 'POST',
      );
      await transport.send(r);
      expect(utf8.decode(capture.bytes), r.body);
      expect(
        BathingApi.sign(utf8.decode(capture.bytes), key: fixtureBathingKey),
        capture.last!.headers['X-Sign'],
      );
      expect(capture.last!.followRedirects, isFalse);
      final query = bath.build('/mgapp/machine/getInfoByQRCode', {
        'qrcode': '中文+&/?=',
      });
      await transport.send(query);
      expect(capture.last!.uri.queryParameters['qrcode'], '中文+&/?=');
      expect(capture.bytes, isEmpty);
      final drink = DrinkingApi(
        FakeTransport(),
        signingSecret: fixtureDrinkingSecret,
      );
      final form = drink.build('/goods/water/unlock', {
        'skuId': 'sku',
        'promotions': DrinkingApi.promotions(true),
      }, token: 'test');
      await transport.send(form);
      expect(utf8.decode(capture.bytes), form.body);
    },
  );
  test(
    'readOnly policy before adapter, redirects and failures never replay',
    () async {
      final capture = CaptureAdapter(), dio = Dio();
      dio.httpClientAdapter = capture;
      final live = LiveTransport(AppMode.readOnly, client: dio);
      final blocked = BathingApi(
        FakeTransport(),
        signingKey: fixtureBathingKey,
      ).build('/bath/valve/close', {}, method: 'POST');
      await expectLater(live.send(blocked), throwsA(isA<ApiFailure>()));
      expect(capture.calls, 0);
      final read = DrinkingApi(
        FakeTransport(),
        signingSecret: fixtureDrinkingSecret,
      ).build('/user/balance', {}, token: 'fixture');
      for (final status in [302, 401, 429, 500]) {
        capture.status = status;
        final n = capture.calls;
        await expectLater(live.send(read), throwsA(isA<ApiFailure>()));
        expect(capture.calls, n + 1);
      }
    },
  );
  test('request summaries omit headers, query and body secrets', () async {
    final log = <String>[];
    final previous = debugPrint;
    debugPrint = (String? value, {int? wrapWidth}) {
      if (value != null) log.add(value);
    };
    try {
      final dio = Dio()..httpClientAdapter = CaptureAdapter();
      final transport = LiveTransport(AppMode.manualLive, client: dio);
      final r = BathingApi(FakeTransport(), signingKey: fixtureBathingKey)
          .build(
            '/mgapp/machine/getInfoByQRCode',
            {'qrcode': 'secret-qr-input'},
            account: const Account(
              scope: 'private-account',
              token: 'secret-auth-value',
              cookies: 'tokenInfo=secret-cookie',
              origin: BathingApi.origin,
            ),
          );
      await transport.send(r);
      final summary = log.join('\n');
      expect(summary, contains('/mgapp/machine/getInfoByQRCode'));
      expect(summary, contains('http=200'));
      expect(summary, contains('code=0'));
      for (final sensitive in [
        'secret-qr-input',
        'secret-auth-value',
        'secret-cookie',
        'private-account',
        'Cookie',
        'X-Sign',
      ]) {
        expect(summary, isNot(contains(sensitive)));
      }
    } finally {
      debugPrint = previous;
    }
  });
}
