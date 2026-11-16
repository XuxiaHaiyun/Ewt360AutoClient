# mstplayer-v3.0.37 行为分析文档

> 分析对象：`https://cdn.ewt360.com/resources/app/prod/mst-video-player/dist/mstplayer-v3.0.37.min.js`
> 分析页面：`https://teacher.ewt360.com/ewtbend/bend/index/index.html#/homework/play-videos?role=student&courseId=48419&lessonId=117890&videoType=1&homeworkId=10495544&onlyMustLearn=1&isNewPlayer=1&videoPoint=0&date=1785427200000`
> 分析方式：Edge DevTools MCP 注入 fetch/XHR 拦截器 + 运行时对象读取 + 源码静态分析

---

## 1. 全局对象

脚本加载后在 `window` 上挂载以下关键全局变量：

| 全局变量 | 类型 | 说明 |
|---|---|---|
| `MSTPlayer` | class | 播放器主类，封装 videojs |
| `ApiRequest` | function | 通用请求工具（静态方法 `get/post/ajax/postBody` 等） |
| `axios` | function | 全局 axios（页面其它脚本使用） |
| `MSTAnalytics` | object | 埋点上报对象 |
| `MstQtAnalytics` | object | QuickTracking 埋点对象，含 `currentUid`、`pageConfigMap` |
| `__oXMLHttpRequest_` | function | 原生 `XMLHttpRequest` 备份（被劫持前的原始实现） |
| `__MST_REAL_LABEL__` | string | 值为 `"baseline"`（AB 实验标签） |
| `__MST_CUSTOM_CONFIG__` | object | 自定义配置（当前为空 `{}`） |

---

## 2. 域名 / Host 配置

源码中根据 `location.host` 判断环境，构造统一域名：

```js
const hostInfo = hostCheck(location.host);              // prod 环境
const makeUnifyDomain = e => `//${e}.ewt360.com`;        // prod
const bfe       = makeUnifyDomain("bfe");                // //bfe.ewt360.com
const clog      = makeUnifyDomain("clog");               // //clog.ewt360.com
const dlog      = makeUnifyDomain("dlog");               // //dlog.ewt360.com
const gateway   = makeUnifyDomain("gateway");            // //gateway.ewt360.com
const video     = gateway;                               // 非管理端/非CPS 时 video = gateway
const adminGateway = makeUnifyDomain("admingateway");
const cps       = makeUnifyDomain("cps");
```

`BizPoint` 插件内的 host 映射（用于看课埋点多通道上报，按顺序尝试，成功即停）：

```js
const hostMap = { bfe, clog, dlog, iplog: "" };
// 若配置了 fallbackIP，则 iplog = "//" + fallbackIP，并 push 到 _hostList
// _hostList = ["bfe", "clog", "dlog", "iplog"]
```

---

## 3. API 端点清单

| 用途 | 方法 | URL |
|---|---|---|
| 看课埋点上报（核心） | POST | `//bfe.ewt360.com/monitor/web/collect/batch` |
| 作业任务进度 | POST | `//gateway.ewt360.com/api/homeworkprod/homework/student/getUserHomeworkLessonTaskInfo` |
| 互动配置详情 | GET | `//gateway.ewt360.com/api/videoplayerprod/videoplayer/getInteractiveConfigDetail` |
| 互动题提交答案 | POST | `//gateway.ewt360.com/api/videoplayerprod/videoplayer/submitAnswer` |
| Token 续期 | GET | `//gateway.ewt360.com/api/authcenter/oauth/token/renewal/by/gateway` |
| 用户基本信息 | GET | `//gateway.ewt360.com/api/usercenter/user/baseinfo` |
| 学校基本信息 | GET | `//gateway.ewt360.com/api/commondata/common/school/get/baseinfo` |
| HLS 切片 | GET | `https://vod01.ewt360.com/<...>/sd-encrypt-stream-000XX.ts` |

`videoUrl$5 = video + "/api/videoplayerprod"` = `//gateway.ewt360.com/api/videoplayerprod`

---

## 4. 用户身份与 Token

```js
function getCookieUser() {
  // 依次从 cookie 读取 token / ewt_user / user
  const r = ["token", "ewt_user", "user"], n = getCookie();
  for (const i of r) if (n[i]) { t = n[i]; break; }
  t || (t = getUrlParam("token", location.search));      // 兼容 URL 参数
  t.match("tk=") && (t = getUrlParam("tk", t));
  t || (t = "0-0");
  e = Number(t.split("-")[0]) || 0;                       // userId
  return { userId: e, token: t };                         // token 形如 "160000000-1-xxxxxxxxxxxxxxxx"
}
```

- `userId` = `160000000`（token 第一段）
- `token` / `mstid` = `160000000-1-xxxxxxxxxxxxxxxx`（cookie 的 `token` 字段）
- `sessionId` = `${userId}_${随机UUID}`，例：`160000000_7d6c8388-c6b6-44db-93ca-e40b08324e26`

---

## 5. 看课埋点上报（核心接口）

### 5.1 触发时机

`BizPoint` 插件监听 videojs 播放器事件：

```js
this.player.on("play",    this.onPlay);      // 播放
this.player.on("pause",   this.onPause);     // 暂停
this.player.on("ended",   this.onEnded);     // 播放结束
this.player.on("waiting", this.onBufferStart); // 缓冲开始
this.player.on("canplay", this.onBufferEnd);  // 缓冲结束
this.player.on("ratechange", this.onRateChange); // 倍速变化
this.player.on(MSTPlayerEvent.SEEK, this.onSeek); // 拖拽进度
```

各事件触发的上报：

| 事件 | 调用 | action | status | duration(stay_time) | media_time |
|---|---|---|---|---|---|
| `onPlay` → `uploadPlayLike` | `upload(_isFirstPlayStatus, WATCH, 0, 0)` | 首次=1(START)，之后=2(PLAYING) | 1(WATCH) | 0 | 0 |
| 心跳 `uploadWatchLike`（每 60s） | `upload(_isFirstPlayStatus, WATCH, r, n)` | 2(PLAYING) | 1(WATCH) | 真实偏移 | 媒体偏移 |
| `onPause` → `uploadPauseLike` | `upload(_isFirstPlayStatus, WATCH, t, r)` + `upload(PAUSED, PAUSED, 0, 0)` | 先 2 再 3 | 先 1 再 3 | t / 0 | r / 0 |
| `onEnded` | 上报结束 | 4(END) | - | - | - |

### 5.2 状态枚举

```js
FCStatusEnum  = { START:1, PLAYING:2, PAUSED:3, END:4 }   // action 字段
ClogStatusEnum= { WATCH:1, PAUSED:3 }                      // status 字段
VideoTypeEnum = { LIVE:0, NORMAL:1, FM:3, SCHOOL:6 }       // video_type
```

### 5.3 时间计算

```js
function getMillisecond() { return Math.floor(performance.now()); }  // 页面加载后的单调毫秒数

// _diffTime = 服务器时间戳 - getMillisecond()，由接口返回的 data.ts 校准（checkDiffTime）
// report_time = getMillisecond() + _diffTime   => 服务器同步时间戳（毫秒）

getOffsetTime(t)       = t - this._lastUploadTime      // 真实流逝时长（自上次上报）
getMediaOffsetTime(e)  = mediaTimeMs - this._lastMediaTimeMs  // 视频媒体流逝时长
getCurrentMediaTimeMs() = Math.floor(1000 * player.currentTime())
```

### 5.4 请求构造（`createParams`）

**URL**：`POST //bfe.ewt360.com/monitor/web/collect/batch`

**Query 参数**（由 `pointFCUpload` 拼接）：

| 参数 | 来源 | 示例 |
|---|---|---|
| `TrVideoBizCode` | `options.videoBizCode` | `1013` |
| `TrFallback` | `EventPackage[0].fallback` | `0` |
| `TrUserId` | `CommonPackage.userid` | `160000000` |
| `TrLessonId` | `EventPackage[0].lesson_id` | `117890` |
| `TrUuId` | `${uuid}_${upIndex}` | `aBX8ZQTM_4` |
| `sdkVersion` | 拦截器追加 | `3.0.37` |
| `_` | 时间戳防缓存 | `1785476037053` |

**请求头**：

```
Accept: application/json, text/plain, */*
Content-Type: application/json
Access-Control-Allow-Origin: *
x-bfe-session-id: 160000000_7d6c8388-c6b6-44db-93ca-e40b08324e26
token: 160000000-1-xxxxxxxxxxxxxxxx
```

**请求体**：

```json
{
  "CommonPackage": {
    "userid": 160000000,
    "ip": "117.189.108.122",
    "os": "Windows",
    "resolution": "1707*1067",
    "mstid": "160000000-1-xxxxxxxxxxxxxxxx",
    "browser": "Edge",
    "browser_ver": "5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ...",
    "playerType": 1,
    "sdkVersion": "3.0.37",
    "videoBizCode": "1013",
    "memberProvinceCode": "520000",
    "schoolId": "10000",
    "schoolProvinceCode": "520000"
  },
  "EventPackage": [
    {
      "lesson_id": "117890",
      "course_id": "48419",
      "stay_time": 0,            // 真实停留时长(ms) = duration
      "media_time": 0,           // 媒体播放时长(ms)
      "status": 1,               // ClogStatusEnum: 1=WATCH, 3=PAUSED
      "begin_time": 1785475981707,   // 开始播放的服务器时间戳
      "report_time": 1785476038703,  // 本次上报服务器时间戳
      "point_time_id": 1,        // Math.ceil(currentTime / intervalTime)
      "point_time": 60000,       // 1000 * intervalTime (心跳周期 ms)
      "point_num": 13,           // Math.ceil(duration / intervalTime) 总点数
      "video_type": 1,
      "speed": 1,                // 倍速
      "quality": "高清",          // 清晰度
      "action": 2,               // FCStatusEnum: 1=START 2=PLAYING 3=PAUSED 4=END
      "fallback": 0,
      "uuid": "aBX8ZQTM_4"       // ${sessionId_uuid}_${递增序号}
    }
  ],
  "signature": "afb3686fd2c2a9cec6912f4ab7aaa693a26ecac4",
  "sn": "ewt_web_video_detail",
  "_": 1785476037053
}
```

### 5.5 签名算法（HMAC-SHA1）

**密钥（secret）**：`5373c0e70a15c97150bbef12522b6b90`
（来源：`BizPoint` 插件实例 `this._options.secret`，由页面初始化时通过 `globalInfo.secret` 传入）

**算法**（源码 `makeSecretKey`）：

```js
function makeSecretKey(e, t) {        // e=参数对象, t=secret
  let r = "";
  // 1. 按 key 字典序排序
  Object.keys(e).sort().forEach((k, i) => {
    r += (i ? "&" : "") + k + "=" + e[k];   // 2. 拼 key=value&key=value
  });
  // 3. HMAC-SHA1，密钥=t，消息=r，输出 HEX
  const n = new jsSHA("SHA-1", "TEXT");
  n.setHMACKey(t, "TEXT");
  n.update(r);
  return n.getHMAC("HEX");
}
```

**参与签名的参数**：

```js
{
  action: <FCStatusEnum>,              // 1/2/3/4
  duration: <stay_time>,               // 与 EventPackage.stay_time 相同
  mstid: "<token>",                    // 如 160000000-1-xxxxxxxxxxxxxxxx
  timestamp: <report_time>,            // 与 EventPackage.report_time 相同
  version: "2022-08-02",
  signatureMethod: "HMAC-SHA1",
  signatureVersion: "1.0"
}
```

排序后的待签名串（key 字典序）：

```
action=2&duration=0&mstid=160000000-1-xxxxxxxxxxxxxxxx&signatureMethod=HMAC-SHA1&signatureVersion=1.0&timestamp=1785476038703&version=2022-08-02
```

**验证**（已用三组真实样本验证通过）：

| action | duration | timestamp | 期望 signature | HMAC-SHA1 结果 | 匹配 |
|---|---|---|---|---|---|
| 2 | 0 | 1785476038703 | `afb3686f...a26ecac4` | `afb3686f...a26ecac4` | ✅ |
| 2 | 17674 | 1785476056371 | `9ac0e221...d1de524c` | `9ac0e221...d1de524c` | ✅ |
| 3 | 0 | 1785476056375 | `f4aff548...12ccc2b0` | `f4aff548...12ccc2b0` | ✅ |

### 5.6 响应

```json
{
  "code": 200,
  "data": { "ts": 1785476038974 },   // 服务器时间戳，用于 checkDiffTime 校准 _diffTime
  "msg": "ok",
  "success": true
}
```

- `data.ts` 被用来同步服务器时间：`_diffTime = ts - getMillisecond()`

### 5.7 错误码

| code | 含义 | 处理 |
|---|---|---|
| `699101` | 签名错误 | 触发 `ErrorEnum.POINT_SIGNATURE_ERROR`，忽略暂停上报 |
| `699102` | 看课数据非法（疑似作弊/回放） | 触发对应错误，停止上报 |

---

## 6. 作业任务进度接口

**请求**：`POST //gateway.ewt360.com/api/homeworkprod/homework/student/getUserHomeworkLessonTaskInfo`

**头**：

```
Accept: application/json, text/plain, */*
Content-Type: application/json
Access-Control-Allow-Origin: *
token: 160000000-1-xxxxxxxxxxxxxxxx
referUrl: https://teacher.ewt360.com/...#/homework/play-videos?...
```

**体**：

```json
{ "schoolId": 10000, "homeworkId": 10495544, "lessonId": 117890, "contentType": 1 }
```

**响应**：

```json
{
  "success": true,
  "code": "200",
  "msg": "操作成功",
  "data": {
    "playTime": 766672,          // 已播放时长(ms)
    "percent": 1.0,              // 播放比例
    "finishPlayTime": 610400,    // 完成判定时长(ms)
    "finishPercent": 0.8,        // 完成判定比例
    "lessonTime": 763000,        // 课程总时长(ms)
    "lessonId": "117890"
  }
}
```

---

## 7. ApiRequest 通用请求工具

```js
ApiRequest.get(url, params, opts)       // GET，query 拼接，返回 data
ApiRequest.post(url, params, body, opts)// POST，body 进 body，返回 data
ApiRequest.postBody(url, params, body)  // POST，body 进 body
ApiRequest.ajax(method, url, body, opts)// 原生 XHR
ApiRequest.ajaxPost(url, params, body, opts)
ApiRequest.request(method, url, opts)   // fetch 封装
ApiRequest._getUrl(url, params)         // 拼接 query
ApiRequest._intercept(resp)             // code!=0 视为错误
```

**响应约定**：`{ code, data, description, tid }`，`code == 0` 为成功（resolve `data`），非 0 走 `_intercept` 拒绝并返回 `{code, data, description, message:"0x"+hex(code)+", "+description}`。

> 注：看课埋点接口（`collect/batch`）走的是 mstplayer 内部的 `request`（axios 实例），响应约定为 `{code:200, success:true, data, msg}`，与 `ApiRequest` 的 `code==0` 约定不同。

---

## 8. 关键运行时实例数据（实测抓取）

| 字段 | 值 |
|---|---|
| `userId` | `160000000` |
| `token` / `mstid` | `160000000-1-xxxxxxxxxxxxxxxx` |
| `sessionId` | `160000000_7d6c8388-c6b6-44db-93ca-e40b08324e26` |
| `clientIp` | `117.189.108.122` |
| `schoolId` | `10000` |
| `memberProvinceCode` | `520000` |
| `videoBizCode` | `1013` |
| `lessonId` | `117890` |
| `courseId` | `48419` |
| `videoType` | `1` (NORMAL) |
| `intervalTime` | `60` (秒) |
| `secret` | `5373c0e70a15c97150bbef12522b6b90` |
| `sdkVersion` | `3.0.37` |
| `sn` | `ewt_web_video_detail` |
| `uuid` | `aBX8ZQTM`（每次会话生成，上报时拼 `${uuid}_${upIndex}`） |
| `_diffTime` | `1785475973327`（服务器时间偏移基准） |

---

## 9. 完整调用时序

1. 页面加载 → `new MSTPlayer(parentDom, options)`，options 含 `videoBizCode`、`videoInfo`、`globalInfo`(含 `secret`、`intervalTime`、`sessionId`、`clientIp`、`fallbackIP`) 等
2. `MSTPlayer.initServerInfo()` → 拉取互动配置、用户/学校信息、VodService 获取 `PlayURL`（HLS）
3. `bizPoint(globalInfo + lessonId + videoBizCode + ...)` 注册看课埋点插件，初始化 `_diffTime`、`_uuid`
4. 用户点击播放 → `onPlay` → `uploadPlayLike` 上报 `action=START/PLAYING`
5. 每隔 60s → `uploadWatchLike` 上报心跳 `action=PLAYING, status=WATCH`
6. 暂停 → `onPause` → `uploadPauseLike` 先发 WATCH 心跳再发 `action=PAUSED`
7. 播放结束 → `onEnded` → 上报 `action=END`
8. 每次上报响应的 `data.ts` 用于校准 `_diffTime`
9. 上报失败按 `_hostList` 顺序回退：`bfe → clog → dlog → iplog`

---

## 10. 注意事项

- `secret` 是客户端硬编码下发，非动态获取；不同环境/版本可能不同，本版本为 `5373c0e70a15c97150bbef12522b6b90`
- `report_time` 必须使用服务器同步时间（`getMillisecond() + _diffTime`），否则会触发 `699101`/`699102`
- `stay_time`（真实时间）与 `media_time`（媒体时间）分离统计，倍速播放时二者不同
- `point_time_id` = `ceil(currentTime / 60)`，`point_num` = `ceil(duration / 60)`，用于服务端校验播放进度点
- HLS 切片为加密流（`sd-encrypt-stream`），由 `ali-hls.min.1.1.2.js` 解密播放
