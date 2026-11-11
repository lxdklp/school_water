# 洗浴设备接口工具包

一套用于对接 lxt6 校园自助洗浴设备的 Node.js 工具，包含登录、扫码解析、开关阀与签名计算。

- 接口文档：[API.md](API.md)
- 运行环境：Node.js 20.6+（使用内置 `fetch`）

---

## 目录结构

```
.
├── API.md                  # 接口文档（首读）
├── README.md               # 本文件
├── bath.mjs                # 命令行工具（登录 / 扫码 / 状态 / 开阀 / 关阀）
├── client.mjs              # HTTP 客户端，自动处理签名与令牌
├── signer.mjs              # 签名与加解密算法
├── protocol.mjs            # 设备二维码帧解析
├── session.mjs             # 登录态缓存
├── verify.mjs              # 自检脚本
├── apis.json               # 接口清单
└── examples/
    ├── open-close.mjs      # 开阀 → 关阀 完整示例
    ├── query-machine.mjs   # 扫码 → 查询设备（只读）
    └── sign-headers.mjs    # 生成请求头（curl / Postman 用）
```

---

## 本地签名配置

仓库不包含真实签名密钥。复制根目录的 `config/lxt.example.env` 为 `config/lxt.local.env`, 在本机填写所需密钥。原有本地配置已经迁移时可直接复用。示例中的账号、学校、设备和会话值均为虚构占位数据。

以下命令在 `docs/lxt` 目录执行。带网络请求的命令需额外传入本地配置, 例如:

```bash
node --env-file=../../config/lxt.local.env bath.mjs login
node --env-file=../../config/lxt.local.env bath.mjs info --qr "<你自己的设备二维码>"
```

`prod` 使用 `LXT_SIGN_KEY`, `deployLogin` 使用 `LXT_DEPLOY_SIGN_KEY`, `test` 使用 `LXT_TEST_SIGN_KEY`。V2 和 V4 辅助算法的配置项见模板, 仅使用对应算法时需要填写。配置缺失时签名函数会报错, 不会使用占位值发起请求。

## 快速开始

### 1. 登录并缓存凭据

```bash
node --env-file=../../config/lxt.local.env bath.mjs login
```

按提示输入手机号、图形验证码、密码。成功后凭据写入 `.session.json`（权限 `600`），
后续命令自动复用，无需重复登录。

### 2. 解析设备

```bash
node --env-file=../../config/lxt.local.env bath.mjs info --qr "https://n.lxt6.cn/all?EXAMPLE_DEVICE_QR"
```

### 3. 开阀（默认只预览，不发送）

```bash
# 预览
node --env-file=../../config/lxt.local.env bath.mjs open --machine-id 0000000000000001 --machine-ver "01,82"

# 真正开阀，120 秒后自动关闭
node --env-file=../../config/lxt.local.env bath.mjs open --qr "https://n.lxt6.cn/all?EXAMPLE_DEVICE_QR" --auto-close 120 --yes
```

### 4. 单独关阀

```bash
node --env-file=../../config/lxt.local.env bath.mjs close --machine-id 0000000000000001 --machine-ver "01,82" \
  --comm-val AAAA --yes
```

> 4G 机型关阀需要开阀响应里的 `communicationVal`。
> 若用 `open --auto-close`，工具会自动携带，无需手动传。

---

## 命令一览

| 命令 | 作用 |
|---|---|
| `login [--relogin]` | 登录并缓存凭据 |
| `session [--logout]` | 查看 / 清除登录态 |
| `decode --qr <码>` | 离线解析设备帧码 |
| `info --qr <码>` | 扫码解析设备（含服务端查询） |
| `status --qr/<--machine-id>` | 查询设备状态（需 `--comm-val`） |
| `open ... [--auto-close N] [--yes]` | 开阀 |
| `close ... [--yes]` | 关阀 |

通用参数：

| 参数 | 说明 |
|---|---|
| `--machine-id` | 设备编号（也可用 `--qr` 扫码传入） |
| `--machine-ver` | 固件版本，如 `01,82` |
| `--comm-val` | 关阀所需的会话值 |
| `--auto-close` | 开阀后自动关闭的秒数 |
| `--yes` | 真正发送写操作 |
| `--relogin` | 忽略缓存，重新登录 |

---

## 作为库使用

```js
import { LxtClient } from './client.mjs';
import { loadSession } from './session.mjs';

const s = loadSession();
const c = new LxtClient();
c.token = s.token;
if (s.baseUrl) c.baseUrl = s.baseUrl;

const r = await c.call('bath/valve/open', {
  typeId: 1,
  channelWay: 4,
  machineId: '0000000000000001',
  deviceVer: '01,82',
  machineInfoJson: { lastPosMoney: '0000', lastPosSerial: '0000' },
}, 'POST');
```

`client.call()` 会自动生成 `X-Sid` / `X-Sign` / `X-Ghost` 等头部。

---

## 自检

```bash
node verify.mjs          # 离线校验（签名、解码向量）
node --env-file=../../config/lxt.local.env verify.mjs --live   # 额外发起线上请求
```

---

## 注意事项

- **开阀会产生真实用水与计费**，工具默认只预览，需显式 `--yes` 才发送。
- 建议始终配合 `--auto-close`，避免阀门长时间开启。
- `.session.json` 等价于登录凭据，请勿提交到版本库；`node --env-file=../../config/lxt.local.env bath.mjs session --logout` 可清除。
