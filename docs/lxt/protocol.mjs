/**
 * 设备帧协议解码 —— 对应 app 的 util/nb.js (resolveData / dealScanCode)
 *
 * 二维码结构: 12 位 machineMac + "A5" 开头的设备帧
 * A5 帧结构 : "A5" + rns3(2) + rns2(2) + 若干 (字节-170)^rns2^rns3 编码的字段 + 校验(2)
 * 解码字段  : rns1, rns0, cmd, type, version, way, status, data
 * data 前 16 位 = machineId, 接着 8 位 = machineRandom(设备密码因子)
 */

/** 单字节解码: (byte - 170) [负则+256] ^ rns2 ^ rns3 */
export function decodeByte(hex, rns2, rns3) {
  let a = parseInt(hex, 16) - 170;
  if (Number.isNaN(a)) throw new Error('非设备数据(解码溢出)');
  if (a < 0) a += 256;
  a = a ^ parseInt(rns2, 16) ^ parseInt(rns3, 16);
  return (a & 0xff).toString(16).toUpperCase().padStart(2, '0');
}

/** A5 帧解析 */
export function resolveData(raw) {
  const t = String(raw).toUpperCase();
  if (t.length < 24) throw new Error(`帧长度不足(${t.length}<24)`);
  const r = t.substr(4, t.length - 6);
  const rns3 = r.substr(0, 2);
  const rns2 = r.substr(2, 2);
  const dec = (off) => decodeByte(r.substr(off, 2), rns2, rns3);
  return {
    rns3,
    rns2,
    rns1: dec(4),
    rns0: dec(6),
    cmd: dec(8),
    type: dec(10),
    version: dec(12),
    way: dec(14),
    status: dec(16),
    data: r.substr(18),
    originalData: t,
  };
}

/** 二维码 → 机器参数 */
export function decodeQr(qr) {
  let body = String(qr).trim();
  if (/^https?:/i.test(body)) body = body.slice(body.lastIndexOf('?') + 1);
  if (body.length < 52) throw new Error(`二维码长度不足(${body.length}<52)`);

  const machineMac = body.substr(0, 12);
  const frame = body.substr(12);

  if (!/^A5/i.test(frame)) {
    return {
      machineMac: frame.substr(40, 12).toUpperCase() || machineMac,
      machineId: frame.substr(2, 8),
      machineData: frame.substr(0, 40),
      frame,
      legacy: true,
    };
  }

  const d = resolveData(frame);
  const ok = ['F0', 'F1'].includes(d.cmd) && ['01', '02', '03', '04', '05', '09'].includes(d.type);
  return {
    machineMac,
    machineId: d.data.substr(0, 16),
    machineRandom: d.data.substr(16, 8),
    machinetypeid: d.type,
    machinever: d.version,
    deviceVer: `${d.type},${d.version}`,
    stateinfo: d.status,
    recognized: ok,
    frame,
    decoded: d,
  };
}
