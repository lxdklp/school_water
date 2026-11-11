/**
 * 登录态缓存 —— 避免反复登录触发风控
 *
 * 存的是服务端下发的 token（Set-Cookie 里的 tokenInfo），不是密码。
 * 文件权限 600，只读写当前用户。删掉该文件即退出登录。
 */
import { readFileSync, writeFileSync, chmodSync, existsSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
export const SESSION_FILE = join(HERE, '.session.json');

/** @returns {{token?:string, baseUrl?:string, studentId?:string, schoolName?:string, savedAt?:string}|null} */
export function loadSession() {
  try {
    if (!existsSync(SESSION_FILE)) return null;
    const j = JSON.parse(readFileSync(SESSION_FILE, 'utf8'));
    if (!j || typeof j.token !== 'string' || !j.token) return null;
    return j;
  } catch {
    return null;
  }
}

export function saveSession(obj) {
  const data = {
    token: obj.token,
    baseUrl: obj.baseUrl || '',
    studentId: obj.studentId || '',
    schoolName: obj.schoolName || '',
    savedAt: new Date().toISOString(),
  };
  writeFileSync(SESSION_FILE, JSON.stringify(data, null, 2), { mode: 0o600 });
  try { chmodSync(SESSION_FILE, 0o600); } catch { /* 忽略 */ }
  return data;
}

export function clearSession() {
  try { if (existsSync(SESSION_FILE)) unlinkSync(SESSION_FILE); } catch { /* 忽略 */ }
}

/** 缓存年龄（小时）；无效返回 Infinity */
export function sessionAgeHours(sess) {
  if (!sess?.savedAt) return Infinity;
  const t = Date.parse(sess.savedAt);
  if (Number.isNaN(t)) return Infinity;
  return (Date.now() - t) / 36e5;
}
