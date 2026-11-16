# 认真度检测 (Focus Check) 接口调用文档

> 对齐 Dart 实现:
> - [player_remote_datasource.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart)
> - [playback_engine.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\domain\services\playback_engine.dart) `_performFocusCheck`
> - [captcha_net.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\captcha\captcha_net.dart)
> - [sign_interceptor.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\network\interceptors\sign_interceptor.dart) / [auth_interceptor.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\network\interceptors\auth_interceptor.dart)
> - [endpoint_config.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\config\endpoint_config.dart) / [crypto_constants.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\constants\crypto_constants.dart)
> - [api_constants.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\constants\api_constants.dart)

---

## 一、通用调用约定

### 1.1 网关

| 域名 | 用途 | 是否需 EWT 签名 |
|---|---|---|
| `https://gateway.ewt360.com` | 主网关 (homeworkprod / videoplayerprod / eteacherproduct / usercenter) | 是 |
| `https://filegateway.ewt360.com` | ecaptcha 滑块验证 (业务层) | 否 (只需 bizCode) |
| `https://imlog.ewt360.com` | BFE/CLOG 心跳遥测 (collect/batch) | HMAC-SHA1 (BFE 自有密钥) |

### 1.2 通用请求头 (主网关所有请求)

由 [dio_client.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\network\dio_client.dart) 基础头 + [auth_interceptor.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\network\interceptors\auth_interceptor.dart) 认证头 + [sign_interceptor.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\network\interceptors\sign_interceptor.dart) 签名头共同注入。

```
# 基础头 (dio_client.dart BaseOptions.headers)
Content-Type: application/json
Accept: application/json, text/plain, */*
Accept-Encoding: gzip, deflate, br, zstd
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
Connection: keep-alive

# 认证头 (auth_interceptor.dart)
token: <登录 token, 未登录传 "0">
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ... Edg/147.0.0.0
Origin: https://www.ewt360.com
Referer: https://www.ewt360.com/

# 设备/浏览器提示 (endpoint_config.dart extraHeaders, 可由 web_device_info.json 覆盖)
sec-ch-ua: "Not(A:Brand";v="8", "Chromium";v="147", "Microsoft Edge";v="147"
sec-ch-ua-mobile: ?0
sec-ch-ua-platform: "Windows"
Sec-Fetch-Site: same-site
Sec-Fetch-Mode: cors
Sec-Fetch-Dest: empty
DNT: 1

# 签名头 (sign_interceptor.dart, 每个请求动态生成)
timestamp: <13 位毫秒时间戳>
sign: <MD5(timestamp + secretKey).toUpperCase()>
secretId: 2          # WEB 端点固定值 (crypto_constants.dart webSecretId)
platform: 1          # WEB 端点固定值 (crypto_constants.dart webPlatform)
```

### 1.3 签名算法 (对应 [crypto_utils.dart RequestSigner](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\crypto\crypto_utils.dart))

```
timestamp = 当前毫秒 (13 位)
sign      = MD5( timestamp + "bdc739ff2dcf" ).toUpperCase()
secretId  = "2"
platform  = "1"
```

| 常量 | 值 | 来源 |
|---|---|---|
| `webSignSecretKey` | `bdc739ff2dcf` | [crypto_constants.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\constants\crypto_constants.dart) |
| `webSecretId` | `2` | 同上 |
| `webPlatform` | `1` | 同上 |

### 1.4 统一响应格式

```json
{ "success": true, "code": "200", "msg": "操作成功", "data": ... }
```

- `data` 类型随接口变化 (bool / object / array / string)
- 部分旧接口 `code` 为 `"00000"`, `msg` 为 `"success"`
- `success == false` 时按 `code` 分流错误处理

### 1.5 检测点核心错误码

| 错误码 | 含义 | 用户可见 |
|---|---|---|
| `699001` | 看课数据非法 (触发确认型弹窗) | "视频已暂停" |
| `699101` | 签名错误 | "oops, 遇到一点小状况" |
| `699102` | 参数错误 | "oops, 遇到一点小状况" |
| `626101` | submitAnswer 题目为空 | 业务错误 |

---

## 二、认真度检测流程总览

```
[阶段 A: 播放前一次性查询]
   getLessonDetailV2          → needCheckPoint / interactiveVideo
   getSeriousCheckDownGradeConfig → level (0 正常 / >0 降级)
   getVideodp                 → data:bool (黑名单)
   getExternalVideoInfo        → 时长 + interactiveConfigs (可失败, 不阻断)
   客户端生成 videoCheckPoint[]  → [121, 181, 241, ...] (秒, 间距 60)

[阶段 B: 心跳循环 (墙钟 60s/120s)]
   每轮检查: cp > lastPlayed && cp <= currentPlayed
   ┌── 检测点触发 → perform_focus_check() ──┐
   │                                        │
   │  1. act=3 (collect 暂停埋点)           │
   │  2. addVideoss/addVideocss (首报, 0)   │
   │  3. 主动解算滑块 (仅黑名单) → token    │
   │  4. 模拟用户点击 (~2s 快刷 / ~5s 常规)│
   │  5. addVideoss/addVideocss (二次, 2)  │
   │  6. act=2 (collect 恢复埋点)           │
   │  7. playbackProgress 进度持久化        │
   └────────────────────────────────────────┘

[阶段 C: 互动视频检测点变体]
   到达 interactiveTimePoint 时:
      getInteractiveConfigDetail → 取题
      submitAnswer (空答) → 拿正确答案
      submitAnswer (正确答案)
      addVideoss/addVideocss: 0 → 2 (type=3, ipId=cfg.id)

[降级分支]
   level > 0 → 仅写日志, 不执行上述 1~7 步, 进度上报照常
```

---

## 三、播放前查询接口

### 3.1 getSeriousCheckDownGradeConfig — 认真度检测降级配置

**用途**：判定认真度检测功能是否可用 (高峰期降级兜底)。

- **方法 / URL**：`GET /api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig`
- **Query**：

| 字段 | 类型 | 必填 | 示例 |
|---|---|---|---|
| `schoolId` | string | 是 | `10000` |
| `videoType` | int | 是 | `1` |

- **响应** `data`：

```json
{
  "key": "downgrade.student.video.serious.check",
  "level": 0,
  "tips": "当前为使用高峰期, 课程视频监测功能暂不可用",
  "description": "课程视频监测功能降级",
  "needLog": 1
}
```

- **判断**：
  - `level == 0` → 正常检测, 执行完整流程
  - `level > 0`  → 降级模式, 仅日志, 不暂停/不滑块
  - 接口失败 → 默认 `level=1` (安全 fallback, 避免自动化卡死)

**源码**：[player_remote_datasource.dart getSeriousCheckDownGradeConfig](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart) / [serious_check_config.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\domain\entities\serious_check_config.dart)

---

### 3.2 getVideodp — 查询黑名单状态

**用途**：决定检测点走滑块型 (ek 组件) 还是确认型 (ev 组件)。

- **方法 / URL**：`GET /api/homeworkprod/homework/student/getVideodp`
- **Query**：

| 字段 | 类型 | 必填 | 示例 |
|---|---|---|---|
| `_` | long | 否 (防缓存) | `1785478092335` |

- **响应** `data`：布尔值

```json
{ "success": true, "code": "200", "msg": "操作成功", "data": true }
```

- **判断**：
  - `data == true`  → 已在黑名单 → **ek 组件** → 走滑块型 (ecaptcha) → 二次上报携带 `captchaToken`
  - `data == false` → 普通用户 → **ev 组件** → 走确认型 (直接二次上报 `seriousCheckResult=2`, 不解算滑块)
  - 浏览器源码：`let {data:e} = await getVideodp(); setIsBlacklisted(!!e)`

**源码**：[player_remote_datasource.dart getVideodp](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L511-L537)

---

### 3.3 getLessonDetailV2 — 课时详情 (含检测点开关)

- **方法 / URL**：`POST /api/homeworkprod/player/getLessonDetailV2`
- **请求体**：

```json
{ "schoolId": "10000", "lessonId": "117890", "homeworkId": "10495544" }
```

- **响应** `data` (节选)：

```json
{
  "id": "117890",
  "lessonName": "J《六国论》带背与带练1",
  "videoPlayTime": 763.00,
  "needCheckPoint": true,
  "interactiveVideo": false,
  "studyGuideShowVO": { "showDxa": true, "showPractise": true }
}
```

- **字段含义**：
  - `needCheckPoint`：课程级检测点开关 (true 需要检测点)
  - `interactiveVideo`：视频级互动题开关 (false 当前视频无互动题 → 走普通检测点)
  - `videoPlayTime`：视频时长 (秒), 用于生成 `videoCheckPoint[]`

**源码**：[player_remote_datasource.dart getLessonDetail](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L100-L122)

---

### 3.4 getExternalVideoInfo — 视频信息 (互动点位置)

- **方法 / URL**：`GET /api/videoplayerprod/videoplayer/getExternalVideoInfo`
- **Query**：

| 字段 | 类型 | 必填 | 示例 |
|---|---|---|---|
| `videoBizCode` | string | 是 | `1013` |
| `lessonId` | string | 是 | `117890` |
| `videoToken` | string | 是 | (来自 getPlayerToken) |
| `sdkVersion` | string | 是 | `3.0.37` |
| `_` | long | 否 | 时间戳 |

- **响应** `data` (节选)：

```json
{
  "videoInfo": { "duration": 763, "contentType": 1 },
  "interactiveInfo": {
    "interactiveConfigList": [
      { "id": "xxx", "interactiveTimePoint": 180000 }
    ]
  }
}
```

- **用途**：拿时长生成 `videoCheckPoint[]` + 拿互动题时间点列表
- **可失败**：失败不阻断播放, 按无互动题处理

**源码**：[player_remote_datasource.dart getExternalVideoInfo](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L74-L98)

---

## 四、检测点上报接口 (核心)

### 4.1 addVideoss — 非黑名单 (ev 组件)

**用途**：普通用户认真度检测/互动点上报。

- **方法 / URL**：`POST /api/homeworkprod/homework/student/addVideoss`
- **请求体**：

```json
{
  "schoolId": 10000,
  "homeworkId": 10495544,
  "lessonId": "117890",
  "type": 1,
  "interactivePointId": null,
  "platform": 1,
  "seriousCheckResult": 0
}
```

- **二次上报** (黑名单携带 `captchaToken`):

```json
{
  "schoolId": 10000,
  "homeworkId": 10495544,
  "lessonId": "117890",
  "type": 1,
  "interactivePointId": null,
  "platform": 1,
  "seriousCheckResult": 2,
  "captchaToken": "fb3a848b-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

- **响应** `data`：布尔

```json
{ "success": true, "code": "200", "msg": "操作成功", "data": true }
```

**源码**：[player_remote_datasource.dart addVideoss](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L173-L215)

---

### 4.2 addVideocss — 黑名单 (ek 组件)

**用途**：黑名单用户认真度检测/互动点上报 (与 addVideoss 参数完全一致, 仅 URL 不同)。

- **方法 / URL**：`POST /api/homeworkprod/homework/student/addVideocss`
- **请求体**：同 4.1 (黑名单用户二次上报必携带 `captchaToken`)
- **响应**：同 4.1

**源码**：[player_remote_datasource.dart addVideocss](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L217-L245)

---

### 4.3 请求体字段对照

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schoolId` | int | 是 | 学校 ID (数值类型) |
| `homeworkId` | int | 是 | 作业 ID (数值类型) |
| `lessonId` | string | 是 | 课时 ID (字符串, 与服务端约定) |
| `type` | int | 是 | 见下表 |
| `interactivePointId` | string / null | 是 | 互动视频: `getInteractiveConfigDetail.id`; 普通视频: `null` (显式发送) |
| `platform` | int | 是 | 固定 `1` (WEB) |
| `seriousCheckResult` | int | 是 | `0`=首报 / `1`=失败 / `2`=通过 |
| `captchaToken` | string | 否 | 仅黑名单用户二次上报 (seriousCheckResult=2) 携带 |

### 4.4 `type` 计算规则 (对齐 §3'.6)

```
type = interactiveVideo ? 3
     : (contentType == 1 ? 1 : 2)
```

| type | 视频类型 | contentType |
|---|---|---|
| `1` | 普通视频 | `1` |
| `2` | 其他非互动 (如校本视频) | `≠ 1` (如 11) |
| `3` | 互动视频 (含互动题) | - |

### 4.5 `seriousCheckResult` 枚举

| 值 | 触发时机 | 是否携带 captchaToken |
|---|---|---|
| `0` INIT_LOG | 检测弹窗显示时 (首报) | 否 |
| `1` ERROR_LOG | 检测失败/错过 (倒计时超时) | 否 |
| `2` SUCCESS_LOG | 检测通过 (二次上报) | 黑名单: 是 / 普通: 否 |

---

## 五、ecaptcha 滑块验证接口 (黑名单专属)

> 域名 `filegateway.ewt360.com`, **无需 EWT 签名**, 只需 `bizCode`。

### 5.1 captcha/get — 获取滑块图

- **方法 / URL**：`POST https://filegateway.ewt360.com/api/captcha/captcha/get`
- **请求头**：

```
Content-Type: application/json
Accept: application/json, text/plain, */*
Origin: https://www.ewt360.com
Referer: https://www.ewt360.com/
```

- **请求体**：

```json
{ "bizCode": "mst1784513466143", "type": "2" }
```

> `bizCode` 取值 (来自 [crypto_constants.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\constants\crypto_constants.dart)):
> - `passwordCaptchaBizCode` = `mst1784513466143` (默认, 登录/检测点)
> - `smsCaptchaBizCode` = `mst1634782715743` (短信)
> - `registerSmsCaptchaBizCode` = `mst1634784055587` (注册)
>
> 浏览器 `homework-play-video.js` 中视频检测硬编码为 `mst + 时间戳`, 与本项目使用的 passwordCaptchaBizCode 一致。

- **响应** `data`：

```json
{
  "captchaSessionId": "xxx-xxx-xxx",
  "pieceY": 67,
  "backgroundImage": "data:image/png;base64,...",
  "pieceImage": "data:image/png;base64,...",
  "captchaToken": "fallback-token-若-verify-未返回"
}
```

- **字段含义**：
  - `captchaSessionId`：会话 ID, 后续 verify 必带
  - `pieceY`：滑块缺口的 Y 坐标 (固定)
  - `backgroundImage` / `pieceImage`：base64 编码的背景图和滑块图, 供视觉识别缺口 X
  - `captchaToken`：兜底 token (部分场景 verify 不返回新 token 时使用)

**源码**：[captcha_net.dart getCaptcha](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\captcha\captcha_net.dart#L41-L58)

---

### 5.2 captcha/verify — 验证滑块位置

- **方法 / URL**：`POST https://filegateway.ewt360.com/api/captcha/captcha/verify`
- **请求头**：同 5.1
- **请求体**：

```json
{
  "bizCode": "mst1784513466143",
  "type": "2",
  "captchaSessionId": "xxx-xxx-xxx",
  "verifyData": "[{\"x\":187,\"y\":67}]"
}
```

> 注意 `verifyData` 是 JSON 字符串 (整体被序列化一次), 不是对象。

- **响应** `data`：

```json
{
  "verifyResult": true,
  "captchaToken": "fb3a848b-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

- **字段含义**：
  - `verifyResult == true` → 滑块位置正确, 拿到 `captchaToken`
  - `verifyResult == false` → 位置错误, 继续扫描下一个 X
  - `captchaToken`：用于二次上报 `addVideocss`, 服务端据此确认用户已通过滑块

**源码**：[captcha_net.dart verify](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\captcha\captcha_net.dart#L64-L89)

---

### 5.3 滑块求解流程 (对应 [captcha_service.dart](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\captcha\captcha_service.dart))

```
1. captcha/get → 拿到 background / piece / pieceY / sessionId
2. 视觉预测缺口 X (locate_gap_rectified, 失败则跳过)
3. 局部扫描 (predX ±12, step=3)
     for x in [predX-12, predX+12] step 3:
         verify(x, y)
         if 命中: fine_scan(x, ±2) 取最佳 token → 返回
4. 全图扫描兜底 (step=4)
     for x in [0, 290) step 4:
         verify(x, y)
         if 命中: fine_scan(x, ±2) → 返回
5. 全部失败 → 抛异常, 二次上报不带 captchaToken (流程仍继续)
```

---

## 六、互动视频检测点接口

### 6.1 getInteractiveConfigDetail — 互动题详情

- **方法 / URL**：`GET /api/videoplayerprod/videoplayer/getInteractiveConfigDetail`
- **Query**：

| 字段 | 类型 | 必填 | 示例 |
|---|---|---|---|
| `interactiveConfigId` | Long | 是 | `117891` (来自 `interactiveConfigList[].id`, 服务端按 Long 解析) |
| `videoBizCode` | string | 是 | `1013` |
| `_` | long | 否 | 时间戳 |

> **参数名注意**：必须用 `interactiveConfigId`，传 `configId` 会报
> `Required Long parameter 'interactiveConfigId' is not present` (code 621702)。

- **响应** `data`：

```json
{
  "id": "117891",
  "interactiveSceneId": "xxx",
  "interactiveName": "...",
  "interactiveTimePoint": 180000,
  "question": {
    "id": "q123",
    "options": ["A", "B", "C", "D"],
    "imageUrl": "..."
  }
}
```

- **用途**：
  - 取 `data.id` 作为 `addVideoss/addVideocss` 的 `interactivePointId`
  - 取 `interactiveSceneId` / `question.id` 用于后续 submitAnswer

**源码**：[player_remote_datasource.dart getInteractiveConfigDetail](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L462-L478)

---

### 6.2 submitAnswer — 提交互动题答案

- **方法 / URL**：`POST /api/videoplayerprod/videoplayer/submitAnswer`
- **请求体**：

```json
{
  "interactiveSceneId": "xxx",
  "questionId": "q123",
  "myAnswers": ["A"],
  "totalSeconds": 1,
  "videoBizCode": "1013",
  "lessonId": "117890"
}
```

- **响应** `data`：

```json
{ "answers": ["A"], "rightStatus": 1 }
```

- **字段含义**：
  - `answers`：正确答案列表 (空答提交时返回)
  - `rightStatus`：`0`=未校验, `1`=正确, `2`=部分正确, `3`=错误

- **答案获取技巧**：先提交 `myAnswers: [""]` (空答) → 拿到 `answers` (正确答案) → 再提交正确答案

**源码**：[player_remote_datasource.dart submitInteractiveAnswer](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L485-L509)

---

## 七、辅助接口

### 7.1 collect/batch — 播放行为埋点 (BFE/CLOG)

- **URL**：`https://imlog.ewt360.com/monitor/web/collect/batch`
- **签名**：HMAC-SHA1 (密钥为 `getPlayerGlobalConf.globalInfo.secret`)

```
sigStr = "action={action}&duration={duration}&mstid={token}"
       + "&signatureMethod=HMAC-SHA1&signatureVersion=1.0"
       + "&timestamp={ts}&version=2022-08-02"
sign   = HMAC-SHA1(secret, sigStr)   # 40 位小写 hex
```

- **请求体** (数组)：

```json
[{
  "action": 3,
  "stayTime": 0,
  "pti": 1,
  "token": "mst-xxx",
  "reportTime": 1785478092335,
  "sign": "..."
}]
```

- **action 枚举**：`1`=开始 / `2`=播放或恢复 / `3`=暂停 (检测点触发) / `4`=结束

**源码**：[crypto_utils.dart BfeSigner](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\core\crypto\crypto_utils.dart#L60-L77)

---

### 7.2 playbackProgress — 进度持久化

- **URL**：`/video/playbackProgress`
- **触发时机**：检测点 act=2 恢复后强制触发一次
- **作用**：将检测点完成后的进度写入服务端, 防止检测点完成后未持久化导致重播

---

### 7.3 cab — 用途未明 (疑似检测点开关)

- **URL**：`GET /api/homeworkprod/homework/student/cab`
- **Query**：`schoolId` / `lessonId` / `homeworkId` / `_`
- **响应**：`data: false` (实测, 当前不影响流程)

**源码**：[player_remote_datasource.dart getCab](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L555-L585)

---

### 7.4 addStudp — 上报黑名单事件 (反自动化命中)

- **URL**：`GET /api/homeworkprod/homework/student/addStudp`
- **触发时机**：浏览器检测到模拟点击 (`event.isTrusted=false`) 或 Fiber 直调 `toCheck` 时调用, 通知服务端将用户加入黑名单
- **本项目**：不主动触发, 异常情况下被动调用

**源码**：[player_remote_datasource.dart addStudp](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\ewt_auto_client\lib\features\player\data\datasources\player_remote_datasource.dart#L539-L553)

---

## 八、完整调用流程示例

### 8.1 普通用户 (非黑名单) 检测点

```http
# 1) act=3 暂停埋点 (imlog.ewt360.com)
POST /monitor/web/collect/batch
[{ "action": 3, "stayTime": 0, "pti": 1, "token": "mst-xxx", "reportTime": ..., "sign": "..." }]

# 2) 首报 (gateway, seriousCheckResult=0)
POST /api/homeworkprod/homework/student/addVideoss
Headers: token: xxx | timestamp: 17... | sign: MD5(...).upper() | secretId: 2 | platform: 1
Body: { "schoolId": 10000, "homeworkId": 10495544, "lessonId": "117890",
        "type": 1, "interactivePointId": null, "platform": 1, "seriousCheckResult": 0 }

# 3) (普通用户跳过滑块解算)

# 4) 等待 ~5s (模拟用户点击)

# 5) 二次上报 (seriousCheckResult=2, 无 captchaToken)
POST /api/homeworkprod/homework/student/addVideoss
Body: { ..., "seriousCheckResult": 2 }   # 注意无 captchaToken 字段

# 6) act=2 恢复埋点
POST /monitor/web/collect/batch
[{ "action": 2, ... }]

# 7) 进度持久化
POST /video/playbackProgress
```

### 8.2 黑名单用户检测点

```http
# 1) act=3 暂停埋点
# 2) 首报 addVideocss (seriousCheckResult=0, 无 token)
POST /api/homeworkprod/homework/student/addVideocss
Body: { ..., "seriousCheckResult": 0 }

# 3) 主动解算滑块
POST https://filegateway.ewt360.com/api/captcha/captcha/get
Body: { "bizCode": "mst1784513466143", "type": "2" }
→ { captchaSessionId, pieceY, backgroundImage, pieceImage }

POST https://filegateway.ewt360.com/api/captcha/captcha/verify
Body: { "bizCode": "mst1784513466143", "type": "2",
        "captchaSessionId": "xxx", "verifyData": "[{\"x\":187,\"y\":67}]" }
→ { verifyResult: true, captchaToken: "fb3a848b-..." }

# 4) 等待 ~5s
# 5) 二次上报 (seriousCheckResult=2, 携带 captchaToken)
POST /api/homeworkprod/homework/student/addVideocss
Body: { ..., "seriousCheckResult": 2, "captchaToken": "fb3a848b-..." }

# 6) act=2 恢复埋点
# 7) 进度持久化
```

### 8.3 降级模式 (level > 0)

```http
# 仅日志输出, 不发起上述任何请求
# 心跳循环 / 进度上报照常进行
```

---

## 九、参考

- 详细分析：[mstplayer_seriousness_check_doc.md](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\debug\player_behavior\mstplayer_seriousness_check_doc.md)
- Python 伪代码：[focus_check_flow.py](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\debug\foucs_check\focus_check_flow.py)
- 浏览器接口测试：[test_mstplayer_seriousness.py](file:///c:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\debug\player_behavior\test_mstplayer_seriousness.py)
