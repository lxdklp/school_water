// 协议移植自 LightLife, MIT, Copyright (c) 2024 Inonvation.
// 完整声明见 assets/licenses/lightlife.txt.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/models.dart';
import '../../core/network.dart';
import '../../core/signing_config.dart';

class DrinkingSku {
  final String id, name;
  const DrinkingSku({required this.id, required this.name});
}

String drinkingStepName(Object? step) => switch (step) {
  'skus' => '获取设备水温规格',
  'sync' => '读取设备状态',
  'details' => '读取设备信息',
  'checkUserIsRisk' => '积分检查',
  'addUserAfterPayChannel' => '后付开通',
  'isCheckLocation' => '位置风控检查',
  'unlock' => '发送开水指令',
  'creating' => '创建后付订单',
  'detail' => '读取订单详情',
  _ => '开水前检查',
};

class DrinkingApi {
  static const origin = 'https://userapi.qiekj.com';
  final String signingSecret;
  final Transport transport;
  final DateTime Function() now;
  DrinkingApi(
    this.transport, {
    DateTime Function()? now,
    this.signingSecret = SigningConfig.drinkingSecret,
  }) : now = now ?? DateTime.now;
  static String promotions(bool points) => jsonEncode([
    for (final type in ['-6', '-7', if (points) '8'])
      {
        'assetId': '0',
        'oldPromotionId': type == '8' ? '0' : '',
        'orgId': '0',
        'promotionId': '0',
        'promotionType': type,
      },
  ]);
  WireRequest build(String path, Map<String, String> fields, {String? token}) {
    final secret = SigningConfig.require(signingSecret);
    final login = path.startsWith('/common/') || path == '/user/reg';
    final timestamp = now().millisecondsSinceEpoch.toString();
    final body = {...fields, if (!login && token != null) 'token': token};
    final raw =
        'appSecret=$secret&channel=android_app&timestamp=$timestamp&token=$token&version=1.60.3$path';
    return WireRequest(
      platform: WaterPlatform.drinking,
      method: 'POST',
      origin: origin,
      path: path,
      body: body.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&'),
      signPayload: login ? '' : raw,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
        'Version': '1.60.3',
        'channel': 'android_app',
        'phoneBrand': 'Redmi',
        'User-Agent': 'okhttp/3.14.9',
        'timestamp': timestamp,
        if (!login && token != null) ...{
          'token': token,
          'Authorization': token,
          'sign': sha256.convert(utf8.encode(raw)).toString(),
        },
      },
    );
  }

  Future<Object?> call(
    String path,
    Map<String, String> fields, {
    String? token,
  }) async => envelope(
    await transport.send(build(path, fields, token: token)),
    WaterPlatform.drinking,
  );
  Future<void> sendCode(String phone) async {
    await call('/common/sms/sendCode', {
      'phone': input(phone, max: 32),
      'template': 'reg',
    });
  }

  Future<Account> login(String phone, String code) async {
    final p = input(phone, max: 32);
    final data = objectMap(
      await call('/user/reg', {
        'channel': 'android_app',
        'phone': p,
        'verify': input(code, max: 32),
      }),
    );
    return Account(
      scope: 'phone:${sha256.convert(utf8.encode(p))}',
      token: requiredId(data['token']),
      origin: origin,
    );
  }

  Future<Account> importToken(String token) async {
    final t = input(token);
    await call('/user/balance', {}, token: t);
    return Account(scope: 'import:${newId()}', token: t, origin: origin);
  }

  static List<DrinkingSku> parseSkus(Object? data) {
    if (data is! List) {
      throw const ApiFailure('设备规格响应格式不完整', kind: FailureKind.protocol);
    }
    final result = <String, DrinkingSku>{};
    for (final item in data) {
      final row = objectMap(item);
      final id = requiredId(row['skuId']);
      // `name` is the actual returned field (e.g. 热水 / 常温水). Price/unit
      // semantics are unverified and must not be inferred as a billing rate.
      final name = scalarId(row['name']) ?? '未命名水温规格';
      final old = result[id];
      if (old != null && old.name != name) {
        throw const ApiFailure(
          '设备规格信息冲突，请在官方客户端核对',
          kind: FailureKind.protocol,
        );
      }
      result[id] = DrinkingSku(id: id, name: name);
    }
    if (result.isEmpty) throw const ApiFailure('该设备没有可用的水温规格');
    return List.unmodifiable(result.values);
  }

  static DrinkingSku ambientSku(List<DrinkingSku> choices) {
    final matches = choices.where((sku) => sku.name == '常温水').toList();
    if (matches.isEmpty) throw const ApiFailure('该设备没有常温水规格，无法开始喝水');
    if (matches.length != 1) throw const ApiFailure('该设备存在多个常温水规格，请在官方客户端核对');
    return matches.single;
  }

  Future<List<DrinkingSku>> skus(Account a, Device d) async => parseSkus(
    await call('/goods/normal/skus', {'goodsId': d.id}, token: a.token),
  );

  Future<List<Device>> devices(Account a) async {
    final data = await call('/goods/latestUsed', {
      'categoryCode': '5',
    }, token: a.token);
    if (data is! List) {
      throw const ApiFailure('历史设备格式不完整', kind: FailureKind.protocol);
    }
    return data.map((e) {
      final j = objectMap(e);
      final name = scalarId(j['goodsName']) ?? '未命名设备';
      return Device(
        id: scalarId(j['goodsId']) ?? requiredId(j['id']),
        name: name,
      );
    }).toList();
  }
}
