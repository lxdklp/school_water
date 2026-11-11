import 'dart:convert';
import 'dart:math';

enum WaterPlatform { drinking, bathing }

enum AppMode { mock, readOnly, manualLive }

enum Stage {
  preflightFailed,
  preparing,
  sendingUnlock,
  awaitingWork,
  working,
  completionUnconfirmed,
  creatingOrder,
  loadingOrder,
  completed,
  sendingOpen,
  openAccepted,
  running,
  sendingClose,
  closeAccepted,
  closed,
  uncertain,
  resolvedByUser,
}

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

String? scalarId(Object? value) => switch (value) {
  String s when s.trim().isNotEmpty => s.trim(),
  int n => n.toString(),
  _ => null,
};
String requiredId(Object? v) =>
    scalarId(v) ??
    (throw const ApiFailure('响应缺少必要字段', kind: FailureKind.protocol));
Map<String, dynamic> objectMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  throw const ApiFailure('响应格式不完整', kind: FailureKind.protocol);
}

String input(String value, {int max = 4096}) {
  final v = value.trim();
  if (v.isEmpty || v.length > max || v.contains(RegExp(r'[\x00-\x1F]'))) {
    throw const ApiFailure('请检查输入内容或长度');
  }
  return v;
}

enum FailureKind { network, auth, business, protocol, policy, storage }

class ApiFailure implements Exception {
  final String message;
  final FailureKind kind;
  final int? code;
  const ApiFailure(this.message, {this.kind = FailureKind.business, this.code});
  @override
  String toString() => message;
}

class Device {
  final String id, name;
  final String? version;
  final int? typeId, channelWay;
  const Device({
    required this.id,
    required this.name,
    this.version,
    this.typeId,
    this.channelWay,
  });
  bool get bathSupported =>
      version == '01,82' && typeId == 1 && channelWay == 4;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'typeId': typeId,
    'channelWay': channelWay,
  };
  factory Device.fromJson(Map<String, dynamic> j) => Device(
    id: requiredId(j['id']),
    name: j['name'] as String,
    version: j['version'] as String?,
    typeId: j['typeId'] as int?,
    channelWay: j['channelWay'] as int?,
  );
}

class Account {
  final String scope, token, origin;
  final String? cookies, studentId;
  const Account({
    required this.scope,
    required this.token,
    required this.origin,
    this.cookies,
    this.studentId,
  });
  Map<String, dynamic> toJson() => {
    'scope': scope,
    'token': token,
    'origin': origin,
    'cookies': cookies,
    'studentId': studentId,
  };
  factory Account.fromJson(Map<String, dynamic> j) => Account(
    scope: requiredId(j['scope']),
    token: requiredId(j['token']),
    origin: requiredId(j['origin']),
    cookies: j['cookies'] as String?,
    studentId: j['studentId'] as String?,
  );
}

/// Immutable journal snapshot. No credential, response or QR is printable.
class Session {
  final String id, accountScope, origin;
  final WaterPlatform platform;
  final Device device;
  final Stage stage;
  final DateTime intentAt;
  final Map<String, dynamic> context;
  const Session({
    required this.id,
    required this.accountScope,
    required this.origin,
    required this.platform,
    required this.device,
    required this.stage,
    required this.intentAt,
    this.context = const {},
  });
  bool get finished => const {
    Stage.preflightFailed,
    Stage.completed,
    Stage.closed,
    Stage.resolvedByUser,
  }.contains(stage);

  /// Presence of any write-intent marker is conservative evidence, even if
  /// its response was lost. Read-only preparation fields are not such markers.
  bool get drinkingWriteMayHaveBeenSent =>
      [
        'unlockAttempted',
        'creatingAttempted',
        'initialOrderNo',
        'orderId',
      ].any(context.containsKey) ||
      context.keys.any((key) => key.startsWith('attempted:'));
  Session update(Stage next, [Map<String, dynamic> fields = const {}]) =>
      Session(
        id: id,
        accountScope: accountScope,
        origin: origin,
        platform: platform,
        device: device,
        stage: next,
        intentAt: intentAt,
        context: Map.unmodifiable({...context, ...fields}),
      );
  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'accountScope': accountScope,
    'origin': origin,
    'platform': platform.name,
    'device': device.toJson(),
    'stage': stage.name,
    'intentAt': intentAt.toUtc().toIso8601String(),
    'context': context,
  };
  factory Session.fromJson(Map<String, dynamic> j) {
    if (j['schemaVersion'] != 1) {
      throw const ApiFailure('会话版本不支持，请保留数据', kind: FailureKind.storage);
    }
    return Session(
      id: requiredId(j['id']),
      accountScope: requiredId(j['accountScope']),
      origin: requiredId(j['origin']),
      platform: WaterPlatform.values.byName(j['platform'] as String),
      device: Device.fromJson(objectMap(j['device'])),
      stage: Stage.values.byName(j['stage'] as String),
      intentAt: DateTime.parse(j['intentAt'] as String),
      context: Map.unmodifiable(objectMap(j['context'])),
    );
  }
  String encode() => jsonEncode(toJson());
}
