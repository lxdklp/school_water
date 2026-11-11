import {
  KEYSETS, xGhost, xSign, buildRequest, appQuery, BASE_HOSTS,
} from './signer.mjs';

export class LxtClient {
  /**
   * @param {object} opt
   * @param {'prod'|'deployLogin'|'test'} [opt.keySet]
   * @param {string} [opt.baseUrl]      覆盖默认域名(租户自定义 requstDomain)
   * @param {object} [opt.device]       {platform, model, system, productVer, clientType}
   * @param {string} [opt.token]        X-Cookie / x-token (登录后返回的 tokenInfo)
   */
  constructor(opt = {}) {
    this.keySet = opt.keySet || 'prod';
    this.keys = KEYSETS[this.keySet];
    this.baseUrl = opt.baseUrl || BASE_HOSTS.app;
    this.topserviceUrl = opt.topserviceUrl || BASE_HOSTS.topservice;
    this.token = opt.token || '';
    this.device = {
      platform: '1',
      model: 'iPhone',
      system: 'iOS 17',
      productVer: '3.16.1#?345',
      clientType: '4', // 小程序默认 initData.x_clientType = "4"
      ...(opt.device || {}),
    };
  }

  /** 生成与小程序一致的请求头 */
  headers(extra = {}) {
    const d = this.device;
    const h = {
      'content-type': 'application/json',
      'X-Sid': this.keys.v3_sid,
      'X-Ghost': xGhost(),
      'X-Product-Ver': d.productVer,
      'X-Mobile-Info': `${d.platform}#?${d.model}#?${d.system}`,
      'X-clientType': d.clientType,
      'X-B3-TraceId': cryptoRandomHex(16),
      'X-B3-SpanId': cryptoRandomHex(16),
      ...extra,
    };
    if (this.token) {
      h['x-token'] = this.token;
      h.Cookie = this.token;
    }
    return h;
  }

  /**
   * 调用一个接口。
   * @param {string} api     例如 "user/basic/getUserInfo"
   * @param {object} params  业务参数
   * @param {'GET'|'POST'} [method]
   * @param {{topservice?:boolean, form?:boolean, baseUrl?:string}} [opt]
   * @returns {Promise<{Code:number, Message?:string, Data:any, Serial?:number}>}
   */
  async call(api, params = {}, method = 'POST', opt = {}) {
    const req = buildRequest(api, params, method, { ...opt, keySet: this.keySet });
    const host = opt.baseUrl || (opt.topservice ? this.topserviceUrl : this.baseUrl);
    let url = host.replace(/\/$/, '') + '/' + req.path;
    if (method === 'GET' && req.payload) url += '?' + req.payload;

    const res = await fetch(url, {
      method,
      headers: this.headers({
        'content-type': req.contentType,
        'X-Sign': req.sign,
      }),
      body: method === 'GET' ? undefined : req.body,
    });
    const text = await res.text();
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      throw new Error(`non-JSON response (HTTP ${res.status}): ${text.slice(0, 200)}`);
    }
    // 登录成功后服务端通过 cookie 下发 tokenInfo
    const setCookie = res.headers.get('set-cookie') || '';
    if (/tokenInfo/.test(setCookie)) this.token = setCookie;
    return json;
  }

  /** 登录 (userLoginV2 → 自动加 WithEncrypt + base64 body) */
  login(studentMobile, loginPassword, code) {
    return this.call(
      'user/login/userLoginV2',
      { studentMobile, loginPassword, code, topservice: true },
      'POST',
      { topservice: true },
    );
  }

  /** 图形验证码 (登录取码前调用) */
  getCaptcha(account) {
    return this.call(
      'user/authentication/getCode',
      { account, topservice: true },
      'GET',
      { topservice: true },
    );
  }

  /** 当前登录用户 */
  getUserInfo() {
    return this.call('user/basic/getUserInfo', {}, 'GET');
  }

  /** 学校列表 */
  getSchools(schoolList) {
    return this.call('baseDict/school/getListBySchoolIds', { schoolList }, 'GET');
  }
}

function cryptoRandomHex(n) {
  const arr = new Uint8Array(n);
  globalThis.crypto.getRandomValues(arr);
  return Array.from(arr, (b) => b.toString(16).padStart(2, '0')).join('');
}

export default LxtClient;
