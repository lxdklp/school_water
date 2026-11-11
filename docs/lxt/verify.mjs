#!/usr/bin/env node
import { md5, xGhost, xSign, buildRequest, appQuery, rsaEncryptLong } from './signer.mjs';
import { resolveData, decodeQr } from './protocol.mjs';

const fixtureKeys = { v3_md5: 'fixture-bathing-key' };

let pass = 0;
let fail = 0;
function eq(name, got, want) {
  if (got === want) {
    pass++;
    console.log(`  ✓ ${name}`);
  } else {
    fail++;
    console.log(`  ✗ ${name}\n      got : ${got}\n      want: ${want}`);
  }
}

console.log('— 离线向量 —');
let missingKeyRejected = false;
try {
  xSign('fixture', { v3_md5: '' });
} catch {
  missingKeyRejected = true;
}
eq('缺失密钥时拒绝签名', missingKeyRejected, true);
// 1) MD5 与运行时逐字节一致
eq('md5("fixture-bathing-key")', md5('fixture-bathing-key'), '6e7b50d8b6568ca89307c5b938d7bdc1');
eq('md5(secret+body)', md5('fixture-bathing-key{"data":"eyJhIjoxfQ=="}'), 'ac89c98661cc7b73431de149219b8da2');

// 2) X-Ghost: 使用两个已知时间戳做校验
eq('xGhost(期望 ms 0x01A1A246F1CD)', xGhost(parseInt('01A1A246F1CD', 16)), '4801A1A246F1CD78');
eq('xGhost(期望 ms 0x01A1A2470228)', xGhost(parseInt('01A1A2470228', 16)), 'B501A1A24702286F');

// 3) 使用虚构密钥校验登录体包装和路径
const login = buildRequest(
  'user/login/userLoginV2',
  { studentMobile: '13000000000', loginPassword: '123456', code: '0000', topservice: true },
  'POST',
  { keySet: fixtureKeys },
);
eq('login path', login.path, 'user/login/userLoginV2WithEncrypt');
eq(
  'login body',
  login.body,
  '{"data":"eyJzdHVkZW50TW9iaWxlIjoiMTMwMDAwMDAwMDAiLCJsb2dpblBhc3N3b3JkIjoiMTIzNDU2IiwiY29kZSI6IjAwMDAiLCJ0b3BzZXJ2aWNlIjp0cnVlfQ=="}',
);
eq('login X-Sign', login.sign, 'dd897ea7b85c0059950ad96bac51b525');

// 4) 使用虚构密钥校验 GET 查询串和签名
eq('appQuery order', appQuery({ b: 2, a: 1 }), 'b=2&a=1');
eq('schoolList X-Sign', xSign('schoolList=1', fixtureKeys), 'ce22173aa34a8fafa70ecfdb4d2a0d84');

// 5) RSA 插件层
const enc = rsaEncryptLong('hello');
eq('rsaEncryptLong 单块长度(128bit → 16B → 32 hex)', enc.length, 32);
eq('rsaEncryptLong 多块拼接', rsaEncryptLong('abcdef').length, 32 * 2);

// 6) 设备帧解码 (与沙箱内 util/nb.js 的 resolveData 实跑一致)
const FRAME = 'A515ABCD21EE400F1010101234567890ABCDEF1122334400';
const dec = resolveData(FRAME);
eq('frame rns3/rns2', `${dec.rns3}/${dec.rns2}`, 'AB/CD');
eq('frame cmd', dec.cmd, 'F0');
eq('frame type', dec.type, '03');
eq('frame version', dec.version, '00');
eq('frame data', dec.data, '1234567890ABCDEF11223344');
const m = decodeQr('A1B2C3D4E5F6' + FRAME);
eq('qr machineMac', m.machineMac, 'A1B2C3D4E5F6');
eq('qr machineId', m.machineId, '1234567890ABCDEF');
eq('qr machineRandom', m.machineRandom, '11223344');
eq('qr deviceVer', m.deviceVer, '03,00');

console.log(`\n离线: ${pass} passed, ${fail} failed`);

if (!process.argv.includes('--live')) {
  console.log('(加 --live 可跑线上验证)');
  process.exit(fail ? 1 : 0);
}

/* ---------------- 线上验证 ---------------- */
const { LxtClient } = await import('./client.mjs');
const c = new LxtClient();

async function live() {
  console.log('\n— 线上验证 —');
  const cap = await c.getCaptcha('13000000000');
  eq('getCode Code', cap.Code, 0);
  eq('getCode 返回图片', typeof cap.Data === 'string' && cap.Data.startsWith('data:image/png;base64,'), true);

  const schools = await c.getSchools('1');
  eq('getListBySchoolIds Code', schools.Code, 0);

  // 故意错签 → 应被拒
  const url = `https://v3-app.lxt6.cn/baseDict/school/getListBySchoolIds?schoolList=1`;
  const bad = await fetch(url, {
    method: 'GET',
    headers: {
      'content-type': 'application/json',
      'X-Sid': c.keys.v3_sid,
      'X-Sign': '00000000000000000000000000000000',
      'X-Ghost': xGhost(),
    },
  }).then((r) => r.json());
  eq('错误签名被拒 (-301)', bad.Code, -301);

  // 缺 X-Ghost → -45
  const noGhost = await fetch(url, {
    method: 'GET',
    headers: {
      'content-type': 'application/json',
      'X-Sid': c.keys.v3_sid,
      'X-Sign': xSign('schoolList=1'),
    },
  }).then((r) => r.json());
  eq('缺 X-Ghost 被拒 (-45)', noGhost.Code, -45);
}

await live();
console.log(`\n总计: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
