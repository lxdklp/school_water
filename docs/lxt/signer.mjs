import crypto from 'node:crypto';

function requireValue(value, name) {
  if (!value.trim()) throw new Error(`缺少签名配置: ${name}`);
  return value;
}

/* ------------------------------------------------------------------ *
 * 0. 基础件
 * ------------------------------------------------------------------ */

/** 标准 MD5, 输出小写 hex. */
export const md5 = (s) => crypto.createHash('md5').update(String(s), 'utf8').digest('hex');

/** js-base64 的 encode (等价 Buffer.toString('base64')) */
export const b64encode = (s) => Buffer.from(String(s), 'utf8').toString('base64');
export const b64decode = (s) => Buffer.from(String(s), 'base64').toString('utf8');

/* ------------------------------------------------------------------ *
 * 1. 密钥组 (util/secret.js —— getInterface)
 * ------------------------------------------------------------------ */

/**
 * 密钥由本地环境变量提供, 仓库只保留公共协议标识.
 * deployLogin: isDeployLogin && !topservice && channel === 'xzx'
 * test:        globalData.test && !beta
 */
export const KEYSETS = {
  prod: { v3_md5: process.env.LXT_SIGN_KEY || '', v3_sid: '2021011300001', v2_md5: process.env.LXT_V2_SIGN_KEY || '', v2_sid: '140000000000000001' },
  deployLogin: { v3_md5: process.env.LXT_DEPLOY_SIGN_KEY || '', v3_sid: '2024073000001', v2_md5: process.env.LXT_V2_SIGN_KEY || '', v2_sid: '140000000000000001' },
  test: { v3_md5: process.env.LXT_TEST_SIGN_KEY || '', v3_sid: '10000001', v2_md5: process.env.LXT_V2_SIGN_KEY || '', v2_sid: '140000000000000001' },
};

/* ------------------------------------------------------------------ *
 * 2. X-Ghost —— 带校验的毫秒时间戳 (util/util.js 的 q())
 * ------------------------------------------------------------------ *
 * 结构:  SUM(2 hex) + TIMESTAMP(12 hex, 大写) + XOR(2 hex)
 * 服务端用它做时间窗校验 —— 缺失/错误时返回
 *   {"Code":-45,"Message":"请求已过期,请核对设备时间!"}
 */
export function xGhost(ms = Date.now()) {
  let h = ms.toString(16).toUpperCase();
  if (h.length !== 12) h = '0' + h; // 与源码一致: 只补一个 0
  let sum = 0;
  let xor = 0;
  for (let i = 0; i < h.length; i += 2) {
    const byte = parseInt(h.substring(i, i + 2), 16);
    sum += byte;
    xor ^= byte;
  }
  const hex2 = (n) => ('00' + (n & 0xff).toString(16)).slice(-2).toUpperCase();
  return hex2(sum) + h + hex2(xor);
}

/* ------------------------------------------------------------------ *
 * 3. 签名体构造 (util/util.js 的 A() 与 fnJson)
 * ------------------------------------------------------------------ */

/**
 * A(obj): 直接把对象拼成 k=v&k=v —— 不排序、不 URL 编码、用插入顺序。
 * 这就是 X-Sign 里参与摘要的那段字符串。
 */
export function appQuery(obj) {
  if (!obj || typeof obj !== 'object') return '';
  return Object.entries(obj)
    .map(([k, v]) => `${k}=${v}`)
    .join('&');
}

/** 需要把 body 做 base64 包裹 + 路径追加 "WithEncrypt" 的接口 (按末段方法名匹配) */
export const WITH_ENCRYPT = new Set([
  'userLoginV2',
  'moblieRegisterUser',
  'loginPasswordByAuthenticationMessage',
  'userLoginPassword',
]);

/**
 * 计算 X-Sign。
 * payload 规则(fnJson):
 *   GET   : A(params)
 *   POST  : JSON.stringify(params), 若命中 WITH_ENCRYPT 则为 JSON.stringify({data: base64(...)})
 *   表单  : A(params)   (POST + 第4参 "true")
 */
export function xSign(payload, keySet = 'prod') {
  const ks = typeof keySet === 'string' ? KEYSETS[keySet] : keySet;
  if (!ks) throw new Error(`unknown keySet: ${keySet}`);
  return md5(requireValue(ks.v3_md5, 'LXT_SIGN_KEY') + payload);
}

/**
 * 按小程序逻辑生成一次请求所需的 path / body / content-type / sign 负载。
 * @param {string} api     例如 "user/login/userLoginV2"
 * @param {object} params  业务参数(与小程序调用处同序)
 * @param {'GET'|'POST'} method
 * @param {{form?: boolean}} opt  form=true 对应第4参 "true"(application/x-www-form-urlencoded)
 */
export function buildRequest(api, params = {}, method = 'POST', opt = {}) {
  let path = api;
  let payload;
  let body;
  let contentType = 'application/json';

  if (method === 'GET') {
    payload = appQuery(params);
    body = undefined;
  } else if (opt.form) {
    contentType = 'application/x-www-form-urlencoded';
    payload = appQuery(params);
    body = payload;
  } else {
    const leaf = api.split('/').pop();
    if (WITH_ENCRYPT.has(leaf)) {
      path = api + 'WithEncrypt';
      body = JSON.stringify({ data: b64encode(JSON.stringify(params)) });
    } else {
      body = JSON.stringify(params);
    }
    payload = body;
  }

  return { path, body, contentType, payload, sign: xSign(payload, opt.keySet || 'prod') };
}

/* ------------------------------------------------------------------ *
 * 4. V4 层 (V4/v4-util.js) —— 另一套独立签名
 * ------------------------------------------------------------------ *
 * header: { timestamp, token?, sign }
 *   签名使用本地配置的 LXT_V4_SALT
 *   设备开阀签名使用本地配置的 LXT_V4_DEVICE_SALT
 * 无 token 时只带 timestamp。
 */
export const V4_SALT = process.env.LXT_V4_SALT || '';
export const V4_DEVICE_SALT = process.env.LXT_V4_DEVICE_SALT || '';
export const V4_DEVICE_APIS = ['/device/open', '/v4/device/open', '/api/whitelist/status'];

export function v4Headers(api, token, timestamp = Date.now()) {
  const h = { 'content-type': 'application/json', timestamp };
  if (V4_DEVICE_APIS.includes(api)) {
    h.sign = md5(`timestamp=${timestamp}${requireValue(V4_DEVICE_SALT, 'LXT_V4_DEVICE_SALT')}`);
  } else if (token) {
    h.token = token;
    h.sign = md5(`${token}${timestamp}${requireValue(V4_SALT, 'LXT_V4_SALT')}`);
  }
  return h;
}

/* ------------------------------------------------------------------ *
 * 5. 插件层 (utils/util.js + services/api.js) —— 支付宝风格网关
 * ------------------------------------------------------------------ *
 * POST https://webgw.alipay-eco.com  (form-urlencoded)
 *   { service: "promotionplugin."+service, version:"1.0",
 *     biz_content: needRsa ? JSON.stringify({data: RSA(JSON.stringify(payload))}) : JSON.stringify(payload),
 *     client_id: "2021002134696668", token }
 * 注意: RSA 公钥只有 128 bit, 等于没有加密强度。
 */
export const PLUGIN_PUBLIC_KEY =
  'MCwwDQYJKoZIhvcNAQEBBQADGwAwGAIRAL80JaqWM8SzrIUuX/heibsCAwEAAQ==';
export const PLUGIN_CLIENT_ID = '2021002134696668';

function pemFromB64(b64) {
  return `-----BEGIN PUBLIC KEY-----\n${b64.match(/.{1,64}/g).join('\n')}\n-----END PUBLIC KEY-----`;
}

/**
 * wxmp-rsa / JSEncrypt 的 encryptLong:
 * 每块长度 = (n.bitLength()+7>>3) - 11 字节, 逐块 PKCS#1 v1.5 加密, hex 拼接。
 */
export function rsaEncryptLong(text, publicKeyB64 = PLUGIN_PUBLIC_KEY) {
  const pem = pemFromB64(publicKeyB64);
  const bits = crypto.createPublicKey(pem).asymmetricKeyDetails.modulusLength;
  const chunkSize = (bits + 7 >> 3) - 11;
  if (chunkSize <= 0) throw new Error('key too small');
  const buf = Buffer.from(String(text), 'utf8');
  const out = [];
  for (let i = 0; i < buf.length; i += chunkSize) {
    out.push(
      crypto.publicEncrypt(
        { key: pem, padding: crypto.constants.RSA_PKCS1_PADDING },
        buf.subarray(i, i + chunkSize),
      ).toString('hex'),
    );
  }
  return out.join('');
}

/** 插件层 service 调用体 */
export function pluginBody(service, payload, { needRsa = false, token = '' } = {}) {
  const json = JSON.stringify(payload);
  const biz = needRsa ? JSON.stringify({ data: rsaEncryptLong(json) }) : json;
  return {
    service: 'promotionplugin.' + service,
    version: '1.0',
    biz_content: biz,
    client_id: PLUGIN_CLIENT_ID,
    token,
  };
}

/* ------------------------------------------------------------------ *
 * 6. 已知常量 (排错用)
 * ------------------------------------------------------------------ */
export const RESPONSE_CODES = {
  0: '成功',
  '-44': '未登录 / 登录态失效',
  '-45': '请求已过期(缺 X-Ghost 或时间窗不对)',
  '-67': '系统异常(参数不全)',
  '-301': '数据安全校验不通过(X-Sign 错误)',
};
export const BASE_HOSTS = {
  app: 'https://v3-app.lxt6.cn',
  topservice: 'https://topservice.lxt6.cn',
  deploy: 'https://deploy.lxt6.cn',
  plugin: 'https://webgw.alipay-eco.com',
};
