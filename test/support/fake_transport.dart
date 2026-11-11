import 'package:water/core/models.dart';
import 'package:water/core/network.dart';
import 'package:water/features/bathing/bathing_api.dart';

enum DemoScenario {
  normal('正常流程'),
  empty('无历史设备'),
  offline('网络离线'),
  expired('登录过期'),
  lostOpen('开始响应丢失'),
  lostClose('结束响应丢失'),
  lostOrder('订单响应丢失'),
  noWork('未观测工作态'),
  conflict('订单号冲突'),
  missingValue('会话值缺失'),
  unknown('设备状态未知'),
  longName('长设备名称');

  final String label;
  const DemoScenario(this.label);
}

class FakeTransport implements Transport {
  final List<WireRequest> requests = [];
  DemoScenario scenario = DemoScenario.normal;
  final Duration latency;
  int syncCount = 0;
  bool opened = false, closed = false;
  FakeTransport({this.latency = const Duration(milliseconds: 220)});
  void reset(DemoScenario value) {
    scenario = value;
    syncCount = 0;
    opened = false;
    closed = false;
  }

  @override
  Future<WireResponse> send(WireRequest r) async {
    const RequestPolicy(AppMode.mock).check(r);
    requests.add(r);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (scenario == DemoScenario.offline) {
      throw const ApiFailure('模拟网络离线', kind: FailureKind.network);
    }
    final bath = r.platform == WaterPlatform.bathing;
    if (scenario == DemoScenario.expired) {
      return WireResponse(bath ? {'Code': -44} : {'code': 401});
    }
    Object? data;
    final name = scenario == DemoScenario.longName
        ? '校园东区教学楼一楼走廊靠近图书馆入口的饮水设备（演示长名称）'
        : '教学楼饮水机';
    switch (r.path) {
      case '/common/sms/sendCode':
        break;
      case '/user/reg':
        data = {'token': 'demo-drinking-token'};
      case '/user/balance':
        data = {'tokenCoin': '50', 'integral': '320', 'integralAmount': '3.20'};
      case '/goods/latestUsed':
        data = scenario == DemoScenario.empty
            ? []
            : [
                {'goodsId': 'demo-goods', 'goodsName': name},
                {'goodsId': 'demo-library', 'goodsName': '图书馆饮水机'},
              ];
      case '/goods/normal/skus':
        data = [
          {'skuId': 'demo-sku', 'name': '常温水'},
        ];
      case '/goods/normal/details':
        data = {'imei': 'demo-imei'};
      case '/goods/water/unlock':
        if (scenario == DemoScenario.lostOpen) {
          throw const ApiFailure('模拟开始响应丢失', kind: FailureKind.network);
        }
        data = {
          'orderNo': 'demo-order-${requests.length}',
          'msgId': 'demo-message',
        };
      case '/goods/water/sync':
        syncCount++;
        final unlocks = requests.where((e) => e.path == '/goods/water/unlock');
        String? order;
        if (unlocks.isNotEmpty) {
          final index = requests.indexOf(unlocks.last) + 1;
          order = 'demo-order-$index';
        }
        data = {
          'workStatus': scenario == DemoScenario.noWork
              ? 0
              : syncCount == 2
              ? 2
              : 0,
          if (order != null)
            'identify': scenario == DemoScenario.conflict
                ? 'foreign-order'
                : order,
        };
      case '/order/afterPay/creating':
        if (scenario == DemoScenario.lostOrder) {
          throw const ApiFailure('模拟订单响应丢失', kind: FailureKind.network);
        }
        data = {'orderId': 'demo-detail-${requests.length}'};
      case '/order/detail':
        data = {
          'tradeOrderItem': [
            {'originPrice': '0.12'},
          ],
          'promotionList': [
            {'promotionType': 8, 'discountAmount': '0.11'},
          ],
        };
      case '/user/authentication/getCode':
        data = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
      case '/user/login/userLoginV2WithEncrypt':
        data = {'studentId': 'demo-student', 'url': BathingApi.origin};
      case '/user/basic/getUserInfo':
        data = {'studentName': '演示账号'};
      case '/mgapp/machine/getInfoByQRCode':
        data = {
          'machineId': 'demo-bath-A7FA',
          'typeId': 1,
          'deviceVer': '01,82',
        };
      case '/mgapp/machine/getUseInfoByMachineId':
        data = {'schoolId': 'demo-school', 'investorId': 'demo-investor'};
      case '/bath/valve/open':
        opened = true;
        if (scenario == DemoScenario.lostOpen) {
          throw const ApiFailure('模拟开始响应丢失', kind: FailureKind.network);
        }
        data = {
          'offline': 0,
          if (scenario != DemoScenario.missingValue)
            'communicationVal': 'demo-open-A',
        };
      case '/bath/valve/close':
        closed = true;
        if (scenario == DemoScenario.lostClose) {
          throw const ApiFailure('模拟结束响应丢失', kind: FailureKind.network);
        }
        data = {
          'offline': 0,
          if (scenario != DemoScenario.missingValue)
            'communicationVal': 'demo-close-B',
        };
      case '/bath/valve/getStatus':
        data = scenario == DemoScenario.unknown
            ? {'unrecognized': true}
            : {'_demoStatus': closed ? 'stopped' : 'running'};
      default:
        data = null;
    }
    return WireResponse(
      bath ? {'Code': 0, 'Data': data} : {'code': 200, 'data': data},
      setCookies: r.path == '/user/login/userLoginV2WithEncrypt'
          ? [
              'tokenInfo=demo-token==; Path=/; HttpOnly; Secure',
              'demo=1; Path=/',
            ]
          : [],
    );
  }
}

class DemoBathStatusDecoder implements BathStatusDecoder {
  const DemoBathStatusDecoder();
  @override
  BathStatus decode(Object? payload) => payload is Map
      ? switch (payload['_demoStatus']) {
          'running' => BathStatus.running,
          'stopped' => BathStatus.stopped,
          _ => BathStatus.unknown,
        }
      : BathStatus.unknown;
}
