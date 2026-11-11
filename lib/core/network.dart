import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';

enum Effect { read, auth, billingPreparation, billingCommand }

class Endpoint {
  final WaterPlatform platform;
  final String method, path;
  final Effect effect;
  final bool authGateway;
  const Endpoint(
    this.platform,
    this.method,
    this.path,
    this.effect, {
    this.authGateway = false,
  });
}

final endpoints = List<Endpoint>.unmodifiable(<Endpoint>[
  Endpoint(WaterPlatform.drinking, 'POST', '/common/sms/sendCode', Effect.auth),
  Endpoint(WaterPlatform.drinking, 'POST', '/user/reg', Effect.auth),
  ...[
    for (final p in [
      '/user/balance',
      '/goods/latestUsed',
      '/goods/normal/skus',
      '/goods/normal/details',
      '/goods/water/sync',
      '/order/detail',
    ])
      Endpoint(WaterPlatform.drinking, 'POST', p, Effect.read),
  ],
  ...[
    for (final p in [
      '/userIntegral/checkUserIsRisk',
      '/payChannelRoute/addUserAfterPayChannel',
      '/orderRisk/isCheckLocation',
    ])
      Endpoint(WaterPlatform.drinking, 'POST', p, Effect.billingPreparation),
  ],
  Endpoint(
    WaterPlatform.drinking,
    'POST',
    '/goods/water/unlock',
    Effect.billingCommand,
  ),
  Endpoint(
    WaterPlatform.drinking,
    'POST',
    '/order/afterPay/creating',
    Effect.billingCommand,
  ),
  Endpoint(
    WaterPlatform.bathing,
    'GET',
    '/user/authentication/getCode',
    Effect.auth,
    authGateway: true,
  ),
  Endpoint(
    WaterPlatform.bathing,
    'POST',
    '/user/login/userLoginV2WithEncrypt',
    Effect.auth,
    authGateway: true,
  ),
  ...[
    for (final p in [
      '/user/basic/getUserInfo',
      '/mgapp/machine/getInfoByQRCode',
      '/mgapp/machine/getUseInfoByMachineId',
      '/bath/valve/getStatus',
    ])
      Endpoint(WaterPlatform.bathing, 'GET', p, Effect.read),
  ],
  Endpoint(
    WaterPlatform.bathing,
    'POST',
    '/bath/valve/open',
    Effect.billingCommand,
  ),
  Endpoint(
    WaterPlatform.bathing,
    'POST',
    '/bath/valve/close',
    Effect.billingCommand,
  ),
]);

bool trustedBusinessOrigin(Uri u) =>
    u.scheme == 'https' &&
    u.userInfo.isEmpty &&
    !u.hasQuery &&
    !u.hasFragment &&
    (u.path.isEmpty || u.path == '/') &&
    (!u.hasPort || u.port == 443) &&
    (u.host == 'v3-app.lxt6.cn' || u.host.endsWith('.lxt6.cn')) &&
    u.host != 'topservice.lxt6.cn';
String businessOrigin(Object? value) {
  if (value == null) return 'https://v3-app.lxt6.cn';
  final u = Uri.tryParse(value.toString());
  if (u == null || !trustedBusinessOrigin(u)) {
    throw const ApiFailure('业务网关无效，已阻止发送凭据', kind: FailureKind.policy);
  }
  return u.origin;
}

class WireRequest {
  final WaterPlatform platform;
  final String method, origin, path, query, signPayload;
  final Map<String, String> headers;
  final String? body;
  const WireRequest({
    required this.platform,
    required this.method,
    required this.origin,
    required this.path,
    required this.headers,
    this.query = '',
    this.body,
    this.signPayload = '',
  });
  Uri get uri => Uri.parse('$origin$path${query.isEmpty ? '' : '?$query'}');
}

class WireResponse {
  final int status;
  final Object? data;
  final List<String> setCookies;
  const WireResponse(
    this.data, {
    this.status = 200,
    this.setCookies = const [],
  });
}

abstract interface class Transport {
  Future<WireResponse> send(WireRequest request);
}

class RequestPolicy {
  final AppMode mode;
  const RequestPolicy(this.mode);
  Endpoint check(WireRequest r) {
    final matches = endpoints.where(
      (e) =>
          e.platform == r.platform && e.method == r.method && e.path == r.path,
    );
    if (matches.length != 1) {
      throw const ApiFailure('未许可的接口', kind: FailureKind.policy);
    }
    final e = matches.single;
    final u = Uri.tryParse(r.origin);
    final good = r.platform == WaterPlatform.drinking
        ? r.origin == 'https://userapi.qiekj.com'
        : e.authGateway
        ? r.origin == 'https://topservice.lxt6.cn'
        : u != null && trustedBusinessOrigin(u);
    if (!good) throw const ApiFailure('未许可的网关', kind: FailureKind.policy);
    if (mode == AppMode.readOnly &&
        (e.effect == Effect.billingCommand ||
            e.effect == Effect.billingPreparation)) {
      throw const ApiFailure('只读模式不允许计费操作', kind: FailureKind.policy);
    }
    return e;
  }
}

/// No retries, redirect following, shared cookies, token refresh or body logging.
class LiveTransport implements Transport {
  final RequestPolicy policy;
  final Dio _client;
  LiveTransport(AppMode mode, {Dio? client})
    : policy = RequestPolicy(mode),
      _client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 20),
            ),
          ) {
    if (mode == AppMode.mock) {
      throw StateError('Mock must never create a real client');
    }
  }
  @override
  Future<WireResponse> send(WireRequest r) async {
    final endpoint = policy.check(r);
    final elapsed = Stopwatch()..start();
    try {
      final response = await _client.request<String>(
        r.uri.toString(),
        data: r.body == null ? null : utf8.encode(r.body!),
        options: Options(
          method: r.method,
          headers: r.headers,
          followRedirects: false,
          maxRedirects: 0,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      void logCode(Object? code) => debugPrint(
        '[water] ${r.platform.name} ${r.method} ${r.path} effect=${endpoint.effect.name} http=$status code=${code is int ? code : 'unknown'} durationMs=${elapsed.elapsedMilliseconds}',
      );
      if (status < 200 || status >= 300) {
        logCode(null);
        throw ApiFailure(
          status == 401 || status == 403
              ? '登录已失效，请重新登录'
              : 'HTTP 请求未成功（$status）',
          kind: status == 401 || status == 403
              ? FailureKind.auth
              : FailureKind.network,
          code: status,
        );
      }
      Object? data;
      try {
        data = jsonDecode(response.data ?? '');
      } catch (_) {
        logCode(null);
        throw const ApiFailure('服务器未返回有效 JSON', kind: FailureKind.protocol);
      }
      logCode(
        data is Map
            ? data[r.platform == WaterPlatform.drinking ? 'code' : 'Code']
            : null,
      );
      return WireResponse(
        data,
        status: status,
        setCookies: response.headers['set-cookie'] ?? [],
      );
    } on DioException catch (e) {
      debugPrint(
        '[water] ${r.platform.name} ${r.method} ${r.path} effect=${endpoint.effect.name} transport=${e.type.name} durationMs=${elapsed.elapsedMilliseconds}',
      );
      throw const ApiFailure('网络请求未能确认，请检查网络或官方客户端', kind: FailureKind.network);
    }
  }
}

Object? envelope(WireResponse r, WaterPlatform p) {
  if (r.status < 200 || r.status >= 300) {
    throw ApiFailure(
      'HTTP 请求未成功（${r.status}）',
      kind: r.status == 401 || r.status == 403
          ? FailureKind.auth
          : FailureKind.network,
      code: r.status,
    );
  }
  final j = objectMap(r.data);
  final bath = p == WaterPlatform.bathing;
  final code = j[bath ? 'Code' : 'code'];
  if (code is! int) {
    throw const ApiFailure('响应缺少业务码', kind: FailureKind.protocol);
  }
  if (!(code == 0 || (!bath && code == 200))) {
    final text = (j[bath ? 'Message' : 'message'] ?? j['msg'] ?? '')
        .toString()
        .toLowerCase();
    final auth = bath
        ? code == -44
        : code == 401 ||
              code == 403 ||
              text.contains('未登录') ||
              text.contains('未登陆') ||
              text.contains('请先登录') ||
              (text.contains('token') &&
                  ['过期', '无效', 'expired', 'invalid'].any(text.contains));
    // Never surface untrusted server text that may echo a credential or QR.
    throw ApiFailure(
      auth ? '登录已失效，请使用同一账号重新登录' : '平台拒绝请求（$code），请在官方客户端核对',
      kind: auth ? FailureKind.auth : FailureKind.business,
      code: code,
    );
  }
  return j[bath ? 'Data' : 'data'];
}
