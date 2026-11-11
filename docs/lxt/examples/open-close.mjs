#!/usr/bin/env node
/**
 * 示例：开阀 → 使用 → 关阀
 *
 * 运行前先登录一次：  node bath.mjs login
 *
 * 说明：
 *   - channelWay：4G 机型固定为 4
 *   - communicationVal 由开阀响应下发，关阀时必须带回
 *   - 无论正常结束还是 Ctrl-C，都会尝试关阀
 */
import { LxtClient } from '../client.mjs';
import { loadSession } from '../session.mjs';

const arg = (name, def) => {
  const i = process.argv.indexOf('--' + name);
  return i > -1 ? process.argv[i + 1] : def;
};

const machineId = arg('machine-id');
if (!machineId) {
  console.error('请通过 --machine-id 显式传入自己的设备编号');
  process.exit(1);
}
const deviceVer = arg('machine-ver', '01,82');
const channelWay = 4;
const seconds = Number(arg('seconds', '60'));
const typeId = 1;

const dryRun = process.argv.includes('--dry-run');

const sess = loadSession();
if (!sess?.token) {
  console.error('没有登录凭据，请先执行: node bath.mjs login');
  process.exit(1);
}

const client = new LxtClient();
client.token = sess.token;
if (sess.baseUrl) client.baseUrl = sess.baseUrl;

const log = (...a) => console.log(...a);

if (dryRun) {
  console.log('DRY-RUN（未发送）\n');
  console.log('开阀请求:', JSON.stringify({
    typeId, channelWay, machineId, deviceVer,
    machineInfoJson: { lastPosMoney: '0000', lastPosSerial: '0000' },
  }, null, 2));
  console.log('\n关阀请求:', JSON.stringify({
    typeId, channelWay, machineId, deviceVer,
    machineInfoJson: { machineId, communicationVal: '<开阀返回的 communicationVal>' },
  }, null, 2));
  process.exit(0);
}

async function openValve() {
  const payload = {
    typeId,
    channelWay,
    machineId,
    deviceVer,
    machineInfoJson: { lastPosMoney: '0000', lastPosSerial: '0000' },
  };
  log('→ 开阀', JSON.stringify(payload));
  const r = await client.call('bath/valve/open', payload, 'POST');
  log('← 响应', JSON.stringify(r));
  if (r.Code !== 0) throw new Error(`开阀失败: ${r.Code} ${r.Message}`);
  if (r.Data?.offline) log(`⚠️ 设备脱机 ${r.Data.offlineDuration} 分钟`);
  return r.Data?.communicationVal;
}

async function closeValve(communicationVal) {
  const payload = {
    typeId,
    channelWay,
    machineId,
    deviceVer,
    machineInfoJson: { machineId, communicationVal },
  };
  log('→ 关阀', JSON.stringify(payload));
  const r = await client.call('bath/valve/close', payload, 'POST');
  log('← 响应', JSON.stringify(r));
  return r;
}

let cv = null;
let closing = false;

async function safeClose(why) {
  if (closing || !cv) return;
  closing = true;
  log(`\n[${why}] 正在关阀 …`);
  try {
    await closeValve(cv);
    log('已关阀');
  } catch (e) {
    console.error('关阀失败，请在小程序或设备上手动关闭:', e?.message ?? e);
  }
}

process.on('SIGINT', async () => {
  await safeClose('中断');
  process.exit(130);
});

try {
  cv = await openValve();
  log(`\n已开阀，${seconds} 秒后自动关闭（Ctrl-C 可提前关闭）`);
  await new Promise((r) => setTimeout(r, seconds * 1000));
  await safeClose('到时');
} catch (e) {
  console.error('流程异常:', e?.message ?? e);
  await safeClose('异常');
  process.exit(1);
}
