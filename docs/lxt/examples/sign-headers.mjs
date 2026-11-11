#!/usr/bin/env node
/**
 * 示例：生成某个请求所需的头部（可直接贴到 curl / Postman）
 *
 *   node examples/sign-headers.mjs GET /baseDict/school/getListBySchoolIds schoolList=1
 *   node examples/sign-headers.mjs POST /bath/valve/open '{"typeId":1,"machineId":"..."}'
 *
 * 输出：X-Sid / X-Sign / X-Ghost 等，按需复制。
 */
import { xGhost, xSign, appQuery, KEYSETS } from '../signer.mjs';

const [method = 'GET', path = '/', ...rest] = process.argv.slice(2);

if (!path || path === '/') {
  console.log(`用法:
  node examples/sign-headers.mjs GET  /path key=value key2=value2
  node examples/sign-headers.mjs POST /path '<json>'`);
  process.exit(0);
}

let payload;
if (method.toUpperCase() === 'GET') {
  const params = {};
  for (const kv of rest) {
    const i = kv.indexOf('=');
    if (i > 0) params[kv.slice(0, i)] = kv.slice(i + 1);
  }
  payload = appQuery(params);
} else {
  payload = rest.join(' ');
}

const headers = {
  'content-type': 'application/json',
  'X-Sid': KEYSETS.prod.v3_sid,
  'X-Sign': xSign(payload),
  'X-Ghost': xGhost(),
  'X-Product-Ver': '3.16.1#?345',
  'X-Mobile-Info': '1#?iPhone#?iOS 17',
  'X-clientType': '4',
};

console.log('payload:', payload);
console.log();
for (const [k, v] of Object.entries(headers)) console.log(`${k}: ${v}`);
console.log();
console.log('curl 片段:');
console.log(
  Object.entries(headers).map(([k, v]) => `  -H "${k}: ${v}"`).join(' \\\n'),
);
