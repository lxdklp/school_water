# 校园洗浴设备开放接口文档

> 适用：lxt6 校园自助洗浴设备（`typeId = 1`）的扫码、开阀、关阀。
> 版本：接口版本 v3，文档基于设备 `deviceVer = 01,82`（4G 机型）实测。
> 本文用户、学校、设备和会话值均为虚构占位数据, 不能用于实际请求。

---

## 1. 基础约定

| 项 | 值 |
|---|---|
| 业务网关 | `https://v3-app.lxt6.cn`，或登录后返回的学校专属域（`Data.url`） |
| 认证网关 | `https://topservice.lxt6.cn`（登录、部署信息） |
| 请求方法 | `GET` / `POST` |
| 请求体 | `application/json`；个别接口为 `application/x-www-form-urlencoded` |
| 字符集 | UTF-8 |
| 响应体 | `application/json` |

所有接口都需要在请求头携带签名，见第 2 节。

---

## 2. 认证与签名

### 2.1 获取图形验证码

```
GET /user/authentication/getCode?account={手机号}&topservice=true
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `account` | string | 手机号 / 账号 |
| `topservice` | bool | 固定 `true` |

响应：

```json
{ "Code": 0, "Message": "请求成功", "Data": "data:image/png;base64,iVBORw0KGgo..." }
```

`Data` 是完整的 dataURL，可直接用于展示。

### 2.2 登录

登录接口的 URL 带 `WithEncrypt` 后缀，入参整体做 Base64 包裹：

```
POST /user/login/userLoginV2WithEncrypt
Content-Type: application/json
```

原始参数（先序列化，再 Base64，再包进 `data` 字段）：

| 参数 | 类型 | 说明 |
|---|---|---|
| `studentMobile` | string | 手机号 / 账号 |
| `loginPassword` | string | 密码 |
| `code` | string | 图形验证码 |
| `topservice` | bool | 固定 `true` |

```js
const inner = JSON.stringify({ studentMobile, loginPassword, code, topservice: true });
const body  = JSON.stringify({ data: Buffer.from(inner).toString('base64') });
```

响应：

```json
{
  "Code": 0,
  "Message": "请求成功",
  "Data": { "studentId": "demo-student", "url": "https://v3-app.lxt6.cn" }
}
```

> **Token 在响应头 `Set-Cookie` 的 `tokenInfo` 里**，不是 JSON 字段。
> 后续请求把它同时放进 `x-token` 与 `Cookie` 两个头。
> 登录成功后应把 `Data.url` 作为后续业务接口的域名（未配置专属域时回落默认域）。

### 2.3 请求头

```http
content-type: application/json
X-Sid: 2021011300001
X-Sign: <签名>
X-Ghost: <带校验的时间戳>
X-Product-Ver: 3.16.1#?345
X-Mobile-Info: 1#?iPhone#?iOS 17
X-clientType: 4
X-B3-TraceId: <16 字节随机 hex>
X-B3-SpanId:  <16 字节随机 hex>
x-token: <token>      # 登录后才有
Cookie: <token>       # 登录后才有
```

### 2.4 X-Sign

```
X-Sign = MD5( v3_md5 + payload )
```

`v3_md5` 从本地环境变量 `LXT_SIGN_KEY` 读取, 仓库不包含真实签名密钥。`X-Sid` 是公共协议标识。
`payload` 随请求类型变化：

| 场景 | payload |
|---|---|
| `GET` | `k=v&k=v`，按参数书写顺序拼接，**不排序、不做 URL 编码** |
| `POST` JSON | 请求体原文（`JSON.stringify` 的结果） |
| `POST` 表单 | 同 GET 的拼接方式 |

> 摘要输入是「原文」，不是编码后的值。若客户端对 query 做了 URL 编码，
> 签名仍应基于编码前的字符串。

示例：

```js
import crypto from 'node:crypto';
const md5 = (s) => crypto.createHash('md5').update(s, 'utf8').digest('hex');

md5(process.env.LXT_SIGN_KEY + 'schoolList=1');
```

### 2.5 X-Ghost

带校验的毫秒时间戳，共 16 位：

```
X-Ghost = 校验和(2位) + 时间戳(12位十六进制,大写) + 异或(2位)
```

```js
function xGhost(ms = Date.now()) {
  let h = ms.toString(16).toUpperCase();
  if (h.length !== 12) h = '0' + h;
  let sum = 0, xor = 0;
  for (let i = 0; i < h.length; i += 2) {
    const b = parseInt(h.substring(i, i + 2), 16);
    sum += b; xor ^= b;
  }
  const hex2 = (n) => ('00' + (n & 0xff).toString(16)).slice(-2).toUpperCase();
  return hex2(sum) + h + hex2(xor);
}

xGhost(1793723920845); // '4801A1A246F1CD78'
```

> 缺失或不合法时，任意接口都会返回
> `{"Code":-45,"Message":"请求已过期,请核对设备时间!"}`。
> 时间窗通常为数分钟，建议每次请求实时生成。

### 2.6 响应信封与错误码

```json
{ "Code": 0, "Message": "正常", "Data": {}, "Serial": 1793725452480 }
```

| Code | 含义 | 处理建议 |
|---|---|---|
| `0` | 成功 | — |
| `-44` | 未登录 / 登录态失效 | 重新登录 |
| `-45` | 请求已过期（缺 `X-Ghost`）或业务校验失败 | 检查时间戳；或看 `Message` |
| `-67` | 系统异常（参数缺失/不匹配） | 核对参数与接口域名 |
| `-301` | 数据安全校验不通过 | `X-Sign` 错误 |
| `-302` | 必填参数为空 | 见 `Message` 中点名的字段 |

---

## 3. 设备模型

### 3.1 设备标识

| 字段 | 示例 | 说明 |
|---|---|---|
| `machineId` | `0000000000000002` | 设备编号，16 位 |
| `deviceVer` | `01,82` | `设备类型,固件版本`；`01` 表示洗浴 |
| `deviceMac` | `02:00:00:00:00:01` | 设备 MAC 地址 |
| `typeId` | `1` | 业务类型，洗浴固定为 `1` |

### 3.2 通信方式

设备为 **4G 机型**，指令由服务端下发，`channelWay` 固定为 `4`。

---

## 4. 接口清单

### 4.1 扫码解析设备

```
GET /mgapp/machine/getInfoByQRCode?qrcode={二维码内容}
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `qrcode` | string | 扫码得到的完整字符串 |

响应：

```json
{
  "Code": 0,
  "Data": {
    "machineId": "0000000000000002",
    "typeId": 1,
    "deviceMac": "02:00:00:00:00:01",
    "deviceVer": "01,82"
  }
}
```

### 4.2 查询设备归属

```
GET /mgapp/machine/getUseInfoByMachineId?machineId={machineId}&typeId=1
```

```json
{ "Code": 0, "Data": { "schoolId": 1, "investorId": "000000000000000001" } }
```

> `investorId` 是 18 位字符串，**不要转成数字**，否则会丢精度。

### 4.3 查询设备状态

```
GET /bath/valve/getStatus?typeId=1&machineId={machineId}&modeValue={1|2}&communicationVal={值}
```

| 参数 | 说明 |
|---|---|
| `modeValue` | 开阀上下文填 `1`，关阀上下文填 `2` |
| `communicationVal` | 会话值，**不可为空** |

> `communicationVal` 由 **open / close 的响应**下发，首次调用时还没有该值。
> 因此它不能作为「开阀前置检查」使用：开阀前直接请求会返回
> `-302 参数machineId/communicationVal不能为空`。
> 该接口用于开关阀之后的轮询。

### 4.4 开阀

```
POST /bath/valve/open
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `typeId` | number | `1` |
| `channelWay` | number | 固定 `4`，**必填** |
| `machineId` | string | 设备编号 |
| `deviceVer` | string | `01,82` |
| `machineInfoJson` | object | `{ "lastPosMoney": "0000", "lastPosSerial": "0000" }` |

```json
{
  "typeId": 1,
  "channelWay": 4,
  "machineId": "0000000000000002",
  "deviceVer": "01,82",
  "machineInfoJson": { "lastPosMoney": "0000", "lastPosSerial": "0000" }
}
```

成功响应：

```json
{
  "Code": 0,
  "Message": "正常",
  "Data": { "offline": 0, "offlineDuration": 7, "communicationVal": "AAAA" }
}
```

| 字段 | 说明 |
|---|---|
| `offline` | `0` 在线，非 0 脱机 |
| `offlineDuration` | 脱机时长（分钟） |
| `communicationVal` | **本次会话值，关阀时必须带回去** |

### 4.5 关阀

```
POST /bath/valve/close
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `typeId` | number | `1` |
| `channelWay` | number | 固定 `4`，与开阀一致 |
| `machineId` | string | 设备编号 |
| `deviceVer` | string | `01,82` |
| `machineInfoJson` | object | `{ "machineId": "…", "communicationVal": "…" }` |

```json
{
  "typeId": 1,
  "channelWay": 4,
  "machineId": "0000000000000002",
  "deviceVer": "01,82",
  "machineInfoJson": {
    "machineId": "0000000000000002",
    "communicationVal": "AAAA"
  }
}
```

成功响应：

```json
{ "Code": 0, "Message": "正常", "Data": { "communicationVal": "BBBB" } }
```

> `communicationVal` 每次开关阀都会更新，关闭时用**开阀返回的那个值**。

### 4.6 当前用户

```
GET /user/basic/getUserInfo
```

```json
{
  "Code": 0,
  "Data": {
    "studentName": "示例用户",
    "studentMobile": "1**********",
    "studentIdentity": "…",
    "studentGender": "1",
    "studentHex": "…"
  }
}
```

> 该接口**不返回** `studentId`，需要时用登录响应的 `Data.studentId`。

---

## 5. 典型流程

```
① 扫码
   GET  getInfoByQRCode            → machineId / deviceVer
        │
② 开阀
   POST bath/valve/open            → Data.communicationVal
        │   （记录这个值）
        │
③ 使用中
   GET  bath/valve/getStatus       ← 带 modeValue=1 与 communicationVal
        │
④ 关阀
   POST bath/valve/close           ← machineInfoJson 带上 communicationVal
```

最小可用序列只有两步：**open → close**。`getStatus` 是可选的轮询。

---

## 6. 示例

### 6.1 curl

```bash
# 变量
HOST=https://v3-app.lxt6.cn
SID=2021011300001
KEY="$LXT_SIGN_KEY"

# X-Ghost 由脚本生成（见 2.5）
GHOST=$(node -e "..." )

# 开阀：payload 为请求体原文
BODY='{"typeId":1,"channelWay":4,"machineId":"0000000000000002","deviceVer":"01,82","machineInfoJson":{"lastPosMoney":"0000","lastPosSerial":"0000"}}'
SIGN=$(printf '%s' "$KEY$BODY" | md5)

curl -s -X POST "$HOST/bath/valve/open" \
  -H "content-type: application/json" \
  -H "X-Sid: $SID" -H "X-Sign: $SIGN" -H "X-Ghost: $GHOST" \
  -H "x-token: $TOKEN" -H "Cookie: $TOKEN" \
  --data-binary "$BODY"
```

### 6.2 Node.js

```js
import { LxtClient } from './client.mjs';

const c = new LxtClient();
c.token = process.env.LXT_TOKEN;          // 或调用登录接口获取令牌

// 1) 解析设备
const info = await c.call('mgapp/machine/getInfoByQRCode',
  { qrcode: 'https://n.lxt6.cn/all?EXAMPLE_DEVICE_QR' }, 'GET');
const { machineId, deviceVer } = info.Data;

// 2) 开阀
const open = await c.call('bath/valve/open', {
  typeId: 1,
  channelWay: 4,
  machineId,
  deviceVer,
  machineInfoJson: { lastPosMoney: '0000', lastPosSerial: '0000' },
}, 'POST');

// 3) 关阀（带上开阀返回的 communicationVal）
await c.call('bath/valve/close', {
  typeId: 1,
  channelWay: 4,
  machineId,
  deviceVer,
  machineInfoJson: { machineId, communicationVal: open.Data.communicationVal },
}, 'POST');
```

更多可运行示例见 [`examples/`](examples/)。

---

## 7. 常见报错排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `-301 数据安全校验不通过` | `X-Sign` 与 payload 不一致 | 确认签名基于参数原文、顺序一致 |
| `-45 请求已过期` | 未带 / 错带 `X-Ghost` | 实时生成，注意 12 位补零 |
| `-302 …channelWay…不能为空` | 开阀漏了 `channelWay` | 固定填 `4` |
| `-302 …communicationVal…不能为空` | 在开阀前调了 `getStatus` | 改为开阀后再查 |
| `-67 系统异常` | 打错域名（如余额类接口误用 `topservice`） | 改用登录返回的 `Data.url` |
| 开阀成功但不出水 | 设备脱机 | 看响应 `Data.offline` 与 `offlineDuration` |

---

## 8. 注意事项

- 开阀会产生**真实用水与计费**，请务必在关闭前不要中断流程。
- `communicationVal` 是会话级凭证，一次开关阀即失效，不可复用。
- 设备侧存在授信/额度校验，余额不足时开阀会被直接拒绝。
