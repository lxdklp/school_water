#!/usr/bin/env node
/**
 * 洗澡设备工具 —— 扫码解析 / 状态 / 开阀 / 关阀
 * 业务类型：洗浴（typeId = 1），机型：4G。
 *
 * 二维码两种形态:
 *   1) 设备帧码: 12位mac + "A5..."                         → 离线解码 (protocol.mjs)
 *   2) 服务端码: https://n.lxt6.cn/all?EXAMPLE_DEVICE_QR        → mgapp/machine/getInfoByQRCode
 *
 * 洗澡的 HTTP 端点 (typeId=1):
 *   GET  bath/valve/getStatus  {typeId, machineId, modeValue, communicationVal}
 *   POST bath/valve/open       {typeId, channelWay:4, machineId, deviceVer, machineInfoJson}
 *   POST bath/valve/close      {typeId, channelWay:4, machineId, deviceVer, machineInfoJson}
 *
 * modeValue: 开阀上下文=1, 关阀上下文=2 (源码里 globalData.modeValue)
 * communicationVal: 上一次响应 Data.communicationVal，需要串联
 *
 * 安全: 默认 DRY-RUN，真正发送必须 --yes；open 建议配 --auto-close。
 */
import readline from 'node:readline';
import { writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { LxtClient } from './client.mjs';
import { decodeQr, resolveData } from './protocol.mjs';
import { loadSession, saveSession, clearSession, sessionAgeHours, SESSION_FILE } from './session.mjs';

/* ================= 参数 ================= */
const argv = process.argv.slice(2);
const cmd = argv[0];
const flag = (name, def) => {
  const i = argv.indexOf('--' + name);
  return i > -1 ? argv[i + 1] : def;
};
const has = (name) => argv.includes('--' + name);

const typeId = 1; // 洗浴业务

/* ================= 机器解析 ================= */
function extractMachine(data) {
  const out = {};
  out.machineId = data.machineId ?? data.machineNo ?? data.machineCode ?? data.SN ?? undefined;
  out.machineMac = data.machineMac ?? data.mac ?? undefined;
  out.deviceVer = data.deviceVer
    ?? (data.machinetypeid && data.machinever ? `${data.machinetypeid},${data.machinever}` : undefined);
  out.pwdVer = data.pwdVer ?? data.machinePwdVer ?? undefined;
  out.usageType = data.usageType ?? undefined;

  for (const key of ['originalData', 'machineDataFull', 'machineData']) {
    const f = data[key];
    if (typeof f === 'string' && /^A5/i.test(f)) {
      try {
        const d = resolveData(f);
        out.machineId ??= d.data.substr(0, 16);
        out.deviceVer ??= `${d.type},${d.version}`;
        out.frameDecoded = { cmd: d.cmd, type: d.type, version: d.version, status: d.status };
      } catch { /* 非 A5 帧忽略 */ }
    }
  }
  return out;
}

async function resolveMachine(c, qr) {
  if (qr) {
    try {
      return { source: 'local-frame', ...decodeQr(qr) };
    } catch { /* 服务端码 */ }

    // 原文 → 问号后段（签名必须基于原始字符串，不能编码）
    const cands = [qr];
    const tail = qr.includes('?') ? qr.slice(qr.lastIndexOf('?') + 1) : null;
    if (tail && tail !== qr) cands.push(tail);

    let last;
    for (const cand of cands) {
      const r = await c.call('mgapp/machine/getInfoByQRCode', { qrcode: cand }, 'GET');
      last = r;
      if (r.Code === 0 && r.Data) {
        return { source: 'server', qrcode: cand, raw: r.Data, ...extractMachine(r.Data) };
      }
    }
    // 兜底: 码尾当 SN（小程序 getMachineBySN 分支）
    if (tail) {
      const r2 = await c.call('mgapp/machine/getUseInfoByMachineId', { machineId: tail, typeId }, 'GET');
      if (r2.Code === 0 && r2.Data) {
        return { source: 'sn', machineId: tail, raw: r2.Data, ...extractMachine({ machineId: tail, ...r2.Data }) };
      }
      last = r2 ?? last;
    }
    throw new Error(`解析失败: ${last?.Code} ${last?.Message}`);
  }

  const machineId = flag('machine-id');
  if (!machineId) throw new Error('需要 --qr 或 --machine-id');
  return {
    source: 'args',
    machineId,
    deviceVer: flag('machine-ver', ''),
    pwdVer: flag('pwd-ver', ''),
  };
}

/* ================= 登录 ================= */
let _client = null;
function ask(q, { hidden = false } = {}) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    if (hidden) {
      const write = rl._writeToOutput.bind(rl);
      rl._writeToOutput = (s) => { if (s.includes(q)) write(s); };
    }
    rl.question(q, (a) => { rl.close(); if (hidden) process.stdout.write('\n'); resolve(a.trim()); });
  });
}
async function login() {
  const c = new LxtClient();
  const tokenFlag = flag('token');
  if (tokenFlag) { c.token = tokenFlag; return c; }

  // 1) 复用缓存
  const sess = loadSession();
  if (sess && !has('relogin')) {
    c.token = sess.token;
    if (sess.baseUrl) c.baseUrl = sess.baseUrl;
    try {
      const me = await c.getUserInfo();
      if (me.Code === 0) {
        const age = sessionAgeHours(sess).toFixed(1);
        console.log(`复用登录态 studentId=${sess.studentId || '?'} (${age}h 前保存)`);
        console.log('如需重登: 加 --relogin，或删除 .session.json\n');
        return c;
      }
      console.log(`缓存登录态失效(${me.Code} ${me.Message})，重新登录...`);
    } catch (e) {
      console.log(`缓存登录态不可用(${e?.message ?? e})，重新登录...`);
    }
  }

  // 2) 交互登录
  const phone = flag('phone') || (await ask('手机号/账号: '));
  const cap = await c.getCaptcha(phone);
  if (cap.Code !== 0) throw new Error('取验证码失败: ' + JSON.stringify(cap));
  writeFileSync('captcha.png', Buffer.from(cap.Data.replace(/^data:image\/\w+;base64,/, ''), 'base64'));
  try { spawn('open', ['captcha.png'], { stdio: 'ignore', detached: true }).unref(); } catch {}
  console.log('验证码: captcha.png（已尝试打开）');
  const code = await ask('图片验证码: ');
  const pwd = await ask('密码(不回显): ', { hidden: true });
  const r = await c.login(phone, pwd, code);
  if (r.Code !== 0) throw new Error(`登录失败: ${r.Code} ${r.Message}`);
  if (r.Data?.url) c.baseUrl = r.Data.url;

  // 3) 落盘
  if (c.token) {
    saveSession({ token: c.token, baseUrl: c.baseUrl, studentId: r.Data?.studentId });
    console.log(`登录成功 studentId=${r.Data?.studentId ?? '?'}，已缓存到 ${SESSION_FILE}\n`);
  } else {
    console.log(`登录成功 studentId=${r.Data?.studentId ?? '?'}（未拿到 token，未缓存）\n`);
  }
  return c;
}

async function client() {
  if (!_client) _client = await login();
  return _client;
}

/* ================= 洗澡状态 ================= */
let commVal = ''; // 串联用的 communicationVal

async function getStatus(c, machineId, modeValue) {
  const r = await c.call('bath/valve/getStatus', {
    typeId, machineId, modeValue, communicationVal: flag('comm-val') ?? commVal,
  }, 'GET');
  if (r.Code === 0 && r.Data?.communicationVal) commVal = r.Data.communicationVal;
  return r;
}

function deviceVerOf(m) {
  return m.deviceVer || flag('machine-ver', '');
}

/** 开阀：4G 机型 channelWay 固定为 4 */
function openPayload(m) {
  return {
    typeId,
    channelWay: 4,
    machineId: m.machineId,
    deviceVer: deviceVerOf(m),
    machineInfoJson: { lastPosMoney: '0000', lastPosSerial: '0000' },
  };
}

/** 关阀：带回开阀响应下发的 communicationVal */
function closePayload(m) {
  return {
    typeId,
    channelWay: 4,
    machineId: m.machineId,
    deviceVer: deviceVerOf(m),
    machineInfoJson: { machineId: m.machineId, communicationVal: commVal },
  };
}

/* ================= 子命令 ================= */
async function decode() {
  const qr = flag('qr');
  if (!qr) throw new Error('需要 --qr');
  try {
    console.log(JSON.stringify(decodeQr(qr), null, 2));
  } catch (e) {
    console.log(`不是设备帧(${e.message})`);
    console.log('属于服务端码，需登录解析：');
    console.log(`  node bath.mjs info --qr "${qr}"`);
  }
}

async function info() {
  const c = await client();
  const m = await resolveMachine(c, flag('qr'));
  const { raw, ...rest } = m;
  console.log('[机器参数]', JSON.stringify(rest, null, 2));
  if (raw) console.log('[服务端原始返回]', JSON.stringify(raw, null, 2));
  if (m.machineId) {
    const r2 = await c.call('mgapp/machine/getUseInfoByMachineId', { machineId: m.machineId, typeId }, 'GET');
    console.log('[getUseInfoByMachineId]', JSON.stringify(r2, null, 2));
  }
}

async function status() {
  const c = await client();
  const m = await resolveMachine(c, flag('qr'));
  if (!m.machineId) throw new Error('未能解析出 machineId');
  console.log('[getStatus]', JSON.stringify(await getStatus(c, m.machineId, Number(flag('mode', '1'))), null, 2));
}

async function open() {
  const qr = flag('qr');
  let m = null;

  // 免登录预览：本地可解的设备帧码，或直接给 --machine-id
  if (qr) {
    try { m = { source: 'local-frame', ...decodeQr(qr) }; } catch { /* 需服务端解析 */ }
  }
  if (!m && flag('machine-id')) {
    m = {
      source: 'args',
      machineId: flag('machine-id'),
      deviceVer: flag('machine-ver', ''),
    };
  }

  if (!has('yes')) {
    if (!m) {
      console.log('该二维码需登录解析，DRY-RUN 无法离线预览。');
      console.log('可改用: node bath.mjs open --machine-id <id> --machine-ver "01,82" 免登录预览');
      return;
    }
    console.log(`[设备] 洗浴 machineId=${m.machineId} ver=${deviceVerOf(m) || '-'}`);
    console.log('\n=== DRY-RUN：未发送 ===');
    console.log('POST bath/valve/open');
    console.log(JSON.stringify(openPayload(m), null, 2));
    console.log('\n确认无误后加 --yes 才会真正开阀。');
    return;
  }

  const c = await client();
  if (!m) m = await resolveMachine(c, qr);
  if (!m.machineId) throw new Error('未能解析出 machineId（先跑 info）');

  console.log(`[设备] 洗浴 machineId=${m.machineId} ver=${deviceVerOf(m) || '-'}`);

  console.log('\n>>> 开阀 ...');
  const r = await c.call('bath/valve/open', openPayload(m), 'POST');
  console.log('[open]', JSON.stringify(r));
  // communicationVal 只由 open/close 响应下发，关阀时要带上
  if (r.Data?.communicationVal) commVal = r.Data.communicationVal;

  if (r.Code !== 0) {
    console.log('\n开阀未成功，不启动自动关阀。');
    return;
  }

  const sec = Number(flag('auto-close', '0'));
  if (sec <= 0) {
    console.log('\n⚠️ 未设 --auto-close，阀可能一直开着；用 close 子命令关阀。');
    return;
  }
  const doClose = async (why) => {
    console.log(`\n>>> ${why}，关阀 ...`);
    try {
      const rc = await c.call('bath/valve/close', closePayload(m), 'POST');
      console.log('[close]', JSON.stringify(rc));
    } catch (e) { console.error('❌ 关阀失败:', e?.message ?? e); }
  };
  console.log(`\n${sec}s 后自动关阀（Ctrl-C 立即关）`);
  process.on('SIGINT', async () => { await doClose('收到中断'); process.exit(130); });
  setTimeout(async () => { await doClose(`${sec}s 到`); process.exit(0); }, sec * 1000);
  await new Promise(() => {});
}

async function close() {
  const c = await client();
  const m = await resolveMachine(c, flag('qr'));
  if (!m.machineId) throw new Error('未能解析出 machineId');
  if (flag('comm-val')) commVal = flag('comm-val');
  if (!commVal) {
    console.log('⚠️ 关阀需要 communicationVal（开阀响应里给的那个）。');
    console.log('   可加 --comm-val <值>，或先在同一次运行里用 open --auto-close 自动关。\n');
  }
  const payload = closePayload(m);
  if (!has('yes')) {
    console.log('=== DRY-RUN：未发送 ===');
    console.log('POST bath/valve/close');
    console.log(JSON.stringify(payload, null, 2));
    console.log('\n关阀加 --yes 发送。');
    return;
  }
  console.log('[close]', JSON.stringify(await c.call('bath/valve/close', payload, 'POST')));
}

/* ================= 分发 ================= */
async function loginOnly() {
  const c = await client();
  const me = await c.getUserInfo();
  console.log('当前用户:', me.Data?.studentName ?? '-', '| Code', me.Code);
}

async function sessionCmd() {
  const sess = loadSession();
  if (has('logout')) {
    clearSession();
    console.log('已清除登录态:', SESSION_FILE);
    return;
  }
  if (!sess) { console.log('无缓存登录态:', SESSION_FILE); return; }
  console.log(JSON.stringify({
    file: SESSION_FILE,
    studentId: sess.studentId,
    缓存时间: sess.savedAt,
    年龄小时: Number(sessionAgeHours(sess).toFixed(2)),
    baseUrl: sess.baseUrl,
    token长度: sess.token?.length ?? 0,
  }, null, 2));
}

const run = { decode, info, status, open, close, login: loginOnly, session: sessionCmd }[cmd];
if (!run) {
  console.log(`洗澡设备工具（4G 机型）

  node bath.mjs login   [--relogin]            # 登录并缓存(推荐先跑这个)
  node bath.mjs session [--logout]             # 查看/清除登录态
  node bath.mjs decode  --qr "<二维码原文>"
  node bath.mjs info    --qr "<二维码原文>"
  node bath.mjs status  --qr "..." | --machine-id N --comm-val <值> [--mode 1]
  node bath.mjs open    --qr "..." [--auto-close 120] --yes
  node bath.mjs close   --qr "..." | --machine-id N --comm-val <值> --yes`);
  process.exit(0);
}
try { await run(); } catch (e) { console.error('错误:', e?.message ?? e); process.exit(1); }
