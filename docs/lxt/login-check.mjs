#!/usr/bin/env node
/**
 * 端到端登录自检 —— 在本地跑，密码从标准输入隐藏读取，不落盘、不进对话历史。
 *
 *   node login-check.mjs                 # 交互式
 *   node login-check.mjs --phone 138xxx  # 预填手机号
 *
 * 流程: 取图片验证码 → 存 captcha.png 并自动打开 → 输入验证码 → 登录
 *       → 成功后切到租户域名 → 拉一次个人信息(打码显示)
 */
import readline from 'node:readline';
import { writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { LxtClient } from './client.mjs';

function ask(question, { hidden = false } = {}) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
      terminal: true,
    });
    if (hidden) {
      const write = rl._writeToOutput.bind(rl);
      rl._writeToOutput = (str) => {
        // 只回显提示语，吞掉用户输入
        if (str.includes(question)) write(str);
      };
    }
    rl.question(question, (answer) => {
      rl.close();
      if (hidden) process.stdout.write('\n');
      resolve(answer.trim());
    });
  });
}

const mask = (v) => {
  const s = String(v ?? '');
  if (s.length <= 2) return '**';
  return s[0] + '*'.repeat(Math.max(1, s.length - 3)) + s.slice(-2);
};

const argPhone = (() => {
  const i = process.argv.indexOf('--phone');
  return i > -1 ? process.argv[i + 1] : '';
})();

const phone = argPhone || (await ask('手机号/账号: '));
if (!phone) {
  console.error('账号为空');
  process.exit(1);
}
if (!/^1\d{10}$/.test(phone)) {
  console.warn('提示: 不是 11 位手机号，将按「账号」提交（部分学校支持学号登录）');
}

const client = new LxtClient();

// 1) 图片验证码
const cap = await client.getCaptcha(phone);
if (cap.Code !== 0 || typeof cap.Data !== 'string') {
  console.error('取验证码失败:', JSON.stringify(cap));
  process.exit(1);
}
const b64 = cap.Data.replace(/^data:image\/\w+;base64,/, '');
writeFileSync('captcha.png', Buffer.from(b64, 'base64'));
console.log('验证码已保存: captcha.png（已尝试自动打开）');
try {
  spawn('open', ['captcha.png'], { stdio: 'ignore', detached: true }).unref();
} catch {
  /* 非 macOS 就手动打开 */
}

// 2) 输入验证码 + 密码
const code = await ask('图片验证码: ');
const password = await ask('密码(输入不回显): ', { hidden: true });
if (!code || !password) {
  console.error('验证码或密码为空');
  process.exit(1);
}

// 3) 登录
const r = await client.login(phone, password, code);
console.log('\n登录返回:', JSON.stringify({ Code: r.Code, Message: r.Message }));

if (r.Code !== 0) {
  console.log('未登录成功，无需继续。');
  process.exit(r.Code === 0 ? 0 : 2);
}

const data = r.Data || {};
console.log('studentId :', mask(data.studentId));
console.log('租户域名  :', data.url || '(未返回)');
console.log('token     :', client.token ? `已获取(len=${client.token.length})` : '(未拿到)');

// 4) 切到租户域名，验证鉴权接口
if (data.url) client.baseUrl = data.url;
const me = await client.getUserInfo();
console.log('getUserInfo:', JSON.stringify({
  Code: me.Code,
  Message: me.Message,
  studentName: mask(me.Data?.studentName ?? me.Data?.studentMobile),
}));

console.log('\n结论:', me.Code === 0 ? '✅ 登录 + 鉴权接口全链路通过' : '⚠️ 登录成功但鉴权接口异常');
