// ═════════════════════════════════════════════════════════════════════════════
// EWT360 进度上报 - 自定义模式示例脚本 (QuickJS)
// ═════════════════════════════════════════════════════════════════════════════
// 行为链与普通模式 PlaybackEngine 完全对齐:
//   初始化 → record/submit → 起始 burst → 心跳循环(检测点/互动点/
//   周期持久化/真实进度轮询) → 结束序列 → 查询最终进度
//
// ── 默认配置 (脚本内硬编码, 不走 Flutter 配置读取, 与普通模式默认一致) ──
//   心跳间隔 60s / 倍速 1x / 完成阈值 0.8 / 真实进度轮询 60s /
//   周期进度持久化 300s (或每 5 心跳)
//
// ── 实现方式 ──
// 本示例尽量不依赖 Flutter/Dart 接口:
//   1. BFE/CLOG/DLOG/IPLOG 四通道由脚本独立实现 (sendRequest 绝对 URL 直连,
//      见「四通道遥测」段): 事件构造、CommonPackage、HMAC-SHA1 (BFE/CLOG/IPLOG)
//      与 MD5 (DLOG) 签名均为脚本内纯 JS 实现 (QuickJS 无 WebCrypto, 故手写)。
//   2. 回退逻辑脚本内实现: bfe → clog → dlog → iplog 逐级降级, 首个成功即返回。
//   3. 进度/日志/详情栏全部由脚本控制: updateProgress / log / updateDetail。
//   4. 业务 API (token/视频信息/record/认真度/互动点等) 用 sendRequest 封装。
//   仅保留宿主基础能力: sendRequest (HTTP 桥)、log、updateProgress、
//   updateDetail、sleep、parseJson; 滑块解算 solveCaptcha 依赖原生 ecaptcha。
//   Flutter 内置宿主函数 (sendHeartbeat 等) 仍可调用, 但本示例不依赖。
//
// ── 可用字段 ──
//   account: userId/schoolId/account/displayName/schoolName/provinceCode/
//            mobile/token/sessionId/secret/clientIp
//   task:    title/lessonId/videoId/taskId/contentType/schoolId/duration/subjectName
//
// ── 宿主函数速查 ──
//   基础:   log(msg, level?) / updateProgress(ratio, message?) /
//           sendRequest({url,method,headers,body,query,timeout}) /
//           updateDetail({...详情字段}) / sleep(ms) / parseJson(str)
//   可选:   solveCaptcha() (滑块解算, 原生 ecaptcha)
//   未使用: sendHeartbeat / initVideo / performFocusCheck / doInteractivePoint
//           / persistProgress / queryProgress / startPlayback 等内置宿主
//
// ── 约定 ──
//   定义 async function main() 即可, 宿主自动调用 (不要自己调用 main())。
//   脚本中勿写无界死循环 (QuickJS 无超时中断)。
// ═════════════════════════════════════════════════════════════════════════════

// ═════════════════════════════════════════════════════════════════════════════
// 零、纯 JS 加密库 (SHA-1 / HMAC-SHA1 / MD5)
//    QuickJS 无 WebCrypto, 为不依赖 Flutter 加密接口, 手写标准实现。
// ═════════════════════════════════════════════════════════════════════════════

/// UTF-8 字符串 → 字节数组
function utf8Bytes(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.charCodeAt(i);
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code >= 0xd800 && code <= 0xdbff) {
      const next = str.charCodeAt(++i);
      const cp = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
      out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
          0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f));
    }
  }
  return out;
}

/// 32 位整数数组 → 大端字节数组
function wordsToBytes(words) {
  const out = [];
  for (let i = 0; i < words.length; i++) {
    out.push((words[i] >>> 24) & 0xff, (words[i] >>> 16) & 0xff,
        (words[i] >>> 8) & 0xff, words[i] & 0xff);
  }
  return out;
}

/// 字节数组 → 小写 hex
function bytesToHex(bytes) {
  const hex = '0123456789abcdef';
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    s += hex[(bytes[i] >>> 4) & 0xf] + hex[bytes[i] & 0xf];
  }
  return s;
}

/// SHA-1: 输入字节数组, 返回 20 字节摘要
function sha1Bytes(bytes) {
  const bitLen = bytes.length * 8;
  const msg = bytes.slice();
  msg.push(0x80);
  while (msg.length % 64 !== 56) msg.push(0);
  // 64 位长度 (高 32 位在前)
  const hi = Math.floor(bitLen / 0x100000000) >>> 0;
  const lo = (bitLen >>> 0);
  msg.push((hi >>> 24) & 0xff, (hi >>> 16) & 0xff, (hi >>> 8) & 0xff, hi & 0xff);
  msg.push((lo >>> 24) & 0xff, (lo >>> 16) & 0xff, (lo >>> 8) & 0xff, lo & 0xff);

  let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe,
      h3 = 0x10325476, h4 = 0xc3d2e1f0;
  const w = new Array(80);
  for (let i = 0; i < msg.length; i += 64) {
    for (let j = 0; j < 16; j++) {
      const o = i + j * 4;
      w[j] = ((msg[o] << 24) | (msg[o + 1] << 16) | (msg[o + 2] << 8) |
          msg[o + 3]) >>> 0;
    }
    for (let j = 16; j < 80; j++) {
      w[j] = ((w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16]) << 1 |
          (w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16]) >>> 31) >>> 0;
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4;
    for (let j = 0; j < 80; j++) {
      let f, k;
      if (j < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
      else if (j < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
      else if (j < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
      else { f = b ^ c ^ d; k = 0xca62c1d6; }
      const temp = (((a << 5) | (a >>> 27)) + f + e + k + w[j]) >>> 0;
      e = d; d = c; c = ((b << 30) | (b >>> 2)) >>> 0; b = a; a = temp;
    }
    h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0; h4 = (h4 + e) >>> 0;
  }
  return wordsToBytes([h0, h1, h2, h3, h4]);
}

/// HMAC-SHA1: 返回 40 位小写 hex (对齐 BfeSigner)
function hmacSha1Hex(secret, message) {
  const keyBytes = utf8Bytes(secret);
  let key = keyBytes.slice();
  if (key.length > 64) key = sha1Bytes(key);
  while (key.length < 64) key.push(0);
  const ipad = key.map(function (b) { return b ^ 0x36; });
  const opad = key.map(function (b) { return b ^ 0x5c; });
  const inner = sha1Bytes(ipad.concat(utf8Bytes(message)));
  const outer = sha1Bytes(opad.concat(inner));
  return bytesToHex(outer);
}

/// MD5: 输入字节数组, 返回 32 位小写 hex (对齐 DlogSigner)
///
/// 经典实现 (Blueimp 算法核心, 经验证: abc/空串/fox 向量全部正确)。
function md5HexBytes(bytes) {
  // 字节数组 → 32 位小端字数组
  const words = [];
  for (let i = 0; i < bytes.length; i++) {
    words[i >> 2] = (words[i >> 2] || 0) | ((bytes[i] & 0xff) << ((i % 4) * 8));
  }
  const len = bytes.length * 8;

  function safeAdd(x, y) {
    var lsw = (x & 0xffff) + (y & 0xffff);
    var msw = (x >> 16) + (y >> 16) + (lsw >> 16);
    return (msw << 16) | (lsw & 0xffff);
  }
  function bitRotateLeft(num, cnt) { return (num << cnt) | (num >>> (32 - cnt)); }
  function md5cmn(q, a, b, x, s, t) {
    return safeAdd(bitRotateLeft(safeAdd(safeAdd(a, q), safeAdd(x, t)), s), b);
  }
  function md5ff(a, b, c, d, x, s, t) { return md5cmn((b & c) | (~b & d), a, b, x, s, t); }
  function md5gg(a, b, c, d, x, s, t) { return md5cmn((b & d) | (c & ~d), a, b, x, s, t); }
  function md5hh(a, b, c, d, x, s, t) { return md5cmn(b ^ c ^ d, a, b, x, s, t); }
  function md5ii(a, b, c, d, x, s, t) { return md5cmn(c ^ (b | ~d), a, b, x, s, t); }

  function binlMD5(x, l) {
    x[l >> 5] |= 0x80 << (l % 32);
    x[(((l + 64) >>> 9) << 4) + 14] = l;
    var a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
    for (var i = 0; i < x.length; i += 16) {
      var olda = a, oldb = b, oldc = c, oldd = d;
      a = md5ff(a, b, c, d, x[i], 7, -680876936);
      d = md5ff(d, a, b, c, x[i + 1], 12, -389564586);
      c = md5ff(c, d, a, b, x[i + 2], 17, 606105819);
      b = md5ff(b, c, d, a, x[i + 3], 22, -1044525330);
      a = md5ff(a, b, c, d, x[i + 4], 7, -176418897);
      d = md5ff(d, a, b, c, x[i + 5], 12, 1200080426);
      c = md5ff(c, d, a, b, x[i + 6], 17, -1473231341);
      b = md5ff(b, c, d, a, x[i + 7], 22, -45705983);
      a = md5ff(a, b, c, d, x[i + 8], 7, 1770035416);
      d = md5ff(d, a, b, c, x[i + 9], 12, -1958414417);
      c = md5ff(c, d, a, b, x[i + 10], 17, -42063);
      b = md5ff(b, c, d, a, x[i + 11], 22, -1990404162);
      a = md5ff(a, b, c, d, x[i + 12], 7, 1804603682);
      d = md5ff(d, a, b, c, x[i + 13], 12, -40341101);
      c = md5ff(c, d, a, b, x[i + 14], 17, -1502002290);
      b = md5ff(b, c, d, a, x[i + 15], 22, 1236535329);
      a = md5gg(a, b, c, d, x[i + 1], 5, -165796510);
      d = md5gg(d, a, b, c, x[i + 6], 9, -1069501632);
      c = md5gg(c, d, a, b, x[i + 11], 14, 643717713);
      b = md5gg(b, c, d, a, x[i], 20, -373897302);
      a = md5gg(a, b, c, d, x[i + 5], 5, -701558691);
      d = md5gg(d, a, b, c, x[i + 10], 9, 38016083);
      c = md5gg(c, d, a, b, x[i + 15], 14, -660478335);
      b = md5gg(b, c, d, a, x[i + 4], 20, -405537848);
      a = md5gg(a, b, c, d, x[i + 9], 5, 568446438);
      d = md5gg(d, a, b, c, x[i + 14], 9, -1019803690);
      c = md5gg(c, d, a, b, x[i + 3], 14, -187363961);
      b = md5gg(b, c, d, a, x[i + 8], 20, 1163531501);
      a = md5gg(a, b, c, d, x[i + 13], 5, -1444681467);
      d = md5gg(d, a, b, c, x[i + 2], 9, -51403784);
      c = md5gg(c, d, a, b, x[i + 7], 14, 1735328473);
      b = md5gg(b, c, d, a, x[i + 12], 20, -1926607734);
      a = md5hh(a, b, c, d, x[i + 5], 4, -378558);
      d = md5hh(d, a, b, c, x[i + 8], 11, -2022574463);
      c = md5hh(c, d, a, b, x[i + 11], 16, 1839030562);
      b = md5hh(b, c, d, a, x[i + 14], 23, -35309556);
      a = md5hh(a, b, c, d, x[i + 1], 4, -1530992060);
      d = md5hh(d, a, b, c, x[i + 4], 11, 1272893353);
      c = md5hh(c, d, a, b, x[i + 7], 16, -155497632);
      b = md5hh(b, c, d, a, x[i + 10], 23, -1094730640);
      a = md5hh(a, b, c, d, x[i + 13], 4, 681279174);
      d = md5hh(d, a, b, c, x[i], 11, -358537222);
      c = md5hh(c, d, a, b, x[i + 3], 16, -722521979);
      b = md5hh(b, c, d, a, x[i + 6], 23, 76029189);
      a = md5hh(a, b, c, d, x[i + 9], 4, -640364487);
      d = md5hh(d, a, b, c, x[i + 12], 11, -421815835);
      c = md5hh(c, d, a, b, x[i + 15], 16, 530742520);
      b = md5hh(b, c, d, a, x[i + 2], 23, -995338651);
      a = md5ii(a, b, c, d, x[i], 6, -198630844);
      d = md5ii(d, a, b, c, x[i + 7], 10, 1126891415);
      c = md5ii(c, d, a, b, x[i + 14], 15, -1416354905);
      b = md5ii(b, c, d, a, x[i + 5], 21, -57434055);
      a = md5ii(a, b, c, d, x[i + 12], 6, 1700485571);
      d = md5ii(d, a, b, c, x[i + 3], 10, -1894986606);
      c = md5ii(c, d, a, b, x[i + 10], 15, -1051523);
      b = md5ii(b, c, d, a, x[i + 1], 21, -2054922799);
      a = md5ii(a, b, c, d, x[i + 8], 6, 1873313359);
      d = md5ii(d, a, b, c, x[i + 15], 10, -30611744);
      c = md5ii(c, d, a, b, x[i + 6], 15, -1560198380);
      b = md5ii(b, c, d, a, x[i + 13], 21, 1309151649);
      a = md5ii(a, b, c, d, x[i + 4], 6, -145523070);
      d = md5ii(d, a, b, c, x[i + 11], 10, -1120210379);
      c = md5ii(c, d, a, b, x[i + 2], 15, 718787259);
      b = md5ii(b, c, d, a, x[i + 9], 21, -343485551);
      a = safeAdd(a, olda); b = safeAdd(b, oldb);
      c = safeAdd(c, oldc); d = safeAdd(d, oldd);
    }
    return [a, b, c, d];
  }

  const result = binlMD5(words, len);
  const hexTab = '0123456789abcdef';
  let str = '';
  for (let i = 0; i < result.length * 4; i++) {
    str += hexTab.charAt((result[i >> 2] >> ((i % 4) * 8 + 4)) & 0xf) +
        hexTab.charAt((result[i >> 2] >> ((i % 4) * 8)) & 0xf);
  }
  return str;
}

/// MD5: 字符串 → 32 位小写 hex
function md5Hex(str) { return md5HexBytes(utf8Bytes(str)); }

// ═════════════════════════════════════════════════════════════════════════════
// 一、会话工具 (时钟同步 / uuid)
// ═════════════════════════════════════════════════════════════════════════════

/// 服务器时间同步 (对齐 ServerClock: 用响应 data.ts 校准本地时钟)
let _clockDiffMs = 0; // server_ts - local_ts
let _clockSyncCount = 0;
let _clockLastTs = 0; // 最后一次同步的服务器时间戳 (ms)
function clockNow() {
  return Date.now() + _clockDiffMs;
}
function clockSync(serverTsMs) {
  if (serverTsMs == null || serverTsMs <= 0) return;
  _clockDiffMs = serverTsMs - Date.now();
  _clockSyncCount++;
  _clockLastTs = serverTsMs;
}
function clockDiffMs() { return _clockDiffMs; }
function clockSyncCount() { return _clockSyncCount; }
function clockLastTs() { return _clockLastTs; }

/// 会话级 beginTs (一次脚本执行内固定, 对齐引擎 _beginTs)
const _sessionBeginTs = clockNow();

/// 会话 UUID 前缀 (8 位随机, 对齐引擎 _genUuidPrefix)
let _uuidSeq = 0;
const _uuidPrefix = (function () {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  let s = '';
  for (let i = 0; i < 8; i++) {
    s += chars[Math.floor(Math.random() * chars.length)];
  }
  return s;
})();
function nextUuid() {
  _uuidSeq++;
  return _uuidPrefix + '_' + _uuidSeq;
}

// ═════════════════════════════════════════════════════════════════════════════
// 二、四通道遥测 (BFE / CLOG / DLOG / IPLOG 独立实现 + 回退)
//    对齐 TelemetryRemoteDataSource.sendCollectBatch
// ═════════════════════════════════════════════════════════════════════════════

const _kMonitorDomain = 'https://bfe.ewt360.com';
const _kClogDomain = 'https://clog.ewt360.com';
const _kDlogDomain = 'https://dlog.ewt360.com';
const _kCollectPath = '/monitor/web/collect/batch';
const _kDlogSignKey = 'eo^nye1j#!wt2%v)';

/// CommonPackage (对齐 _buildCommon)
function buildCommon() {
  return {
    userid: Number(account.userId) || 0,
    ip: account.clientIp || '114.114.114.114',
    os: 'Windows',
    resolution: '1920*1080',
    mstid: account.token || '',
    browser: 'Chrome',
    browser_ver: account.userAgent || '',
    playerType: 1,
    sdkVersion: account.sdkVersion || '3.0.37',
    videoBizCode: '1013',
    memberProvinceCode: account.provinceCode || '',
    schoolId: task.schoolId || '',
    schoolProvinceCode: account.provinceCode || '',
  };
}

/// 单事件构造 (对齐 _buildCollectEvent)
function buildEvent(opts) {
  const status = (opts.action === 3 || opts.action === 4) ? 3 : 1;
  return {
    lesson_id: opts.lessonId,
    course_id: opts.courseId,
    stay_time: opts.stayTime,
    media_time: opts.mediaTime,
    status: status,
    begin_time: opts.beginTs,
    report_time: opts.reportTs,
    point_time_id: Math.min(opts.pointNum, opts.pti),
    point_time: 1000 * 60,
    point_num: opts.pointNum,
    video_type: opts.videoType,
    speed: opts.speed || 1.0,
    quality: '高清',
    action: opts.action,
    fallback: opts.fallback,
    uuid: opts.uuid,
  };
}

/// BFE/CLOG/IPLOG 签名 (HMAC-SHA1, 对齐 BfeSigner.signCollect)
function signBfe(opts) {
  const sigStr = 'action=' + opts.action + '&duration=' + opts.duration +
      '&mstid=' + (account.token || '') +
      '&signatureMethod=HMAC-SHA1&signatureVersion=1.0' +
      '&timestamp=' + opts.timestamp + '&version=2022-08-02';
  return hmacSha1Hex(account.secret || '', sigStr);
}

/// BFE 请求头 (对齐 _collectHeaders)
function collectHeaders() {
  return {
    'access-control-allow-origin': '*',
    'content-type': 'application/json',
    'origin': 'https://teacher.ewt360.com',
    'referer': 'https://teacher.ewt360.com/',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    'sec-fetch-dest': 'empty',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'same-site',
    'user-agent': account.userAgent || '',
    'Token': account.token || '',
    'X-Bfe-Session-Id': account.sessionId || '',
  };
}

/// 发送 BFE 格式请求到指定域名 (bfe/clog/iplog 共用; DLOG 走独立 MD5 格式)
async function sendBfeLike(hostUrl, fallback, opts) {
  const reportTs = clockNow();
  const event = buildEvent({
    lessonId: opts.lessonId, courseId: opts.courseId,
    stayTime: opts.stayTime, mediaTime: opts.mediaTime,
    action: opts.action, beginTs: opts.beginTs, reportTs: reportTs,
    pti: opts.pti, pointNum: opts.pointNum, videoType: opts.videoType,
    speed: opts.speed, fallback: fallback, uuid: opts.uuid,
  });
  const common = buildCommon();
  const signature = signBfe({
    action: opts.action, duration: opts.stayTime,
    timestamp: reportTs,
  });
  const payload = {
    CommonPackage: common,
    EventPackage: [event],
    signature: signature,
    sn: 'ewt_web_video_detail',
    _: reportTs,
  };
  const query = {
    TrVideoBizCode: '1013',
    TrFallback: fallback,
    TrUserId: account.userId || '',
    TrLessonId: opts.lessonId,
    TrUuId: opts.uuid,
    sdkVersion: account.sdkVersion || '3.0.37',
    _: reportTs,
  };
  const r = await sendRequest({
    url: hostUrl + _kCollectPath,
    method: 'POST',
    query: query,
    headers: collectHeaders(),
    body: payload,
  });
  // 同步服务器时间 (响应 data.ts)
  const data = r && r.data;
  if (data && typeof data === 'object' && data.ts != null) {
    clockSync(Number(data.ts));
  }
  const code = r && r.data && r.data.code != null
      ? Number(r.data.code) : (r.status ? r.status : 0);
  const ok = (r && r.ok) && (code === 200 || code === 0 && r.status === 200);
  return {
    host: hostUrl === _kMonitorDomain ? 'bfe' : (hostUrl === _kClogDomain ? 'clog' : 'iplog'),
    fallback: fallback,
    ok: ok,
    code: code,
    status: r ? r.status : 0,
    msg: (r && r.data && r.data.msg) ? r.data.msg : (r ? r.msg : ''),
    error: ok ? null : ((r && r.error) ? r.error : ('http-' + (r ? r.status : 0))),
  };
}

/// DLOG 上报 (form-urlencoded + MD5 签名, 对齐 _sendDlog)
async function sendDlog(opts) {
  const reportTs = clockNow();
  const event = buildEvent({
    lessonId: opts.lessonId, courseId: opts.courseId,
    stayTime: opts.stayTime, mediaTime: opts.mediaTime,
    action: opts.action, beginTs: opts.beginTs, reportTs: reportTs,
    pti: opts.pti, pointNum: opts.pointNum, videoType: opts.videoType,
    speed: opts.speed, fallback: 1, uuid: opts.uuid,
  });
  const logJson = JSON.stringify({
    CommonPackage: buildCommon(),
    EventPackage: [event],
  });
  const sign = md5Hex('log=' + logJson + '&key=' + _kDlogSignKey);
  const formBody = 'sn=' + encodeURIComponent('ewt_web_video_detail') +
      '&log=' + encodeURIComponent(logJson) +
      '&ts=' + reportTs +
      '&sign=' + sign;
  const r = await sendRequest({
    url: _kDlogDomain + '/',
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'origin': 'https://teacher.ewt360.com',
      'referer': 'https://teacher.ewt360.com/',
      'user-agent': account.userAgent || '',
    },
    body: formBody,
  });
  const ok = r && r.ok && r.status === 200;
  return {
    host: 'dlog', fallback: 1, ok: ok,
    code: ok ? 200 : 0, status: r ? r.status : 0,
    msg: ok ? 'ok' : ('http-' + (r ? r.status : 0)),
    error: ok ? null : ('DLOG HTTP ' + (r ? r.status : 0)),
  };
}

/// IPLOG 直连 (fallbackIP 直连)
///
/// 使用动态获取的 fallbackIP (getPlayerGlobalConf.globalInfo.fallbackIP)。
/// 优先使用宿主注入的 `account.fallbackIP` (会话建立时已取), 未注入时才自取。
let _iplogFallbackIP = '';
async function apiGetFallbackIp() {
  if (_iplogFallbackIP) return _iplogFallbackIP;
  // 宿主注入优先 (ProgressReportService 会话建立时已从 getPlayerGlobalConf 取到)
  const injected = account.fallbackIP;
  if (injected && String(injected).trim()) {
    _iplogFallbackIP = String(injected).trim();
    return _iplogFallbackIP;
  }
  try {
    const r = await sendRequest({
      url: '/api/videoplayerprod/videoplayer/getPlayerGlobalConf',
      method: 'GET',
      query: { videoBizCode: '1013', sdkVersion: account.sdkVersion || '3.0.37' },
    });
    // 响应结构: {ok, code, msg, data:{globalInfo:{sessionId,secret,clientIp,fallbackIP,...}}}
    const d = (r && r.data) || {};
    const gi = d.globalInfo || (d.data && d.data.globalInfo) || d;
    const ip = gi.fallbackIP;
    if (ip && String(ip).trim()) _iplogFallbackIP = String(ip).trim();
  } catch (_) {
    // 取不到则保持空 (sendIplog 将跳过 IPLOG 通道)
  }
  return _iplogFallbackIP;
}

async function sendIplog(opts) {
  // 必须取到 fallbackIP: 固定域名 iplog.ewt360.com DNS 解析失败, 不可用。
  await apiGetFallbackIp();
  if (!_iplogFallbackIP) {
    return {
      host: 'iplog', fallback: 1, ok: false, code: 0, status: 0,
      msg: 'no-fallbackIP', error: '缺少 fallbackIP, 跳过 IPLOG 直连',
    };
  }
  const target = 'http://' + _iplogFallbackIP + '/';
  return sendBfeLike(target, 1, opts);
}

/// 四通道回退 (对齐 sendCollectBatch 降级链 bfe→clog→dlog→iplog)
/// 首个成功即返回; 全部失败返回最后结果。
/// [useBackup] 时跳过 bfe 直接走指定通道 (clog/dlog/iplog)。
async function collectWithFallback(opts) {
  const useBackup = opts.useBackup === true;
  const backend = opts.reportBackend || 'clog';
  const base = {
    lessonId: opts.lessonId, courseId: opts.courseId,
    stayTime: opts.stayTime, mediaTime: opts.mediaTime,
    action: opts.action, beginTs: _sessionBeginTs,
    pti: opts.pti, pointNum: opts.pointNum,
    videoType: opts.videoType, speed: opts.speed,
    uuid: nextUuid(),
  };

  // 备用通道直选
  if (useBackup) {
    if (backend === 'iplog') {
      const ip = await apiGetFallbackIp();
      return sendIplog(Object.assign({}, base, {}));
    }
    if (backend === 'clog') {
      const r = await sendBfeLike(_kClogDomain, 1, base);
      if (r.ok) return r;
      const d = await sendDlog(base);
      if (d.ok) return d;
      return sendIplog(base);
    }
    if (backend === 'dlog') {
      const r = await sendDlog(base);
      if (r.ok) return r;
      return sendIplog(base);
    }
  }

  // 默认: bfe → clog → dlog → iplog (标准降级链, 与引擎 sendCollectBatch 一致)
  // ⚠️ 不要因 fallbackIP 存在就优先 IPLOG 直连: 实测 IPLOG 端点对常规心跳
  // (stayMs=60000) 返回 400, 而 bfe 主通道正常 (courseId 正确时心跳可 200)。
  // IPLOG 仅作为最后兜底 (sendIplog 内部会自取 fallbackIP 直连)。
  const stepLog = opts.verbose ? [] : null;
  const steps = [
    { name: 'bfe', fn: () => sendBfeLike(_kMonitorDomain, 0, base) },
    { name: 'clog', fn: () => sendBfeLike(_kClogDomain, 1, base) },
    { name: 'dlog', fn: () => sendDlog(base) },
    { name: 'iplog', fn: () => sendIplog(base) },
  ];
  for (let i = 0; i < steps.length; i++) {
    const st = steps[i];
    const r = await st.fn();
    if (r.ok) return r;
    if (stepLog) {
      stepLog.push(st.name + '=' + r.code + (r.error ? ':' + String(r.error).substring(0, 80) : ''));
      log('  [collect ' + st.name + '] code=' + r.code +
          (r.error ? ' err=' + String(r.error).substring(0, 120) : ''),
          'warning');
    }
  }
  // 全部失败: 附加各通道失败摘要
  const last = stepLog ? stepLog.join('; ') : '';
  const result = await (async () => { return { ok: false, host: 'all', code: 0, error: last }; })();
  return result;
}

// ═════════════════════════════════════════════════════════════════════════════
// 三、业务 API 封装 (sendRequest, 对齐 Flutter PlayerRemoteDataSource)
// ═════════════════════════════════════════════════════════════════════════════

/// 获取播放 token (POST /api/homeworkprod/player/getPlayerToken)
async function apiGetPlayerToken(schoolId, lessonId, contentType) {
  const r = await sendRequest({
    url: '/api/homeworkprod/player/getPlayerToken',
    method: 'POST',
    body: {
      schoolId: Number(schoolId) || schoolId,
      lessonId: Number(lessonId) || lessonId,
      type: 1,
      contentType: contentType || 1,
      videoBizCode: '1013',
    },
  });
  if (!r.ok || r.code !== '200') {
    log('getPlayerToken 失败: ' + (r.msg || r.error), 'warning');
    return '';
  }
  const d = r.data;
  if (typeof d === 'string') return d;
  if (d && typeof d === 'object') {
    return d.videoToken || d.token || '';
  }
  return '';
}

/// 获取外部视频信息 (GET /api/videoplayerprod/videoplayer/getExternalVideoInfo)
async function apiGetVideoInfo(lessonId, videoToken) {
  const r = await sendRequest({
    url: '/api/videoplayerprod/videoplayer/getExternalVideoInfo',
    method: 'GET',
    query: {
      videoBizCode: '1013',
      lessonId: lessonId,
      videoToken: videoToken,
      sdkVersion: account.sdkVersion || '3.0.37',
    },
  });
  return r.ok && r.code === '200' ? (r.data || {}) : {};
}

/// 查询黑名单状态 (GET /api/homeworkprod/homework/student/getVideodp)
async function apiGetVideodp() {
  const r = await sendRequest({
    url: '/api/homeworkprod/homework/student/getVideodp',
    method: 'GET',
  });
  if (!r.ok || r.code !== '200') return false;
  const d = r.data;
  if (typeof d === 'boolean') return d;
  if (typeof d === 'string') return d.toLowerCase() === 'true';
  return false;
}

/// 获取认真度检测降级配置 (GET /api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig)
async function apiGetSeriousCheckConfig(schoolId, videoType) {
  const r = await sendRequest({
    url: '/api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig',
    method: 'GET',
    query: { schoolId: schoolId, videoType: videoType || 1 },
  });
  return r.ok && r.code === '200' ? (r.data || {}) : {};
}

/// 获取课时详情 (POST /api/homeworkprod/player/getLessonDetailV2)
async function apiGetLessonDetail() {
  const r = await sendRequest({
    url: '/api/homeworkprod/player/getLessonDetailV2',
    method: 'POST',
    body: {
      schoolId: task.schoolId,
      lessonId: task.lessonId,
      homeworkId: task.homeworkId,
    },
  });
  return r.ok && r.code === '200' ? (r.data || {}) : {};
}

/// record/submit 开始观看 (POST /api/studyprod/course/lesson/record/submit)
///
/// ⚠️ 请求体必须是 `recordList` 数组 (对齐参考实现 ewt_client.py submit_lesson_record):
///   [{lessonId, courseId, homeworkId, studyTime, videoPlayTime, ratio, schoolId}]
/// 旧写法 {courseId, lessonId, processTime, finished} 会被服务端拒绝:
///   「参数不合法: recordList: 看课记录列表不能为空」。
/// 对齐 Flutter submitRecord (fire-and-forget, 不校验业务 code)。
async function apiStartPlayback(courseId, lessonId, processTimeMs) {
  const studyTime = processTimeMs > 0 ? Math.round(processTimeMs / 1000) : 0;
  const r = await sendRequest({
    url: '/api/studyprod/course/lesson/record/submit',
    method: 'POST',
    body: {
      recordList: [{
        lessonId: Number(lessonId) || lessonId,
        courseId: Number(courseId) || courseId,
        homeworkId: Number(task.homeworkId) || 0,
        studyTime: studyTime,
        videoPlayTime: studyTime,
        ratio: 1.0,
        schoolId: Number(task.schoolId) || 0,
      }],
    },
  });
  if (!r.ok) {
    log('record/submit 请求失败: ' + (r.error || r.msg || ''), 'warning');
    return false;
  }
  if (r.code && r.code !== '200') {
    log('record/submit 业务码 ' + r.code + ' (不判失败, 对齐 fire-and-forget)', 'info');
  }
  return true;
}

/// 认真度/互动点上报 (POST addVideoss / addVideocss, 按黑名单选 URL)
async function apiSendVideoCheck(opts) {
  const url = opts.blacklisted
      ? '/api/homeworkprod/homework/student/addVideocss'
      : '/api/homeworkprod/homework/student/addVideoss';
  const body = {
    schoolId: Number(task.schoolId) || 0,
    homeworkId: Number(task.homeworkId) || 0,
    lessonId: task.lessonId,
    type: opts.type || 1,
    interactivePointId: opts.interactivePointId || null,
    platform: 1,
    seriousCheckResult: opts.seriousCheckResult || 0,
  };
  if (opts.captchaToken) body.captchaToken = opts.captchaToken;
  const r = await sendRequest({ url: url, method: 'POST', body: body });
  return r.ok && r.code === '200';
}

/// 获取互动配置详情 (GET /api/videoplayerprod/videoplayer/getInteractiveConfigDetail)
async function apiGetInteractiveConfigDetail(configId) {
  const r = await sendRequest({
    url: '/api/videoplayerprod/videoplayer/getInteractiveConfigDetail',
    method: 'GET',
    query: { interactiveConfigId: configId, videoBizCode: '1013' },
  });
  return r.ok && r.code === '200' ? (r.data || {}) : {};
}

/// 提交互动视频答案 (POST /api/videoplayerprod/videoplayer/submitAnswer)
async function apiSubmitInteractiveAnswer(opts) {
  const r = await sendRequest({
    url: '/api/videoplayerprod/videoplayer/submitAnswer',
    method: 'POST',
    body: {
      interactiveSceneId: opts.interactiveSceneId,
      questionId: opts.questionId,
      myAnswers: opts.myAnswers || [''],
      totalSeconds: 1,
      videoBizCode: '1013',
      lessonId: task.lessonId || '',
    },
  });
  return r.ok && r.code === '200' ? (r.data || {}) : {};
}

/// FM/板报直写完成 (POST /api/homeworkprod/homework/student/updateMission)
async function apiCompleteMission(contentType) {
  const r = await sendRequest({
    url: '/api/homeworkprod/homework/student/updateMission',
    method: 'POST',
    body: {
      schoolId: Number(task.schoolId) || 0,
      contentId: task.lessonId,
      contentType: contentType,
      percent: 1,
    },
  });
  return r.ok && r.code === '200';
}

/// 查询服务端真实进度 (0~1), 对齐引擎 _queryProgressRatio 双接口:
/// 1. refreshTaskProgressBatch (taskIds 数组 + schoolId, 响应 data 为数组)
/// 2. queryTaskProgress / taskProgressV1 兜底
async function apiQueryProgress() {
  if (!task.taskId) return null;

  // 1. refreshTaskProgressBatch (主): POST {taskIds:[taskId], schoolId}
  try {
    const r = await sendRequest({
      url: '/api/homeworkprod/student/homework/task/refreshTaskProgress',
      method: 'POST',
      body: {
        taskIds: [task.taskId],
        schoolId: task.schoolId || '',
      },
    });
    if (r.ok && r.code === '200') {
      const list = r.data;
      if (Array.isArray(list) && list.length > 0) {
        const item = list[0] || {};
        if (item.ratio != null) {
          const v = Number(item.ratio);
          if (!isNaN(v)) return Math.min(Math.max(v, 0), 1);
        }
        const fp = item.finishPercent != null ? item.finishPercent : item.percent;
        if (fp != null) {
          const v = Number(fp);
          if (!isNaN(v)) return Math.min(Math.max(v, 0), 1);
        }
      }
    }
  } catch (_) {}

  // 2. queryTaskProgress / taskProgressV1 兜底: POST {taskIds:[taskId], sourceType:2, schoolId}
  try {
    const body = {
      taskIds: [task.taskId],
      sourceType: 2,
    };
    if (task.schoolId) body.schoolId = task.schoolId;
    const r = await sendRequest({
      url: '/api/homeworkprod/homework/student/taskProgressV1',
      method: 'POST',
      body: body,
    });
    if (r.ok && r.code === '200') {
      const list = r.data;
      if (Array.isArray(list) && list.length > 0) {
        const item = list[0] || {};
        if (item.ratio != null) {
          const v = Number(item.ratio);
          if (!isNaN(v)) return Math.min(Math.max(v, 0), 1);
        }
        const fp = item.finishPercent != null ? item.finishPercent : item.percent;
        if (fp != null) {
          const v = Number(fp);
          if (!isNaN(v)) return Math.min(Math.max(v, 0), 1);
        }
      }
    }
  } catch (_) {}

  return null;
}

// ═════════════════════════════════════════════════════════════════════════════
// 四、主流程 (行为链与普通模式 PlaybackEngine 完全对齐)
//     进度/日志/详情栏全部由脚本控制
// ═════════════════════════════════════════════════════════════════════════════

async function main() {
  log('开始自定义上报: ' + task.title, 'info');
  log('账号: ' + account.displayName + ' (' + account.account + ')', 'info');

  // ── 脚本内过滤 (自定义模式不使用 Flutter 侧的课程类型/学科过滤) ──
  // 例 1: 只上报数学学科的视频类课程
  // if (task.contentType !== 1 && task.contentType !== 11) {
  //   log('跳过: 非视频类 contentType=' + task.contentType, 'warning');
  //   updateProgress(0, '跳过 (非视频类)');
  //   return;
  // }
  // if (task.subjectName && task.subjectName !== '数学') {
  //   log('跳过: 非数学学科 (' + task.subjectName + ')', 'warning');
  //   updateProgress(0, '跳过 (学科=' + task.subjectName + ')');
  //   return;
  // }

  // FM / 板报: 直写完成 (不走播放心跳)
  if (task.contentType === 3 || task.contentType === 5) {
    const ok = await apiCompleteMission(task.contentType);
    log('FM/板报直写: ' + (ok ? '成功' : '失败'), ok ? 'success' : 'error');
    if (ok) updateProgress(1.0, '完成');
    updateDetail({ progress: ok ? 1 : 0, message: ok ? 'FM/板报完成' : 'FM/板报失败' });
    return;
  }

  // 1. 初始化视频会话 (sendRequest 封装实现, 等价宿主 initVideo)
  const lessonId = task.lessonId;
  const schoolId = task.schoolId;
  const playerToken = await apiGetPlayerToken(schoolId, lessonId, task.contentType || 1);
  if (!playerToken) log('getPlayerToken 失败 (非致命, 继续)', 'warning');

  const evData = playerToken ? await apiGetVideoInfo(lessonId, playerToken) : {};
  let duration = Number(evData.duration) || 0;
  if (duration <= 0 && evData.videoList && evData.videoList.length > 0) {
    duration = Number(evData.videoList[0].duration) || 0;
  }
  if (duration <= 0) duration = Number(task.duration) || 0;
  if (duration <= 0) duration = 600;

  // 真实课程 ID (getLessonDetailV2.data.courseId, 对齐引擎 session.courseId)
  let courseId = task.videoId && task.videoId.length > 0 ? task.videoId : lessonId;
  if (task.homeworkId) {
    const detail = await apiGetLessonDetail();
    if (detail.courseId) courseId = String(detail.courseId);
  }
  log('课程: courseId=' + courseId, 'info');

  // 互动点配置 (interactiveInfo.interactiveConfigList)
  const interactiveConfigs = [];
  if (evData.interactiveInfo && evData.interactiveInfo.interactiveConfigList) {
    for (const c of evData.interactiveInfo.interactiveConfigList) {
      if (c && c.id != null) {
        interactiveConfigs.push({
          id: String(c.id),
          timePoint: Number(c.timePoint) || 0,
        });
      }
    }
  }
  const isInteractiveVideo = interactiveConfigs.length > 0;

  // 黑名单状态 + 认真度降级配置
  const isBlacklisted = await apiGetVideodp();
  const seriousCfg = await apiGetSeriousCheckConfig(schoolId,
      task.contentType === 11 ? 6 : 1);
  const isDowngrade = Number(seriousCfg.level || 0) > 0;

  log('视频: 时长=' + duration + 's, 黑名单=' + isBlacklisted +
      ', 互动点=' + interactiveConfigs.length + '个, ' +
      '认真度' + (isDowngrade ? '已降级' : '正常'), 'info');
  if (isBlacklisted) log('账号在黑名单 → 认真度检测走滑块型 (自动解算 ecaptcha)', 'warning');

  const total = duration;

  // ── 脚本逻辑默认参数 (与普通模式引擎完全一致, 硬编码) ──
  const pointNum = Math.max(1, Math.ceil(total / 60));
  const interval = 60;          // 心跳间隔 (秒) = 普通模式默认 60s
  const speed = 1.0;            // 倍速 = 普通模式默认 1x
  const completeRatio = 0.8;    // 完成阈值 = 普通模式默认 0.8
  const pollIntervalMs = 60000; // 真实进度轮询间隔 = 普通模式默认 60s
  const persistEverySec = 300;  // 周期进度持久化间隔 = 普通模式默认 300s
  const persistEveryHb = 5;     // 或每 5 个心跳持久化一次 (300s/60s)

  // 2. record/submit 开始观看
  const spOk = await apiStartPlayback(courseId, lessonId, 0);
  log('record/submit 开始观看: ' + (spOk ? 'ok' : '失败'), spOk ? 'info' : 'warning');

  // 3. 起始 burst (脚本自建四通道 collect: act=2,1,3,2)
  const bursts = [
    { action: 2, stayMs: 6 },
    { action: 1, stayMs: 0 },
    { action: 3, stayMs: 0 },
    { action: 2, stayMs: 0 },
  ];
  for (let i = 0; i < bursts.length; i++) {
    const b = bursts[i];
    const br = await collectWithFallback({
      lessonId: lessonId, courseId: courseId,
      action: b.action, stayTime: b.stayMs, mediaTime: b.stayMs,
      pti: i === 3 ? 1 : 0, pointNum: pointNum,
      videoType: task.contentType === 11 ? 6 : 1, speed: 1.0,
    });
    log('起始 burst [act=' + b.action + '] host=' + br.host +
        ' code=' + br.code + (br.error ? ' err=' + br.error : ''),
        br.ok ? 'info' : 'warning');
  }

  // 4. 心跳循环 (脚本自建四通道 collect + 检测点/互动点/持久化/轮询)
  const fullHb = Math.max(1, Math.ceil(pointNum / speed));
  let ptiFloat = 1.0;   // 起始 burst 后 (对齐引擎 _ptiFloat=1.0)
  let cpIdx = 0;
  let ipIdx = 0;
  let lastProgressPersist = 0;
  let lastProgressQueryTs = Date.now();
  let heartbeatOkCount = 0;
  let collectFailCount = 0;
  let focusDoneCount = 0;
  let interactiveDoneCount = 0;

  // 客户端认真度检测点生成 (对齐引擎 _generateVideoCheckPoints)
  const checkPoints = [];
  {
    const z = total;
    if (interactiveConfigs.length > 0) {
      if (interactiveConfigs.length < 3 && z > 480) {
        const lastTp = Math.ceil((interactiveConfigs[interactiveConfigs.length - 1].timePoint || 0) / 1000);
        const s = lastTp + 120;
        const o = Math.ceil(0.8 * z);
        if (s < o) {
          const count = z <= 900 ? (interactiveConfigs.length >= 2 ? 0 : 1) : (3 - interactiveConfigs.length);
          for (let k = 1; k <= count; k++) {
            checkPoints.push(Math.round(s + (o - s) * k / (count + 1)));
          }
        }
      }
    } else if (z > 180) {
      const m = (z - 120) * 0.8;
      const t = m + 120;
      const count = m <= 360 ? 1 : (m <= 720 ? 2 : 3);
      for (let k = 1; k <= count; k++) {
        checkPoints.push(Math.round(121 + (t - 121) * k / (count + 1)));
      }
    }
  }

  log('心跳循环开始: ' + fullHb + ' 轮 × ' + interval + 's, 检测点=' +
      checkPoints.length + '个', 'info');

  for (let h = 1; h <= fullHb; h++) {
    // ⚠️ 真实等待 interval 秒后再发心跳 (对齐普通模式引擎: 每轮开头
    // await interval 秒 → 发心跳 → 下一轮再等)。不可加速: 服务端对
    // 「秒级放大」风控 — 1s 内上报 60s 停留返回 699001 拒绝
    // (报告: stay=30s → 699001, 单事件 stay 存在 <30s 上限, 防秒级放大)。
    await sleep(interval * 1000);  // 真实等待 60s

    ptiFloat += speed;
    const pti = Math.floor(ptiFloat);
    const playedS = Math.min(pti * interval, total);
    const stayMs = interval * 1000;
    const mediaMs = Math.round(interval * speed * 1000);

    // 心跳 collect (脚本自建四通道回退)
    const r = await collectWithFallback({
      lessonId: lessonId, courseId: courseId,
      action: 2, stayTime: stayMs, mediaTime: mediaMs,
      pti: pti, pointNum: pointNum,
      videoType: task.contentType === 11 ? 6 : 1, speed: 1.0,
      verbose: true,  // 输出各通道失败详情 (定位 bfe 心跳失败原因)
    });
    if (r.ok) heartbeatOkCount++; else collectFailCount++;
    log('心跳 ' + h + '/' + fullHb + ': pti=' + pti + ' played=' + playedS +
        's, ok=' + r.ok + ' host=' + r.host + ' code=' + r.code +
        (r.error ? ' err=' + r.error : ''), r.ok ? 'info' : 'warning');

    // 进度 + 详情栏 (全部由脚本控制)
    updateProgress(Math.min(playedS / total, 1), '心跳 ' + h + '/' + fullHb);
    updateDetail({
      progress: Math.min(playedS / total, 1),
      playedSeconds: playedS,
      totalSeconds: total,
      message: '心跳 ' + h + '/' + fullHb + ' (host=' + r.host + ')',
      // 服务器时间同步信息 (脚本自维护时钟)
      serverTimeDiffMs: clockDiffMs(),
      serverTimeSyncCount: clockSyncCount(),
      serverLastTs: clockLastTs(),
      // 检测点 (客户端生成, 供详情栏展示与完成度)
      videoCheckPoints: checkPoints,
      pointNum: pointNum,
      lastPointTimeId: pti,
      heartbeatOkCount: heartbeatOkCount,
      collectFailCount: collectFailCount,
      completedCheckPointCount: focusDoneCount,
      interactiveTotalCount: interactiveConfigs.length,
      interactiveDoneCount: interactiveDoneCount,
      isBlacklisted: isBlacklisted,
      isInteractiveVideo: isInteractiveVideo,
      lessonFocusDone: focusDoneCount >= checkPoints.length,
      lessonInteractiveDone: interactiveDoneCount >= interactiveConfigs.length,
      seriousCheckConfig: seriousCfg,
    });

    // 认真度检测点到达 → 完整检测 (脚本自建 collect + apiSendVideoCheck)
    while (cpIdx < checkPoints.length &&
        (checkPoints[cpIdx] <= playedS || checkPoints[cpIdx] === playedS + 1)) {
      const cp = checkPoints[cpIdx];
      cpIdx++;
      if (isDowngrade) {
        log('  认真度检测 ' + cpIdx + '/' + checkPoints.length + ' 已降级 (仅日志)', 'warning');
        continue;
      }
      let ipId = null;
      if (isInteractiveVideo && interactiveConfigs.length > 0) {
        const detail = await apiGetInteractiveConfigDetail(interactiveConfigs[0].id);
        ipId = detail.id || null;
      }
      const addVideoType = isInteractiveVideo ? 3 : (task.contentType === 1 ? 1 : 2);

      // act=3 检测点暂停 (脚本 collect)
      const r3 = await collectWithFallback({
        lessonId: lessonId, courseId: courseId,
        action: 3, stayTime: 0, mediaTime: 0,
        pti: pti, pointNum: pointNum,
        videoType: task.contentType === 11 ? 6 : 1, speed: 1.0,
      });
      log('  [act=3 检测点暂停] host=' + r3.host + ' code=' + r3.code,
          r3.ok ? 'info' : 'warning');

      // 首报 seriousCheckResult=0
      await apiSendVideoCheck({
        blacklisted: isBlacklisted, type: addVideoType,
        interactivePointId: ipId, seriousCheckResult: 0,
      });
      log('  addVideo?ss(0) 首报 ok (type=' + addVideoType + ')', 'info');

      // 滑块解算 (仅黑名单, 宿主 solveCaptcha 依赖原生 ecaptcha)
      let captchaToken = null;
      if (isBlacklisted) {
        const cap = await solveCaptcha();
        captchaToken = cap && cap.captchaToken ? cap.captchaToken : null;
        log(captchaToken ? '  滑块解算成功' : '  滑块解算未拿到 token', 'info');
      } else {
        log('  普通用户 (ev 组件), 跳过滑块解算, 直接二次上报', 'info');
      }

      // 模拟用户点击通过
      await sleep(2000);

      // 二次上报 seriousCheckResult=2
      await apiSendVideoCheck({
        blacklisted: isBlacklisted, type: addVideoType,
        interactivePointId: ipId, seriousCheckResult: 2,
        captchaToken: captchaToken || undefined,
      });
      log('  addVideo?ss(2) 二次上报 ok', 'success');

      // act=2 恢复 (脚本 collect)
      const r2 = await collectWithFallback({
        lessonId: lessonId, courseId: courseId,
        action: 2, stayTime: 0, mediaTime: 0,
        pti: pti, pointNum: pointNum,
        videoType: task.contentType === 11 ? 6 : 1, speed: 1.0,
      });
      log('  [act=2 检测点恢复] host=' + r2.host + ' code=' + r2.code,
          r2.ok ? 'info' : 'warning');
      focusDoneCount++;

      // 进度持久化 (宿主 sendPlaybackProgress, multipart 需原生)
      await persistProgress({ playTime: Math.round(total / pointNum * pti) });
    }

    // 互动点到达 → 完整答题
    while (ipIdx < interactiveConfigs.length) {
      const tpSec = Math.floor((interactiveConfigs[ipIdx].timePoint || 0) / 1000);
      if (tpSec > playedS + 1) break;
      const cfg = interactiveConfigs[ipIdx];
      ipIdx++;

      const detail = await apiGetInteractiveConfigDetail(cfg.id);
      const sceneId = detail.interactiveSceneId;
      const q = detail.question;
      const questionId = q ? q.id : (detail.questionId || null);
      if (!sceneId || !questionId) {
        log('  互动点跳过: 缺少 sceneId/questionId', 'warning');
        continue;
      }

      let correct = null;
      const r0 = await apiSubmitInteractiveAnswer({
        interactiveSceneId: sceneId, questionId: questionId, myAnswers: [''],
      });
      if (r0.answers && r0.answers.length > 0) correct = String(r0.answers[0]);

      if (correct) {
        await apiSubmitInteractiveAnswer({
          interactiveSceneId: sceneId, questionId: questionId, myAnswers: [correct],
        });
        log('  互动点 ' + ipIdx + '/' + interactiveConfigs.length + ': 正确答案提交 ok', 'info');
      }

      await apiSendVideoCheck({
        blacklisted: isBlacklisted, type: 3,
        interactivePointId: cfg.id, seriousCheckResult: 0,
      });
      await apiSendVideoCheck({
        blacklisted: isBlacklisted, type: 3,
        interactivePointId: cfg.id, seriousCheckResult: 2,
      });
      log('  互动点 ' + ipIdx + '/' + interactiveConfigs.length + ': 记录通过 ok', 'success');
      interactiveDoneCount++;
    }

    // 周期性进度持久化
    if (playedS - lastProgressPersist >= persistEverySec) {
      await persistProgress({ playTime: playedS });
      lastProgressPersist = playedS;
    }
    if (h % persistEveryHb === 0) {
      await persistProgress({ playTime: playedS });
    }

    // 真实进度轮询: 达完成阈值提前结束
    const now = Date.now();
    if (now - lastProgressQueryTs >= pollIntervalMs) {
      lastProgressQueryTs = now;
      const ratio = await apiQueryProgress();
      log('真实进度: ' + Math.round((ratio || 0) * 100) + '%', 'info');
      if ((ratio || 0) >= completeRatio) {
        log('真实进度已达阈值, 提前结束', 'success');
        break;
      }
    }
  }

  // 5. 结束序列 (脚本自建 collect: 2×playbackProgress → act=3 → act=4 → 1×)
  const endPti = Math.floor(ptiFloat);
  await persistProgress({ playTime: total });
  await persistProgress({ playTime: total });
  await sleep(500);
  await collectWithFallback({
    lessonId: lessonId, courseId: courseId,
    action: 3, stayTime: 0, mediaTime: 0,
    pti: endPti, pointNum: pointNum,
    videoType: task.contentType === 11 ? 6 : 1, speed: 1.0,
  });
  await collectWithFallback({
    lessonId: lessonId, courseId: courseId,
    action: 4, stayTime: 21, mediaTime: 0,
    pti: endPti, pointNum: pointNum,
    videoType: task.contentType === 11 ? 6 : 1, speed: 1.0,
  });
  await sleep(500);
  await persistProgress({ playTime: total });

  // 6. 查询服务端最终进度
  const ratio = await apiQueryProgress();
  log('服务端最终进度: ' + Math.round((ratio || 0) * 100) + '%', 'info');
  updateProgress(1.0, '完成');
  updateDetail({
    progress: 1.0, playedSeconds: total, totalSeconds: total,
    message: '上报完成', heartbeatOkCount: heartbeatOkCount,
    collectFailCount: collectFailCount,
    serverTimeDiffMs: clockDiffMs(),
    serverTimeSyncCount: clockSyncCount(),
    serverLastTs: clockLastTs(),
    videoCheckPoints: checkPoints,
    pointNum: pointNum,
    lastPointTimeId: Math.floor(ptiFloat),
    completedCheckPointCount: focusDoneCount,
    interactiveTotalCount: interactiveConfigs.length,
    interactiveDoneCount: interactiveDoneCount,
    isBlacklisted: isBlacklisted,
    isInteractiveVideo: isInteractiveVideo,
    lessonFocusDone: focusDoneCount >= checkPoints.length,
    lessonInteractiveDone: interactiveDoneCount >= interactiveConfigs.length,
    seriousCheckConfig: seriousCfg,
  });
  log('自定义上报完成', 'success');
}
