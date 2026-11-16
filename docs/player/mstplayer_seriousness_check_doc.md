# mstplayer-v3.0.37 认真度检测详细分析文档

> 分析对象：`mstplayer-v3.0.37.min.js` + 页面全部 29 个 ewt360 脚本
> 分析方式：源码静态分析 + 运行时对象读取 + 全量脚本关键词检索
> 关联文档：[mstplayer_behavior_doc.md](./mstplayer_behavior_doc.md)（看课埋点基础）

---

## 0. 总览

经对 mstplayer v3.0.37 源码（1.2MB）及页面全部已加载脚本的全量检索，确认当前版本中存在以下认真度检测/防作弊机制：

| 类型 | 状态 | 触发方式 | 实现位置 |
|---|---|---|---|
| **确认型** | ✅ 已实现 | 服务端返回违规错误码（699001）时弹窗 | mstplayer: `BizPoint` + `ConfirmModalPlugin` |
| **答题型（互动型）** | ✅ 已实现 | 播放到指定时间点弹出互动题 | mstplayer: `BizInteractive` + `Interactive` + `Question` |
| **反调试型** | ✅ 已实现 | 检测到 DevTools 打开时锁定页面 | mstplayer: `AliAdapter.antiDebug` + `devtools-detector` |
| **滑块型** | ✅ 已实现（业务层） | **黑名单用户**（`isBlacklisted=true`）播放到达认真度检测点时弹出滑块验证 | 业务层: `homework-play-video.js` `ek` 组件 + `ecaptcha` SDK (5564.js) |

> **关于"滑块型"的演进**：
> - **v1 结论（错误）**：只在 `mstplayer-v3.0.37.min.js` 内检索，未找到滑块型，误判为"未实现"。
> - **v2 线索（用户反馈）**：用户指出 SDK 名为 `ecaptcha`，`addVideocss` 请求可附带 `captchaToken`，可能与滑块相关。
> - **v3 结论（部分错误）**：在 `homework-play-video.79cd986cb0.js`（业务层）和 `5564.1a2748c99b.js`（ecaptcha SDK）中找到完整实现，但误将组件选择条件归为 `interactiveVideo`。
> - **v4 结论（最终）**：滑块型组件为 `ek`，**仅当 `isBlacklisted=true`（用户被加入黑名单）时渲染**；普通用户（`isBlacklisted=false`）渲染 `ev` 组件（非滑块型）。黑名单由反自动化检测（Fiber 直调 `toCheck` / 模拟点击 `event.isTrusted=false`）触发。详见第 3' 节。
>
> **关键认知**：
> - `addVideocss` ≠ "添加视频CSS"，而是"添加视频检测点（video check point）"的拼音缩写上报接口
> - `captchaToken` 是 ecaptcha 验证通过后返回的令牌，附在上报请求中证明用户已完成滑块验证
> - mstplayer SDK 内确实没有滑块型，但整个视频播放系统通过业务层集成了滑块型认真度检测
> - **滑块型是黑名单用户的加强检测**：普通用户到达检测点显示 `ev`（确认型），黑名单用户到达检测点显示 `ek`（滑块型）

除上述主动检测外，mstplayer 还内置了多项**被动防作弊机制**（拖拽限制、失焦检测、签名校验等）和**认真度检测降级机制**，业务层还包含**反自动化脚本检测**（`event.isTrusted` / Fiber 遍历检测），一并归入本文档。

---

## 1. 确认型检测（illegalModal + ConfirmModal）

### 1.1 触发条件

当看课埋点上报接口（`/monitor/web/collect/batch`）返回特定错误码时触发：

| 服务端错误码 | 客户端错误枚举 | 含义 | 是否弹窗 |
|---|---|---|---|
| `699001` | `ErrorEnum.POINT_ILLEGAL` (2002) | 看课数据非法/违规 | ✅ 弹窗（若 `illegalModal:true`） |
| `699101` | `ErrorEnum.POINT_SIGNATURE_ERROR` (1010) | 签名错误 | ❌ 不弹窗，仅 error 事件 |
| `699102` | `ErrorEnum.POINT_PARAMS_ERROR` (1011) | 参数错误 | ❌ 不弹窗，仅 error 事件 |
| 其他非 699001 | `ErrorEnum.POINT_FC` (2003) | 上报失败 | ❌ 不弹窗，`fallback=1` 回退重试 |

### 1.2 触发流程

```
fcUpload() 发送 collect/batch 请求
  └─ catch(e2):
       ├─ 699101 → POINT_SIGNATURE_ERROR → player.trigger("error") → 不弹窗
       ├─ 699102 → POINT_PARAMS_ERROR → player.trigger("error") → 不弹窗
       ├─ 非 699001 → POINT_FC + EventPackage[0].fallback=1 → 回退下一 host
       └─ 699001 → POINT_ILLEGAL → player.trigger("error")
            └─ if (illegalModal):
                 player.trigger(EConfirmModalEvent.SHOW, {
                   title: "视频已暂停",
                   content: e2.msg,
                   confirmText: "我知道了"
                 })
```

### 1.3 ConfirmModalPlugin 实现

```js
class ConfirmModalPlugin extends Plugin {
  constructor(e) {
    super(e);
    this.on(e, EConfirmModalEvent.SHOW, (t, r) => {
      // r = {title, content, confirmText, onClose}
      this.hide();
      this._modal = e.addChild("ConfirmModal", {
        title: r.title,
        content: r.content,
        confirmText: r.confirmText,
        onClose: () => { r.onClose?.(); this._modal = void 0 }
      });
      this._modal.applyMount();  // 挂载到 DOM
    });
    this.on(e, EConfirmModalEvent.HIDE, () => this.hide());
    this.on(e, "hackfullscreenchange", () => {
      // 全屏切换时重新挂载弹窗
      if (this._modal && !this._modal.isDisposed()) this._modal.applyMount();
    });
  }
}
```

### 1.4 ConfirmModal 组件

- CSS 类：`vjs-confirm-modal`
- 结构：标题（`vjs-confirm-modal__title`）+ 正文（`vjs-confirm-modal__body`）+ 关闭按钮 + 确认按钮（`vjs-confirm-modal__confirm`）
- 事件：`EConfirmModalEvent.SHOW = "mst-confirm-modal-show"`，`HIDE = "mst-confirm-modal-hide"`

### 1.5 配置

运行时实测 `pointInfo` 配置：

```json
{
  "pointInfo": {
    "videoType": 1,
    "courseId": "48419",
    "illegalModal": true       // ← 确认型检测已开启
  }
}
```

`illegalModal` 由 `pointInfo` 配置项控制，页面初始化时传入。

### 1.6 用户交互

1. 弹窗显示"视频已暂停" + 服务端返回的违规消息
2. 视频处于暂停状态（由 `ignoreUploadPause()` 控制，不再上报暂停事件）
3. 用户点击"我知道了" → 关闭弹窗 → `onClose` 回调
4. 弹窗关闭后用户需手动点击播放继续

---

## 2. 答题型检测（bizInteractive 互动题）

### 2.0 检测点位置生成逻辑（重要）

**结论：检测点（互动题触发时间点）的位置由服务端下发，客户端不生成位置，只检测 `currentTime` 是否到达。**

#### 2.0.1 涉及的服务端接口

| 接口 | 作用 | 实测响应 |
|---|---|---|
| `GET /api/homeworkprod/player/getLessonDetailV2` | 课程详情，含检测点开关 | `needCheckPoint:true, interactiveVideo:false` |
| `GET /api/homeworkprod/homework/student/getVideodp?schoolId=` | **查询用户是否在黑名单**（见 3'.7.1） | `data:true`（当前用户已在黑名单） |
| `GET /api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig?schoolId=&videoType=` | 认真度检测降级配置 | `level:0`（不降级） |
| `GET /api/videoplayerprod/videoplayer/getPlayerGlobalConf?videoBizCode=&sdkVersion=` | 播放器全局配置 | 含 `intervalTime/reportFrequency` 等 |
| 初始化时传入 `interactiveInfo` | 互动题配置列表 | 由业务层从上述接口组装 |

#### 2.0.2 位置数据流向

```
服务端                                客户端（业务层 + mstplayer）
──────                                ──────────────────────────
getLessonDetailV2 ──┐
  needCheckPoint     │
  interactiveVideo   ├─→ 业务层组装 interactiveInfo ──→ MSTPlayer.init({
  getVideodp ────────┤      (含 interactiveConfigList)      interactiveInfo: {
  getSeriousCheck     │                                         id: "sceneId",
  DownGradeConfig ───┘                                         interactiveConfigList: [
                                                                {id, interactiveTimePoint},
                                                                ...
                                                              ]
                                                            }
                                                          })
                                                          ↓
                                                    mstplayer 内部:
                                                    Interactive.startCheck()
                                                    └─ 比较 currentTime vs
                                                       interactiveTimePoint
```

#### 2.0.3 关键字段说明

- **`needCheckPoint`**（来自 `getLessonDetailV2`）：课程是否需要检测点。当前视频 `true`。
- **`interactiveVideo`**（来自 `getLessonDetailV2`）：该视频是否为互动视频（即是否配置了互动题）。当前视频 `false`。
- **`getVideodp`**：返回布尔值，**查询用户是否在黑名单**（`data:true`=在黑名单，会走滑块型检测）。当前 `true`，**当前用户已在黑名单中**。详见 3'.7.1。
- **`interactiveTimePoint`**（来自 `interactiveInfo.interactiveConfigList[]`）：互动题触发时间点（毫秒）。**此值由服务端下发，客户端不计算。**

> **注意**：`needCheckPoint:true` 与 `interactiveVideo:false` 可同时存在，说明"需要检测点"是课程级开关，而"是否有互动题"是视频级配置。当前视频启用了检测点功能但未配置互动题，因此实际不会弹出互动题。

#### 2.0.4 客户端检测逻辑（不生成位置）

`Interactive` 组件在 `startCheck` 中只做"比较"不做"生成"：

```js
startCheck() {
  if (this._current) return;             // 已有互动题展示中
  if (this.player().paused()) return;    // 暂停时不检测
  const t = this.player().currentTime();
  this.options_.interactive.interactiveConfigList.forEach(e => {
    const n = e.interactiveTimePoint / 1e3;  // ← 直接用服务端下发的值
    if (n > this._lastPlayTime && n <= t) {
      this._current = e;                  // ← 到达时间点，触发
    }
  });
}
```

#### 2.0.5 认真度检测降级机制

`getSeriousCheckDownGradeConfig` 返回降级配置：

```json
{
  "key": "downgrade.student.video.serious.check",
  "level": 0,                        // 降级级别：0=不降级，>0=降级
  "tips": "当前为使用高峰期，课程视频监测功能暂不可用",
  "description": "课程视频监测功能降级",
  "needLog": 1
}
```

- `level=0`：正常检测，所有认真度机制生效
- `level>0`：降级模式，关闭认真度检测（高峰期兜底，避免误伤）

---

### 2.1 配置结构

`MSTPlayer` 初始化时通过 `interactiveInfo` 传入互动题配置：

```js
this._player.bizInteractive({
  interactive: T.interactiveInfo,        // 互动题配置
  checkAnswer: e => ...,                 // 自定义答案校验（可选）
  answerMore: { videoBizCode, lessonId },// 附加参数
  skipCountdown: n.skipCountdown,        // 跳过倒计时（秒）
  markers: r                             // 进度条标记点
});
```

`interactiveInfo` 结构：

```json
{
  "id": "interactiveSceneId",            // 互动场景ID
  "interactiveConfigList": [             // 互动题配置列表
    {
      "id": "configId_1",                // 互动配置ID
      "interactiveTimePoint": 60000      // 触发时间点（毫秒）
    },
    {
      "id": "configId_2",
      "interactiveTimePoint": 180000
    }
  ]
}
```

### 2.2 触发机制

`Interactive` 组件在 `startCheck` 中以 ~60fps 检测（`setTimeout(1e3/60)`）：

```js
startCheck() {
  if (this._current) return;             // 已有互动题展示中，不检测
  if (this.player().paused()) return;    // 暂停时不检测
  
  const t = this.player().currentTime();
  let r = false;                         // 是否有未来的互动题
  
  this.options_.interactive.interactiveConfigList.forEach(e => {
    if (this._lockMap[e.id]) return;     // 已完成且锁定的跳过
    
    const n = e.interactiveTimePoint / 1e3;  // 触发时间点（秒）
    
    if (n > this._lastPlayTime) {        // 正向播放（非拖拽回退）
      r = true;
      // 预加载：距触发时间 <= preLoadTime 时提前加载详情
      if (n - t <= this._preLoadTime) this.initDetail(e);
      // 触发：当前时间 >= 触发时间点
      if (n <= t) this._current = e;
    }
  });
  
  this._lastPlayTime = t;
  
  if (this._current) this.show();        // 显示互动题
  else if (r) this._timer = setTimeout(() => this.startCheck(), 1e3/60);
}
```

**预加载时间**：`PRE_TIME`（常量），根据播放倍速动态调整：`_preLoadTime = PRE_TIME * playbackRate`

### 2.3 显示流程（`show` 方法）

```js
show() {
  // 1. 暂停播放器，隐藏控制栏
  this.player().pause();
  this.player().controlBar.hide();
  this.player().topBar.hide();
  this._isLastHidden = document.hidden;  // 记录弹窗时页面可见性
  
  // 2. 获取/加载互动题详情
  const e = this._current;
  let r = this.getDetail(e);             // 从缓存获取
  if (!r) r = yield this.doLoadDetail(e); // 调用 API 加载
  
  // 3. 触发事件
  this.player().trigger(InteractiveEvent.INIT, {info: t});
  this.player().trigger(InteractiveEvent.START, {info: r});
  
  // 4. 渲染题目
  this.questionLayer = new Question({
    ...r,
    parent: this.container,
    width: i,
    skipCountdown: this.options_.skipCountdown,
    onSkip, onOptionClick, onSubmitClick, onCheckAnswer
  });
}
```

### 2.4 API 接口

#### 获取互动题详情

```
GET //gateway.ewt360.com/api/videoplayerprod/videoplayer/getInteractiveConfigDetail
```

**Query 参数**：

| 参数 | 类型 | 说明 |
|---|---|---|
| `interactiveConfigId` | string | 互动配置ID（`interactiveConfigList[].id`） |
| `videoBizCode` | string | 视频业务码（如 `1013`） |

**请求头**：

```
Accept: application/json, text/plain, */*
Content-Type: application/json
token: <用户token>
```

**响应结构**（推测，基于源码使用方式）：

```json
{
  "code": 0,
  "data": {
    "id": "configId_1",
    "interactiveSceneId": "sceneId",
    "question": {
      "id": "questionId",
      "cate": 1,                          //_cateEnum: 1=单选 2=多选 3=判断
      "questionContentType": 1,           // QuestionContentTypeEnum: 1=图片 2=视频
      "imageUrl": "https://...",          // 题目图片（contentType=1时）
      "answers": ["A", "B"]               // 正确答案
    }
  }
}
```

#### 提交答案

```
POST //gateway.ewt360.com/api/videoplayerprod/videoplayer/submitAnswer
```

**请求体**：

```json
{
  "interactiveSceneId": "sceneId",        // 互动场景ID
  "questionId": "questionId",             // 题目ID
  "myAnswers": ["A"],                     // 用户选择的答案
  "totalSeconds": 15,                     // 答题耗时（秒）
  "videoBizCode": "1013",                 // 视频业务码
  "lessonId": "117890"                    // 课程ID
}
```

**响应**：

```json
{
  "code": 0,
  "data": {
    "rightStatus": 1                      // RightStatusEnum
  }
}
```

### 2.5 枚举定义

```js
// 题目类型
CateEnum = { RADIO: 1, MULTI_SELECT: 2, JUDGE: 3 }

// 题目内容类型
QuestionContentTypeEnum = { IMAGE: 1, VIDEO: 2 }

// 答案状态
RightStatusEnum = { UNCHECK: 0, CORRECT: 1, HALF_CORRECT: 2, INCORRECT: 3 }

// 互动结束方式
InteractiveEndEnum = {
  NORMAL: 0,         // 正常答题后关闭
  SKIP: 1,           // 用户手动跳过
  AUTO_SKIP: 2,      // 倒计时自动跳过
  ANSWER_SKIP: 3,    // 未校验答案直接关闭（rightStatus=UNCHECK）
  INIT_SKIP: 4       // 初始化失败跳过
}

// 互动错误类型
InteractiveErrorEnum = { LOAD_DETAIL: 0, ANSWER: 1 }

// 互动事件
InteractiveEvent = {
  INIT: "interactiveinit",
  START: "interactivestart",
  END: "interactiveend",
  OPTION: "interactiveoption",
  SUBMIT: "interactivesubmit",
  SKIP: "interactiveskip",
  ERROR_SKIP: "interactiveerrorskip",
  ERROR_RETRY: "interactiveerrorretry"
}
```

### 2.6 答题流程

```js
onCheckAnswer(e) {
  const t = yield this.doCheckAnswer(e, r, n);
  if (n !== this._forceStopKey) return;
  
  if (t === RightStatusEnum.UNCHECK) {
    // 未校验 → 直接关闭
    this.hideWithType(InteractiveEndEnum.ANSWER_SKIP, r);
  } else {
    // 显示答题结果（正确/错误）
    yield this.endLayer.show(t === RightStatusEnum.CORRECT);
    if (n !== this._forceStopKey) return;
    this.hideWithType(InteractiveEndEnum.NORMAL, r);
  }
}
```

### 2.7 关闭与恢复（`hideWithType`）

```js
hideWithType(e, t) {
  this.hide();                           // 隐藏弹窗
  this.questionLayer = void 0;
  this.player().controlBar.show();       // 恢复控制栏
  this.player().topBar.show();           // 恢复顶栏
  
  // 锁定该互动题，防止重复触发（500ms 后解锁）
  const n = this._current?.id;
  if (n) {
    this._lockMap[n] = true;
    this.setTimeout(() => delete this._lockMap[n], 500);
  }
  
  this._current = void 0;
  this.player().trigger(InteractiveEvent.END, {type: e, info: t});
  this.player().silencePlay();           // 自动继续播放
}
```

### 2.8 跳过逻辑

- `skipCountdown` 配置控制是否允许跳过及倒计时秒数
- 倒计时结束后自动跳过（`InteractiveEndEnum.AUTO_SKIP`）
- 用户手动跳过 → `InteractiveEndEnum.SKIP`
- 拖拽进度（`MSTPlayerEvent.SEEK`）时 `forceStop()` 强制关闭当前互动题

### 2.9 进度条标记

互动题在进度条上显示标记点（菱形标记）：

```js
e.controlBar.getChild("progressControl").showMarkers(
  i.interactiveConfigList.map(e => ({ time: e.interactiveTimePoint / 1e3 }))
);
```

### 2.10 加载失败处理

```js
doLoadDetail(e, t) {
  this.loadingLayer.show("题目加载中，请稍等");
  try {
    const r = yield this.initDetail(e);  // 调用 getInteractiveConfigDetail
    this.loadingLayer.hide();
    return r;
  } catch(e2) {
    this.loadingLayer.showRetry(() => ...);  // 显示"重试"按钮
    // 触发 InteractiveEvent.ERROR_SKIP
  }
}
```

---

## 3. 反调试型检测（antiDebug + devtools-detector）

**这是 mstplayer v3.0.37 实际实现的"第三种认真度检测"**，由 `AliAdapter`（阿里云视频播放器适配器）提供，基于 `devtools-detector` 库。前版文档误标注为"滑块型（未找到）"，本次更正。

### 3.1 配置

```js
// AliAdapter.defaultConfig
{
  mediaType: "",
  authTimeout: 7200,
  enableLog: true,
  antiDebug: false   // ← 默认关闭，由业务层通过配置开启
}

// 初始化时，若 antiDebug=true 则启动反调试检测
n.antiDebug && n5fg6f(i, true);
```

### 3.2 检测器（6 种）

使用 `devtools-detector` 库（npm 包），内置 6 种检测器：

```js
new DevtoolsDetector({
  checkers: [
    elementIdChecker,         // 检测 DevTools 特定 DOM 元素
    regToStringChecker,       // RegExp.toString() 行为检测
    functionToStringChecker,  // Function.toString() 行为检测
    depRegToStringChecker,    // 依赖 RegExp.toString 的深度检测
    dateToStringChecker,      // Date.toString() 行为检测
    debuggerChecker           // debugger 语句执行时差检测
  ]
})
```

### 3.3 触发行为（极其激进）

检测到 DevTools 打开时，按顺序执行：

```js
var fs56j57 = "debugger";

// 1. 清空所有 console 方法
function kl5f8() {
  window && ["info","log","debug","warn","error","dir","dirxml","table"].forEach(
    e => window.console[e] = function() {}
  );
}

// 2. 死循环 debugger（卡死页面）
function gas4s8() { for(;;) eval(fs56j57); }

// 3. 主逻辑
function n5fg6f(adapter, enable) {
  setTimeout(function() {
    function cl48s87(isOpen) {
      if (isOpen && enable) {
        eval(fs56j57);              // 触发 debugger 断点
        if (enable) {
          kl5f8();                  // ① 清空 console
          adapter.dispose();        // ② 销毁播放器实例
          gas4s8();                 // ③ 死循环 debugger（页面卡死）
        } else {
          // 关闭时移除监听并停止检测
          devtools_detector_js_1.default.removeListener(cl48s87);
          devtools_detector_js_1.default.setDetectDelay(0);
          devtools_detector_js_1.default.stop();
        }
      }
    }
    devtools_detector_js_1.default.addListener(cl48s87);
    devtools_detector_js_1.default.launch();   // 启动检测循环
  }, document.body ? 0 : 100);
}
```

### 3.4 DevtoolsDetector API

| 方法 | 作用 |
|---|---|
| `launch()` | 启动检测循环 |
| `stop()` | 停止检测循环 |
| `isLaunch()` | 是否已启动 |
| `setDetectDelay(ms)` | 设置检测间隔（毫秒） |
| `addListener(cb)` | 添加状态变化监听器，`cb(isOpen, event)` |
| `removeListener(cb)` | 移除监听器 |

### 3.5 运行时实测

当前视频（`lessonId=117890`）的播放器实例：

```js
player.usingPlugin()
// → ["bizPoint", "progressPoint", "userInfo", "confirmModal"]
// 注意：无 "bizInteractive"（当前视频无互动题）
// 注意：antiDebug 是 AliAdapter 配置，非 MSTPlayer plugin，不在此列表
```

`antiDebug` 默认关闭，当前视频未启用反调试检测。是否启用由业务层在初始化 `AliAdapter` 时通过 `antiDebug:true` 配置决定。

### 3.6 与滑块型的关系

反调试型与滑块型是两种不同的认真度检测机制：
- **反调试型**：检测开发者工具，防止逆向分析（mstplayer v3.0.37 内 AliAdapter 已实现，但默认关闭）
- **滑块型**：人机验证，防止自动化脚本（mstplayer v3.0.37 内未实现，但**业务层** `homework-play-video.js` + `ecaptcha` SDK 已实现，详见第 3' 节）

用户提到的 `addVideocss` + `captchaToken` 经核实**确实存在**，属于业务层滑块型检测的上报接口与令牌，与 mstplayer SDK 解耦。

---

## 3'. 滑块型检测（ecaptcha，业务层实现，已找到）

**重大更正**：前版文档标注"滑块型未找到"是因为只在 `mstplayer-v3.0.37.min.js` 内检索。实际上，**滑块型认真度检测由业务层（bend 作业播放页）实现，与 mstplayer SDK 独立**，使用独立的 `ecaptcha` SDK。本次在 `homework-play-video.79cd986cb0.js` 和 `5564.1a2748c99b.js` 中找到完整实现。

> **v4 关键纠正**：业务层有两个认真度检测组件 `ev` 和 `ek`，由 `isBlacklisted`（用户是否在黑名单）决定渲染哪个：
> - **`ev` 组件**（`isBlacklisted=false`，普通用户）：非滑块型，`componentDidMount` 仅上报 `initLog`，等待用户点击"我知道了"后上报 `successLog`
> - **`ek` 组件**（`isBlacklisted=true`，黑名单用户）：**滑块型**，`componentDidMount` 上报 `initLog` 后立即初始化 ecaptcha 滑块验证
>
> 黑名单触发方式（调用 `updateIsBlacklisted`）：反自动化检测命中（详见 3'.7）

### 3'.1 实现位置

| 文件 | 作用 | 关键内容 |
|---|---|---|
| `homework-play-video.79cd986cb0.js`（108KB） | 作业播放视频页业务逻辑 | `ev`（普通）/ `ek`（滑块）组件、`renderEarnestCheck`、`addVideocss` 上报、检测点生成 |
| `5564.1a2748c99b.js`（66KB） | **ecaptcha SDK** | 滑块验证码完整实现（get/verify API、UI 渲染、事件处理） |
| `styles.71e7c32633.js` 模块 27037 | CSS 样式 | `spc_video_earnest_check_box`、`ecaptcha-slide-container` 等类名 |

> **关键认知**：`addVideocss` 不是 CSS 相关接口，而是"添加视频检测点（video check point）"的拼音缩写接口，用于上报认真度检测结果。`captchaToken` 是 ecaptcha 验证通过后返回的令牌，附带在上报请求中证明用户已完成滑块验证。

### 3'.1.1 组件选择逻辑（renderEarnestCheck）

```js
// homework-play-video.js 中的 renderEarnestCheck 方法
renderEarnestCheck = () => {
  let r = this.context?.isBlacklisted;                    // ← 是否在黑名单
  let {earnestCheckVisible:i, ...} = this.state;
  if (!i || !this.oEplayer) return null;                  // ← earnestCheckVisible 必须 true
  
  let m = {lessonId, homeworkId, contentType, videoCheckPoint, 
           interactiveVideo: this.state.currentLesson?.interactiveVideo, ...};
  
  return createPortal(
    r ? createElement(ek, m)    // ← isBlacklisted=true  → ek（滑块型）
      : createElement(ev, m),   // ← isBlacklisted=false → ev（普通确认型）
    this.oEplayer.getHackDoms().base
  );
};
```

**触发条件链**：
1. 客户端生成 `videoCheckPoint` 检测点数组（详见 3'.1.2）
2. 播放时间 `N` 到达检测点（`R.includes(N) || R.includes(N-1)`）→ `earnestCheckVisible=true`
3. 根据 `isBlacklisted` 渲染 `ev`（普通）或 `ek`（滑块）

### 3'.1.2 检测点位置生成（客户端生成，非服务端下发）

**重要纠正**：前版文档说"检测点位置由服务端下发"是针对**互动题**（`interactiveTimePoint`）。**认真度检测点（`videoCheckPoint`）由客户端生成**，基于视频时长和互动题位置计算：

```js
// Z = 视频总时长（秒），t = interactiveConfigList.length（互动题数量）
if (有互动题) {
  if (t >= 3 || Z <= 480) return noAddPoint(Z);            // 互动题≥3 或视频≤8分钟 → 不加
  let s = Math.ceil(interactiveConfigList[t-1].interactiveTimePoint / 1e3) + 120;  // 最后互动题+120s
  let o = Math.ceil(0.8 * Z);                              // 视频80%时长
  if (s >= o) return noAddPoint(Z);
  if (Z <= 900) {                                          // ≤15分钟
    if (t >= 2) return noAddPoint(Z);
    R = ea.MH(s+1, o, 1, 120);                             // 1个检测点
  } else {                                                 // >15分钟
    let e = 3 - t;                                         // 检测点数=3-互动题数
    R = ea.MH(s+1, o, e, 120);
  }
} else if (Z > 180) {                                      // 无互动题 且 视频>3分钟
  let t = (M = (Z-120)*0.8) + 120;
  M > 0 && M <= 360 && (R = ea.MH(121, t, 1));             // 1个检测点
  M > 360 && M <= 720 && (R = ea.MH(121, t, 2));           // 2个检测点
  M > 720 && (R = ea.MH(121, t, 3));                       // 3个检测点
}
this.setState({videoCheckPoint: R});

// 触发：播放时间到达检测点
R && R.length && !V && (R.includes(N) || R.includes(N-1)) && (
  this.setState({earnestCheckVisible: true, currentCheckTime: N})
);
```

`ea.MH(start, end, count, minInterval)` 是工具函数，在 `[start, end]` 区间生成 `count` 个时间点，最小间隔 `minInterval` 秒。

### 3'.2 ecaptcha SDK 初始化（仅 ek 组件）

```js
// homework-play-video.js 中 ek 组件的 componentDidMount
class ek extends Component {
  componentDidMount() {
    let {lessonId:t, homeworkId:s, contentType:o, oEplayer:r, 
         interactiveVideo:i, title:n} = this.props;
    r && r.pause && (r.pause(), r.disableHotKeys && r.disableHotKeys());
    
    // 1. 上报 initLog
    let a = {
      qtData: {video_type: i ? "video_interact" : 11===o ? "video_school" : "video_record", ...},
      interfaceData: {
        homeworkId: s, lessonId: 11===o ? Number(t)+2e6 : t,
        type: i ? 3 : (1===o ? 1 : 2),         // ← type 计算（见 3'.6）
        interactivePointId: i ? 100 : null,     // ← 取决于 interactiveVideo
        platform: 1, seriousCheckResult: 0      // initLog
      }
    };
    this.reportVideoPoint(a.interfaceData);
    
    // 2. 初始化 ecaptcha 滑块（仅 ek 组件有此逻辑）
    new(eg())("#captcha", {
      bizCode: "mst1784513466143",   // 业务码：mst(视频) + 时间戳
      type: "2",                      // 验证码类型：2=滑块
      env: "prod",                    // 环境
      isSafeControl: false            // 是否走安全中心控制
    }).success(async e => {
      // e = { captchaToken: "xxx" }
      clearInterval(this.timerId);
      // 上报 successLog + captchaToken
      let u = {
        interfaceData: {
          ..., 
          seriousCheckResult: 2,              // 2=successLog
          captchaToken: e?.captchaToken       // ← 滑块验证令牌
        }
      };
      await this.reportVideoPoint(u.interfaceData) && (
        callback(true),
        message.success("你真棒，通过检测～"),
        player.play()
      );
    });
  }
}
```

### 3'.3 ecaptcha API 接口

| 接口 | 方法 | 作用 | Host |
|---|---|---|---|
| `/api/captcha/captcha/get` | POST | 获取验证码图片 | `filegateway.ewt360.com` |
| `/api/captcha/captcha/verify` | POST | 验证用户操作 | `filegateway.ewt360.com` |
| `/api/commondata/server/gettime` | GET | 服务器时间 | `gateway.ewt360.com` |
| `/api/safecenter/business/control/type` | POST | 业务控制类型 | `gateway.ewt360.com` |

#### getCaptchaImg 请求（获取滑块图）

```json
POST https://filegateway.ewt360.com/api/captcha/captcha/get
Content-Type: application/json

{
  "bizCode": "mst1784513466143",
  "type": "2",
  "mobile": "",                    // 用户手机号（可选）
  "deviceToken": "",               // 设备令牌（可选）
  "token": "",                     // 用户 token（可选）
  "timestamp": 1785478092335,      // 当前时间戳
  "checkSign": "md5(bizCode + mobile + deviceToken + token + timestamp + 'eo^nye1j#!wt2%v)')"
}
```

**checkSign 签名算法**（密钥 `eo^nye1j#!wt2%v)`，md5）：

```js
var SECRET = "eo^nye1j#!wt2%v)";
var timestamp = new Date().getTime();
var checkSign = md5(bizCode + mobile + deviceToken + token + timestamp + SECRET);
```

**响应**：

```json
{
  "code": "200",
  "data": {
    "captchaSessionId": "session_xxx",
    "captchaImgBase64": "data:image/png;base64,...",
    "captchaToken": ""              // 免验证时直接返回 token（黑名单用户不会免验证）
  },
  "msg": ""
}
```

- `captchaImgBase64`：滑块拼图图片（base64）
- `captchaSessionId`：验证会话ID
- `captchaToken`：若服务端判定无需验证（白名单），直接返回 token

#### captchaValidate 请求（验证滑块）

```json
POST https://filegateway.ewt360.com/api/captcha/captcha/verify
Content-Type: application/json

{
  "bizCode": "mst1784513466143",
  "type": "2",
  "captchaSessionId": "session_xxx",
  "verifyData": "[{\"x\":123,\"y\":45},...]"   // JSON.stringify(marks)，用户拖动轨迹
}
```

**响应**：

```json
{
  "code": "200",
  "data": {
    "verifyResult": true,           // 验证结果
    "captchaToken": "token_xxx"     // 验证令牌（成功时返回）
  },
  "msg": ""
}
```

### 3'.4 ecaptcha UI 结构（CSS 类名）

```html
<div class="ecaptcha_wrapper_content">
  <div class="ecaptcha-slide-container">
    <div class="ecaptcha-slide-wrapper">
      <img class="ecaptcha-slide-img" src="data:image/png;base64,...">  <!-- 背景图 -->
      <img class="ecaptcha-slide-img__ext" src="data:image/png;base64,...">  <!-- 滑块图 -->
    </div>
    <div class="ecaptcha-slide-toolsbar">...</div>
  </div>
  <div class="ecaptcha-slidebar-wrapper">
    <div class="ecaptcha-slidebar-inner ecaptcha-slidebar-inner__normal">
      <div class="ecaptcha-slidebar-inner-button ecaptcha-slidebar-inner-button__normal">
        &gt;&gt;                    <!-- 拖动按钮 -->
      </div>
      <div class="ecaptcha-slidebar-tip">向右拖动滑块完成验证</div>
    </div>
  </div>
</div>
```

状态类名：`__normal` / `__active` / `__success` / `__fail`

### 3'.5 触发流程

```
1. 用户触发反自动化检测 → updateIsBlacklisted → isBlacklisted=true（加入黑名单）
   ├─ Fiber 遍历直调 toCheck 方法
   ├─ 模拟点击（event.isTrusted=false）认真度检测通过按钮
   └─ 模拟点击播放列表 lesson-item
   ↓
2. 客户端生成 videoCheckPoint 检测点数组（基于视频时长和互动题位置）
   ↓
3. 播放时间 N 到达检测点（R.includes(N) || R.includes(N-1)）
   → earnestCheckVisible=true
   ↓
4. renderEarnestCheck 根据 isBlacklisted 渲染组件：
   ├─ isBlacklisted=false → ev 组件（普通确认型，无滑块）
   └─ isBlacklisted=true  → ek 组件（滑块型）
       ↓
5. ek.componentDidMount:
   ├─ 上报 initLog（seriousCheckResult:0）
   ├─ 暂停播放器（player.pause + disableHotKeys）
   └─ 初始化 ecaptcha：new eg()("#captcha", {bizCode, type:"2", env:"prod"})
       ↓
6. 弹出 spc_video_earnest_check_box：
   "认真度检测"
   "近期看课操作异常，请您完成下方检测。"
   "将图形拖动至正确位置："
   [ecaptcha 滑块组件]
   "30s 后将错过当前检测"
   ↓
7. 用户拖动滑块 → 调用 captcha/verify 验证
   ├─ 成功 → 返回 captchaToken
   │   ↓
   │ 8. 上报 addVideocss（seriousCheckResult:2 + captchaToken）
   │   ↓
   │ 9. "你真棒，通过检测～" → player.play() 继续播放
   │
   └─ 失败 → "验证失败，请按提示重新操作～" → 重新加载图片
   ↓
10. 30s 倒计时结束未完成 → "你错过了检测" → 上报 errorLog（seriousCheckResult:1）
```

> **关键**：滑块型（ek 组件）**仅对黑名单用户**显示。普通用户到达检测点显示 ev 组件（无滑块，点击"我知道了"即可）。黑名单由反自动化检测触发，一旦加入后续检测点都会走滑块型。

### 3'.6 addVideocss 上报接口

```json
POST https://gateway.ewt360.com/api/homeworkprod/homework/student/addVideocss
Content-Type: application/json
token: <用户token>

{
  "homeworkId": 10495544,
  "lessonId": 117890,              // 11年级特殊：Number(lessonId) + 2e6
  "type": 1,                       // ← 见下方 type 枚举（取决于 interactiveVideo 和 contentType）
  "interactivePointId": 100,       // ← interactiveVideo?100:null（不是固定 100）
  "platform": 1,
  "seriousCheckResult": 2,         // 0=initLog, 1=errorLog, 2=successLog
  "captchaToken": "token_xxx"      // 仅 successLog 时携带
}
```

**`seriousCheckResult` 枚举**：

| 值 | 含义 | 触发时机 |
|---|---|---|
| 0 | initLog | 检测弹窗显示时（初始化上报） |
| 1 | errorLog | 检测失败/错过时 |
| 2 | successLog | 检测通过时（携带 captchaToken） |

**`type` 枚举**（源码：`type: interactiveVideo ? 3 : (contentType===1 ? 1 : 2)`）：

| 值 | 含义 | 触发条件 |
|---|---|---|
| 1 | 普通视频 | `interactiveVideo=false` 且 `contentType=1` |
| 2 | 其他非互动视频 | `interactiveVideo=false` 且 `contentType≠1`（含 contentType=11 校长寄语及其他） |
| 3 | 互动视频 | `interactiveVideo=true` |

> **纠正**：前版文档说"type=2 为校长寄语视频（contentType≠1 且非 11）"是**错误**的。源码 `1===o?1:2` 中 o=contentType，contentType=11 时 11≠1 故 type=2。type=2 实际包含所有 `contentType≠1` 的非互动视频。

**`interactivePointId`**（源码：`interactivePointId: interactiveVideo ? 100 : null`）：

| 值 | 触发条件 |
|---|---|
| `100` | `interactiveVideo=true`（互动视频） |
| `null` | `interactiveVideo=false`（非互动视频） |

> **纠正**：前版文档说"滑块型固定 100"是**错误**的。`interactivePointId` 取决于 `interactiveVideo`，与是否滑块型（isBlacklisted）无关。滑块型（ek 组件）的 `interactivePointId` 也遵循此规则：互动视频→100，非互动视频→null。

### 3'.7 反作弊机制（业务层）

业务层 `homework-play-video.js` 还内置了反自动化脚本检测：

```js
// 1. 检测 Fiber 遍历直接调用 toCheck 方法
this.toCheck = () => {
  if (!em) {
    em = true;
    this.context.updateIsBlacklisted({
      type: "UNTRUSTED_EVENT",
      desc: "【学生看课使用插件】认真度检测-Fiber直调toCheck",
      message: "检测到对toCheck方法的直接调用（Fiber遍历），疑似脚本操作",
      lessonId, homeworkId, url: window.location.href
    });
  }
};

// 2. 检测模拟点击（event.isTrusted=false）
this._nativeClickHandler = async e => {
  if (!e.isTrusted || !(e instanceof MouseEvent)) {
    // 模拟点击 → 加入黑名单
    this.context.updateIsBlacklisted({
      type: "UNTRUSTED_EVENT",
      desc: "【学生看课使用插件】认真度检测-模拟点击通过",
      message: "检测到对认真度检测的模拟点击，event.isTrusted=false",
      lessonId, homeworkId, url
    });
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
    return;
  }
  // 真实点击 → 正常流程
};

// 3. 检测点上报接口也检测模拟点击
this.reportVideoPoint = async e => {
  if (!em) {
    em = true;
    // ...加入黑名单
  }
};

// 4. 播放列表点击也检测
// "检测到对lesson-item的模拟点击，event.isTrusted=false"
```

### 3'.7.1 黑名单状态的服务端持久化（重要纠正）

**v5 重大纠正**：前版文档说"黑名单由反自动化检测触发，保存在前端 React Context state"是**不完整**的。实际上**黑名单状态保存在服务端**，前端通过两个接口与服务端同步：

#### 涉及接口

| 接口 | 作用 | 方法 | 返回 |
|---|---|---|---|
| `GET /api/homeworkprod/homework/student/getVideodp` | **查询用户是否在黑名单** | GET | `{success:true, data:bool}`（true=在黑名单） |
| `GET /api/homeworkprod/homework/student/addStudp` | **上报黑名单事件**（反自动化检测命中时调用） | GET | 无业务数据返回 |

> **接口名误解纠正**：
> - `getVideodp` 不是"获取视频检测点全局开关"，而是"查询用户是否在黑名单"。`data:true` 表示**用户已在黑名单**，会走滑块型检测。
> - `addStudp`（add student dp）是"上报学生检测点违规事件"，通知服务端将用户加入黑名单。

#### 源码实现（React Context Provider）

```js
// homework-play-video.js 中的 Context Provider 实现
let B = createContext({
  isBlacklisted: false,
  updateIsBlacklisted: async e => {},
  getVideodp: async () => {}
});

let O = e => {                    // Provider 组件
  let {children: t} = e;
  let [s, o] = useState(false);   // s = isBlacklisted，初始 false
  
  // 1. getVideodp：查询服务端黑名单状态
  let r = async () => {
    try {
      let {data: e} = await p.WY({
        url: "/api/homeworkprod/homework/student/getVideodp",
        method: "GET", params: {}
      });
      o(!!e);                     // ← data:true → setIsBlacklisted(true)
    } catch(e) { console.error(e) }
  };
  
  // 2. updateIsBlacklisted：上报黑名单事件到服务端
  let a = async function() {
    let e = arguments[0] || {};   // 黑名单事件详情（type, desc, message, lessonId...）
    try {
      await p.WY({
        url: "/api/homeworkprod/homework/student/addStudp",
        method: "GET", params: {}  // ← 注意：事件详情 e 未作为参数传递！
      });
    } catch(e) { console.error(e) }
    // 事件详情通过阿里云日志上报（aliLogJs）
    A.ZP.warn(e, A.vY.student_watch_class_anticheat);
  };
  
  return createElement(B.Provider, {
    value: {isBlacklisted: s, updateIsBlacklisted: a, getVideodp: r}
  }, t);
};
```

#### 调用时机

```js
// initVideoPlayer 和 changeVideo 中调用 getVideodp
initVideoPlayer = async () => {
  this.context?.getVideodp();     // ← 每次初始化/切换视频都查询黑名单状态
  ...
}

changeVideo = async () => {
  this.context?.getVideodp();     // ← 切换视频时重新查询
  ...
}
```

#### 黑名单状态流转

```
┌───────────── 服务端 ─────────────┐
│  用户黑名单状态（持久化存储）      │
│  data: true / false              │
└──────────────────────────────────┘
        ↑ getVideodp 查询          ↓ addStudp 上报
┌───────────── 前端 ──────────────┐
│  React Context state             │
│  isBlacklisted: bool             │
│                                  │
│  初始化时 getVideodp → 读取状态  │
│  反自动化检测命中 → addStudp 上报│
│  → 服务端持久化 → 下次 getVideodp│
│    返回 true                     │
└──────────────────────────────────┘
        ↓ isBlacklisted 决定
┌───────────── 渲染 ──────────────┐
│  isBlacklisted=false → ev 组件   │
│  isBlacklisted=true  → ek 组件   │
│                      （滑块型）   │
└──────────────────────────────────┘
```

#### 实测验证

```bash
# 用当前用户 token 调用 getVideodp
curl 'https://gateway.ewt360.com/api/homeworkprod/homework/student/getVideodp' \
  -H 'token: 160000000-1-xxxxxxxxxxxxxxxx'

# 响应：
# {"success":true,"code":"200","msg":"操作成功","data":true}
#                                                                      ↑↑↑
#                              当前用户已在黑名单中！会走滑块型检测
```

> **关键结论**：
> 1. **黑名单状态保存在服务端**，非纯前端 state
> 2. 每次初始化/切换视频，前端通过 `getVideodp` 查询当前黑名单状态
> 3. 反自动化检测命中时，前端调用 `addStudp` 通知服务端，服务端持久化黑名单记录
> 4. `addStudp` 的事件详情（type/desc/message）**未通过接口参数传递**，而是通过阿里云日志（`aliLogJs` 的 `A.ZP.warn`）上报
> 5. **当前实测用户（USER_ID=160000000）已在黑名单中**（`data:true`），会走滑块型检测

### 3'.8 与 mstplayer 的关系

```
┌─────────────────────────────────────────────────────────┐
│                    业务层 (bend)                          │
│  homework-play-video.js                                  │
│  ├── 检测到异常 → 弹出 spc_video_earnest_check_box       │
│  ├── 初始化 ecaptcha (new Captcha("#captcha", {...}))    │
│  ├── 用户拖动滑块 → captcha/verify → captchaToken        │
│  └── 上报 addVideocss (seriousCheckResult + token)       │
│         │                                                 │
│         │ 独立调用                                         │
│         ↓                                                 │
│  ecaptcha SDK (5564.js)                                   │
│  ├── captcha/get  (获取滑块图)                            │
│  ├── captcha/verify (验证)                               │
│  └── UI 渲染 (ecaptcha-slide-*)                          │
└─────────────────────────────────────────────────────────┘
                          │ 独立
                          ↓
┌─────────────────────────────────────────────────────────┐
│              mstplayer SDK (v3.0.37)                      │
│  ├── 确认型 (699001 → ConfirmModal)                      │
│  ├── 答题型 (bizInteractive → Interactive)               │
│  └── 反调试型 (antiDebug → devtools-detector)            │
│      （mstplayer 内无滑块型）                             │
└─────────────────────────────────────────────────────────┘
```

**结论**：滑块型认真度检测由**业务层**实现，调用独立的 `ecaptcha` SDK，与 `mstplayer` SDK 完全解耦。mstplayer 内确实没有滑块型实现，但整个视频播放系统具备滑块型认真度检测能力。

---

## 4. 被动防作弊机制

除弹窗式认真度检测外，mstplayer 还内置以下防作弊机制：

### 4.1 拖拽进度条禁用

```js
// 初始化时，若 dragProgressBarDisable=true
if (h) {  // h = dragProgressBarDisable
  this._player.controlBar.getChild("progressControl").disable();
}
```

- 配置项：`dragProgressBarDisable`
- 效果：整个进度条控件被禁用，用户无法拖拽跳转

### 4.2 拖拽越界检测（seekOutOfRange）

```js
// 在 loadedmetadata 事件中
const e = Number(T.viewPlayedProgressInfo?.videoPlayedProgress) || 0;  // 服务端已观看进度
const r = $.videoPlayedProgress?.differenceValue || 5;                  // 允许差值（默认5秒）

if (!isIOS() && e && t - e > r) {
  // 当前时间 - 已观看进度 > 差值 → 重置到已观看进度
  this._player.currentTime(e);
  this._player.one("play", () => {
    this._player.addChild("progressModel");  // 显示提示弹窗
  });
}
```

- `viewPlayedProgressInfo.videoPlayedProgress`：服务端返回的已观看进度（秒）
- `videoPlayedProgress.differenceValue`：允许的误差（默认 5 秒）
- 超出范围时重置 `currentTime` 到已观看进度，并显示"视频升级，本课从头播放"提示

### 4.3 seek 方法越界检测

```js
seek(e) {
  const n = this._player.currentTime();
  const i = this._player.duration();
  let o = Math.max(0, e);
  
  if (o > i) {
    // 目标时间 > 总时长 → 重置为 0
    o = 0;
    this._player.trigger(EToastEvent.TOAST_SHOW, {
      type: EToastType.error,
      content: this._options.seekOutOfRangeWord  // "视频升级，本课从头播放"
    });
  }
  
  this._player.currentTime(o);
  this._player.trigger(MSTPlayerEvent.SEEK, {from: n, to: o});
}
```

### 4.4 页面失焦检测（visibilitychange）

```js
// ProgressPoint 插件
onVisibilityChange() {
  if (document.hidden && this.player && !this.player.paused()) {
    this.sendInfo();  // 页面隐藏且正在播放 → 立即上报进度
  }
}

// 每隔 reportFrequency 秒（默认300秒）定时上报
e.on("play", () => {
  this._timer = setInterval(() => this.sendInfo(), 1e3 * this._reportFrequency);
});
```

- 页面切到后台（`document.hidden = true`）且视频仍在播放 → 立即上报当前进度
- 每 `reportFrequency` 秒（默认 300 秒）定时上报
- 使用 `navigator.sendBeacon` 确保页面关闭时也能发送

### 4.5 播放进度上报 API

```
POST //bfe.ewt360.com/video/playbackProgress
```

使用 `navigator.sendBeacon` 发送 `FormData`：

| 参数 | 说明 |
|---|---|
| `userId` | 用户ID |
| `lessonId` | 课程ID |
| `playedProgress` | 已播放进度（currentTime，秒） |
| `videoBizCode` | 视频业务码 |

### 4.6 互动题弹窗时页面可见性检测

```js
// show() 方法中
this._isLastHidden = document.hidden;

// startCheck() 中
if (this._current) {
  this._logger.warn({
    type: "check",
    msg: "异常情况：展示互动时，还启动了检测",
    last: this._isLastHidden,
    current: document.hidden
  });
  this.player().pause();  // 暂停播放
}
```

如果互动题展示时页面不可见（`document.hidden = true`），视为异常情况，暂停播放。

### 4.7 签名校验（详见基础文档）

- HMAC-SHA1 签名，密钥 `5373c0e70a15c97150bbef12522b6b90`
- 防止篡改上报数据（action/duration/timestamp 等）
- 签名错误返回 `699101`

### 4.8 服务器时间同步

```js
checkDiffTime(e, t) {
  if (e && +e) {
    const r = +e - getMillisecond();  // 服务器时间 - 本地时间
    if (Math.abs(this._diffTime - r) > 1e4) {  // 偏差超过10秒
      this._logger.info({type: "diff_10", last: this._diffTime, current: r, ...});
    }
    this._diffTime = r;
  }
}
```

- 每次上报响应的 `data.ts` 用于校准 `_diffTime`
- `report_time = getMillisecond() + _diffTime`，确保使用服务器同步时间
- 防止篡改本地时间作弊

### 4.9 多通道上报回退

```
_hostList = ["bfe", "clog", "dlog", "iplog"]
```

- 主通道 `bfe` 失败 → 回退 `clog` → `dlog` → `iplog`（fallbackIP）
- 每次回退设置 `EventPackage[0].fallback = 1`
- 所有通道都失败 → `ErrorEnum.POINT_FC`

### 4.10 域名连通性检测

```js
checkDomains() {
  const e = yield Promise.all(
    this._hostList.map(e => connection(`${hostMap[e]}/checkstatus`))
  );
  const t = this._hostList.filter((t, r) => !!e[r]);
  if (0 === t.length) this._logger.warn({type: ""}, "checkDomains");
  // 更新可用 host 列表
}
```

- 播放器初始化时检测各 host 的 `/checkstatus` 端点
- 过滤出可用的 host 列表

---

## 5. 完整检测体系架构

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    ewt360 视频播放认真度检测体系                            │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────── mstplayer SDK 主动检测 ──────────────┐                 │
│  │                                                     │                 │
│  │  ┌─────────┐  ┌─────────────────┐  ┌─────────────┐ │                 │
│  │  │ 确认型   │  │ 答题型(互动型)   │  │ 反调试型     │ │                 │
│  │  │(违规弹窗)│  │(时间点触发题目)  │  │(DevTools检测)│ │                 │
│  │  └────┬────┘  └───────┬─────────┘  └──────┬──────┘ │                 │
│  │       │               │                   │        │                 │
│  │  699001错误码    interactiveTime     devtools-detector                │
│  │       │          Point到达            6种检测器                        │
│  │       ▼               │                   │        │                 │
│  │  "视频已暂停"          ▼                   ▼        │                 │
│  │  "我知道了"      单选/多选/判断      清空console     │                 │
│  │       │               │             销毁播放器       │                 │
│  │       ▼               ▼             死循环debugger   │                 │
│  │   用户确认         submitAnswer                      │                 │
│  │                  → rightStatus                      │                 │
│  └─────────────────────────────────────────────────────┘                 │
│                                                                          │
│  ┌─────────────── 业务层主动检测（bend）──────────────┐                  │
│  │                                                     │                  │
│  │  ┌─────────────────────────────────────────────┐   │                  │
│  │  │ 滑块型 (ecaptcha SDK)                         │   │                  │
│  │  │ 看课异常 → 弹出 spc_video_earnest_check_box   │   │                  │
│  │  │ → captcha/get (获取滑块图)                    │   │                  │
│  │  │ → 用户拖动 → captcha/verify (验证)            │   │                  │
│  │  │ → 返回 captchaToken                          │   │                  │
│  │  │ → addVideocss (seriousCheckResult:2 + token)  │   │                  │
│  │  └─────────────────────────────────────────────┘   │                  │
│  │                                                     │                  │
│  │  ┌── 反自动化脚本检测 ──┐                          │                  │
│  │  │ • event.isTrusted=false 检测                    │                  │
│  │  │ • Fiber 遍历 toCheck 调用检测                   │                  │
│  │  │ • 模拟点击 lesson-item 检测                     │                  │
│  │  │ → updateIsBlacklisted (UNTRUSTED_EVENT)        │                  │
│  │  └────────────────────┘                           │                  │
│  └─────────────────────────────────────────────────────┘                  │
│                                                                          │
│  ┌─────────────── 被动防作弊 ──────────┐  ┌── 降级机制 ──┐              │
│  │ • 拖拽进度条禁用                       │  │ getSeriousCheck │              │
│  │ • 拖拽越界检测 (差值5秒)               │  │ DownGradeConfig │              │
│  │ • 页面失焦检测 (visibilitychange)      │  │ level=0 正常    │              │
│  │ • 签名校验 (HMAC-SHA1, mstid)         │  │ level>0 降级    │              │
│  │ • 服务器时间同步 (checkDiffTime)       │  └────────────────┘              │
│  │ • 多通道回退 (bfe→clog→dlog→iplog)    │                                  │
│  │ • 域名连通性检测 (/checkstatus)        │  ┌── 检测点位置 ──┐              │
│  │ • 进度条标记 (showMarkers)             │  │ 服务端下发:      │              │
│  │ • 弹窗可见性检测 (document.hidden)     │  │ interactiveTime │              │
│  └───────────────────────────────────────┘  │ Point           │              │
│                                              └────────────────┘              │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 错误处理对照表

| 场景 | 错误码 | ErrorEnum | 数值 | 用户可见效果 |
|---|---|---|---|---|
| 看课数据违规 | 699001 | POINT_ILLEGAL | 2002 | "视频已暂停"弹窗（确认型） |
| 签名错误 | 699101 | POINT_SIGNATURE_ERROR | 1010 | 错误提示"oops，遇到一点小状况" |
| 参数错误 | 699102 | POINT_PARAMS_ERROR | 1011 | 错误提示"oops，遇到一点小状况" |
| 上报通道全部失败 | — | POINT_FC | 2003 | 播放异常错误提示 |
| 互动题加载失败 | — | InteractiveErrorEnum.LOAD_DETAIL | 0 | "重试"按钮 |
| 互动题答题失败 | — | InteractiveErrorEnum.ANSWER | 1 | 答题错误提示 |
| 拖拽越界 | — | — | — | "视频升级，本课从头播放"提示 |
| 跨天观看 | — | — | — | 控制台日志"跨天了" |
| DevTools 打开（antiDebug=true 时） | — | — | — | 清空 console + 销毁播放器 + 死循环 debugger |
| 认真度检测降级（level>0） | — | — | — | 提示"当前为使用高峰期，课程视频监测功能暂不可用" |

---

## 7. 运行时实测数据

当前页面（`lessonId=117890`）的认真度检测配置：

```json
{
  "pointInfo": {
    "videoType": 1,
    "courseId": "48419",
    "illegalModal": true                  // 确认型检测已开启
  },
  "interactiveInfo": undefined,            // 当前视频无互动题配置
  "videoTagInfo": {
    "base": true,
    "fullscreen": true,
    "courseId": "48419"
  },
  "videoSegmentInfo": {
    "show": true
  },
  "internalPlugins": {
    "ai": { "options": { "defaultEnableUI": false } }
  }
}
```

- **确认型**：已开启（`illegalModal: true`），但需服务端返回 `699001` 才触发
- **答题型**：当前视频未配置互动题（`interactiveInfo` 为空）
- **反调试型**：`antiDebug` 默认 false，当前未启用
- **滑块型**：mstplayer SDK 内无；业务层（`homework-play-video.js` + `ecaptcha` SDK）已实现，调用 `addVideocss` 上报 `seriousCheckResult` + `captchaToken`，详见第 3' 节

### 7.1 服务端认真度检测相关接口实测响应

#### getLessonDetailV2（课程详情）

```json
{
  "id": "117890",
  "lessonName": "J《六国论》带背与带练1",
  "videoPlayTime": 763.00,
  "needCheckPoint": true,           // ← 课程需要检测点
  "interactiveVideo": false,        // ← 当前视频非互动视频（无互动题）
  "studyGuideShowVO": { "showDxa": true, "showPractise": true }
}
```

#### getVideodp（查询用户是否在黑名单）

```json
{ "success": true, "code": "200", "msg": "操作成功", "data": true }
```

> **重要**：`data:true` 表示**当前用户已在黑名单中**，会走滑块型检测（ek 组件）。
> 前端源码：`let {data:e} = await getVideodp(); setIsBlacklisted(!!e)`。
> 详见 3'.7.1 节。

#### getSeriousCheckDownGradeConfig（认真度检测降级配置）

```json
{
  "success": true, "code": "200", "msg": "操作成功",
  "data": {
    "key": "downgrade.student.video.serious.check",
    "level": 0,                    // ← 0=不降级，>0=降级
    "tips": "当前为使用高峰期，课程视频监测功能暂不可用",
    "description": "课程视频监测功能降级",
    "needLog": 1
  }
}
```

#### cab（用途未知，疑似检测点相关布尔开关）

```json
// GET /api/homeworkprod/homework/student/cab?schoolId=10000&lessonId=117890&homeworkId=10495544
{ "success": true, "code": "200", "msg": "操作成功", "data": false }
```

#### getPlayerGlobalConf（播放器全局配置，含检测相关字段）

```json
{
  "globalInfo": {
    "intervalTime": 60,             // 心跳周期（秒）
    "sessionId": "160000000_5e6862aa-c64b-4538-abf6-a53cfd532f9e",
    "secret": "80199003293cb09a7fa18335a6fc074f",
    "ts": "1785478092335",
    "clientIp": "117.189.108.122",
    "maxBatchSize": 10,
    "fallbackIP": "101.37.78.197:8081"
  },
  "videoPlayedProgress": {
    "reportFrequency": 300,         // 进度上报周期（秒）
    "differenceValue": 5            // 拖拽越界允许差值（秒）
  }
}
```

### 7.2 播放器实例运行时状态

```js
player.usingPlugin()
// → ["bizPoint", "progressPoint", "userInfo", "confirmModal"]
// 当前启用的插件：
//   - bizPoint       → 看课埋点上报（含 699001 确认型检测）
//   - progressPoint  → 播放进度上报（失焦检测、定时上报）
//   - userInfo       → 用户信息
//   - confirmModal   → 确认型弹窗组件
// 未启用：
//   - bizInteractive → 互动题（当前视频无配置）
//   - antiDebug      → 反调试（AliAdapter 配置，默认 false）
```
