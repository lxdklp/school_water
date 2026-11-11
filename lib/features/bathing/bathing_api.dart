import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/models.dart';
import '../../core/network.dart';
import '../../core/signing_config.dart';

class BathCredentials {
  final String tokenInfo, cookiePairs;
  const BathCredentials(this.tokenInfo, this.cookiePairs);
  factory BathCredentials.parse(List<String> headers) {
    final cookies = <String, String>{};
    for (final header in headers) {
      // Split only at a new cookie name, never at Expires' date comma.
      for (final part in header.split(RegExp(r',(?=\s*[^\s;,=]+\s*=)'))) {
        try {
          final c = Cookie.fromSetCookieValue(part.trim());
          cookies[c.name] = c.value;
        } catch (_) {
          throw const ApiFailure('登录 Cookie 无效', kind: FailureKind.protocol);
        }
      }
    }
    final token = cookies['tokenInfo'];
    if (token == null || token.isEmpty) {
      throw const ApiFailure('登录缺少 tokenInfo', kind: FailureKind.protocol);
    }
    return BathCredentials(
      token,
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
  }
}

abstract interface class LxtAuthHeaderCodec {
  Map<String, String> encode(Account account);
}

/// Raw tokenInfo for x-token is provisional; never probes alternative formats.
class RawTokenHeaderCodec implements LxtAuthHeaderCodec {
  const RawTokenHeaderCodec();
  @override
  Map<String, String> encode(Account a) => {
    'x-token': a.token,
    'Cookie': a.cookies ?? 'tokenInfo=${a.token}',
  };
}

enum BathStatus { unknown, running, stopped }

abstract interface class BathStatusDecoder {
  BathStatus decode(Object? payload);
}

class UnknownBathStatusDecoder implements BathStatusDecoder {
  const UnknownBathStatusDecoder();
  @override
  BathStatus decode(Object? payload) => BathStatus.unknown;
}

class BathingApi {
  static const origin = 'https://v3-app.lxt6.cn';
  static const authOrigin = 'https://topservice.lxt6.cn';
  final Transport transport;
  final String signingKey;
  final DateTime Function() now;
  final LxtAuthHeaderCodec codec;
  final BathStatusDecoder decoder;
  BathingApi(
    this.transport, {
    DateTime Function()? now,
    this.signingKey = SigningConfig.bathingKey,
    this.codec = const RawTokenHeaderCodec(),
    this.decoder = const UnknownBathStatusDecoder(),
  }) : now = now ?? DateTime.now;
  static String ghost(int ms) {
    if (ms < 0 || ms > 0xFFFFFFFFFFFF) {
      throw const FormatException('timestamp range');
    }
    final h = ms.toRadixString(16).toUpperCase().padLeft(12, '0');
    var sum = 0, xor = 0;
    for (var i = 0; i < 12; i += 2) {
      final b = int.parse(h.substring(i, i + 2), radix: 16);
      sum += b;
      xor ^= b;
    }
    String hex(int n) =>
        (n & 255).toRadixString(16).toUpperCase().padLeft(2, '0');
    return '${hex(sum)}$h${hex(xor)}';
  }

  static String sign(String payload, {String key = SigningConfig.bathingKey}) =>
      md5
          .convert(utf8.encode('${SigningConfig.require(key)}$payload'))
          .toString();
  static String _trace() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  WireRequest build(
    String path,
    Map<String, dynamic> params, {
    String method = 'GET',
    Account? account,
    bool auth = false,
  }) {
    String? body;
    var actualPath = path;
    if (method == 'POST') {
      body = jsonEncode(params);
      if (path == '/user/login/userLoginV2') {
        actualPath = '${path}WithEncrypt';
        body = jsonEncode({'data': base64Encode(utf8.encode(body))});
      }
    }
    final payload =
        body ?? params.entries.map((e) => '${e.key}=${e.value}').join('&');
    final query = method == 'GET'
        ? params.entries
              .map(
                (e) =>
                    '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}',
              )
              .join('&')
        : '';
    return WireRequest(
      platform: WaterPlatform.bathing,
      method: method,
      origin: auth ? authOrigin : account?.origin ?? origin,
      path: actualPath,
      body: body,
      query: query,
      signPayload: payload,
      headers: {
        'Content-Type': 'application/json',
        'X-Sid': '2021011300001',
        'X-Sign': sign(payload, key: signingKey),
        'X-Ghost': ghost(now().millisecondsSinceEpoch),
        'X-Product-Ver': '3.16.1#?345',
        'X-Mobile-Info': '1#?iPhone#?iOS 17',
        'X-clientType': '4',
        'X-B3-TraceId': _trace(),
        'X-B3-SpanId': _trace(),
        if (!auth && account != null) ...codec.encode(account),
      },
    );
  }

  Future<Object?> call(
    String path,
    Map<String, dynamic> params, {
    String method = 'GET',
    Account? account,
    bool auth = false,
  }) async => envelope(
    await transport.send(
      build(path, params, method: method, account: account, auth: auth),
    ),
    WaterPlatform.bathing,
  );
  Future<Uint8List> captcha(String account) async {
    final data = await call('/user/authentication/getCode', {
      'account': input(account, max: 128),
      'topservice': true,
    }, auth: true);
    if (data is! String ||
        !data.startsWith('data:image/png;base64,') ||
        data.length > 1400000) {
      throw const ApiFailure('验证码图片无效，请刷新', kind: FailureKind.protocol);
    }
    try {
      final bytes = base64Decode(data.substring(22));
      if (bytes.length < 8 ||
          bytes[0] != 137 ||
          bytes[1] != 80 ||
          bytes[2] != 78 ||
          bytes[3] != 71) {
        throw const FormatException();
      }
      return bytes;
    } catch (_) {
      throw const ApiFailure('验证码解码失败，请刷新', kind: FailureKind.protocol);
    }
  }

  Future<Account> login(String account, String password, String code) async {
    final response = await transport.send(
      build(
        '/user/login/userLoginV2',
        {
          'studentMobile': input(account, max: 128),
          'loginPassword': input(password, max: 256),
          'code': input(code, max: 32),
          'topservice': true,
        },
        method: 'POST',
        auth: true,
      ),
    );
    final data = objectMap(envelope(response, WaterPlatform.bathing));
    final student = requiredId(data['studentId']);
    final credentials = BathCredentials.parse(response.setCookies);
    return Account(
      scope: 'student:$student',
      studentId: student,
      token: credentials.tokenInfo,
      cookies: credentials.cookiePairs,
      origin: businessOrigin(data['url']),
    );
  }

  Future<Device> resolve(Account a, String qr, String note) async {
    final j = objectMap(
      await call('/mgapp/machine/getInfoByQRCode', {
        'qrcode': input(qr),
      }, account: a),
    );
    final type = int.tryParse(j['typeId'].toString());
    final version = scalarId(j['deviceVer']);
    // Only the documented 4G profile is supported. Unknown versions stay preview-only.
    return Device(
      id: requiredId(j['machineId']),
      name: note.trim().isEmpty ? '浴室设备' : input(note, max: 120),
      version: version,
      typeId: type,
      channelWay: type == 1 && version == '01,82' ? 4 : null,
    );
  }

  Future<Object?> status(Account a, Session s) {
    final close = s.context['closeAttempted'] == true;
    final value = close
        ? s.context['closeCommunicationVal']
        : s.context['openCommunicationVal'];
    return call('/bath/valve/getStatus', {
      'typeId': 1,
      'machineId': s.device.id,
      'modeValue': close ? 2 : 1,
      'communicationVal': requiredId(value),
    }, account: a);
  }

  static Map<String, dynamic> openBody(Device d) {
    if (!d.bathSupported) throw const ApiFailure('此设备类型或版本尚未支持');
    return {
      'typeId': 1,
      'channelWay': 4,
      'machineId': d.id,
      'deviceVer': d.version,
      'machineInfoJson': {'lastPosMoney': '0000', 'lastPosSerial': '0000'},
    };
  }

  static Map<String, dynamic> closeBody(Session s) => {
    'typeId': 1,
    'channelWay': 4,
    'machineId': s.device.id,
    'deviceVer': s.device.version,
    'machineInfoJson': {
      'machineId': s.device.id,
      'communicationVal': requiredId(s.context['openCommunicationVal']),
    },
  };
}

/// Local preview only. Never grants permission to operate a device.
Map<String, String> previewFrame(String qr) {
  var body = qr.trim().toUpperCase();
  if (body.startsWith('HTTP')) body = body.substring(body.lastIndexOf('?') + 1);
  if (body.length < 52 ||
      body.length.isOdd ||
      !RegExp(r'^[0-9A-F]+$').hasMatch(body)) {
    throw const FormatException('无效设备帧');
  }
  final frame = body.substring(12);
  if (!frame.startsWith('A5')) throw const FormatException('不支持 legacy 帧');
  final r = frame.substring(4, frame.length - 2);
  if (r.length < 42) throw const FormatException('帧长度不足');
  final a = int.parse(r.substring(0, 2), radix: 16),
      b = int.parse(r.substring(2, 4), radix: 16);
  String dec(int off) =>
      (((int.parse(r.substring(off, off + 2), radix: 16) - 170) & 255) ^ a ^ b)
          .toRadixString(16)
          .toUpperCase()
          .padLeft(2, '0');
  if (!['F0', 'F1'].contains(dec(8)) ||
      !['01', '02', '03', '04', '05', '09'].contains(dec(10)) ||
      r.substring(18).length < 24) {
    throw const FormatException('未知设备帧');
  }
  return {
    'machineMac': body.substring(0, 12),
    'machineId': r.substring(18, 34),
    'machineRandom': r.substring(34, 42),
    'deviceVer': '${dec(10)},${dec(12)}',
  };
}
