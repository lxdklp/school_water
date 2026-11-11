#!/usr/bin/env node
/**
 * 示例：扫码 → 解析设备 → 查询归属
 */
import { LxtClient } from '../client.mjs';
import { loadSession } from '../session.mjs';
import { decodeQr } from '../protocol.mjs';

const arg = (name, def) => {
  const i = process.argv.indexOf('--' + name);
  return i > -1 ? process.argv[i + 1] : def;
};

const qr = arg('qr');
const machineIdArg = arg('machine-id');
const typeId = Number(arg('type', '1'));

const sess = loadSession();
if (!sess?.token) {
  console.error('没有登录凭据，请先执行: node bath.mjs login');
  process.exit(1);
}

const client = new LxtClient();
client.token = sess.token;
if (sess.baseUrl) client.baseUrl = sess.baseUrl;

// 1) 本地能解的设备帧码直接解，否则交给服务端
let machine = null;
if (qr) {
  try {
    machine = decodeQr(qr);
    console.log('本地解析:', JSON.stringify(machine, null, 2));
  } catch {
    const r = await client.call('mgapp/machine/getInfoByQRCode', { qrcode: qr }, 'GET');
    console.log('服务端解析:', JSON.stringify(r, null, 2));
    if (r.Code === 0) machine = r.Data;
  }
} else if (machineIdArg) {
  machine = { machineId: machineIdArg };
}

if (!machine?.machineId) {
  console.error('未能解析出 machineId');
  process.exit(1);
}

// 2) 归属信息
const use = await client.call('mgapp/machine/getUseInfoByMachineId', {
  machineId: machine.machineId,
  typeId,
}, 'GET');
console.log('归属:', JSON.stringify(use, null, 2));

const ver = machine.deviceVer || machine.machinever;
console.log(`\n设备: ${machine.machineId}`);
console.log(`固件: ${ver || '-'}`);
console.log('机型: 4G');
