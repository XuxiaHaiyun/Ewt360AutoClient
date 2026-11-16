# 答题报告/分析页面 (answer-pc) API 调用文档

> 分析对象：
> - `https://web.ewt360.com/answer-pc/exam/analysis` (5 个标签页中 3 个)
> - `https://web.ewt360.com/answer-pc/report` (5 个标签页中 2 个)
>
> 分析方式：Edge DevTools MCP 注入 fetch/XHR 拦截器 + 网络抓包 + 真实响应回放
>
> 测试账号 (cookie 中)：
> - `token` = `160000000-1-xxxxxxxxxxxxxxxx`
> - `userId` = `160000000`
> - User-Agent: `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0`

---

## 0. 两类页面差异总览

| 维度 | `/answer-pc/exam/analysis` | `/answer-pc/report` |
|---|---|---|
| 业务码 `bizCode` | `204` (一般试卷/课后练习) | `205` (作业报告) |
| 是否带 `homeworkId` | 否 (URL 中无此参数) | 是 (URL 与每个 API 都带) |
| 容器根 class | `examination-paper-analysis` / `exam-header-in-analysis` | `report-page` / `routes_report_components_TopInfo_index_module_TopInfo_*` |
| 页面标题示例 | `J《六国论》带背与带练1 - 课后习题 用时：54秒` | `「语文」J名篇名句默写带背与带练（必修下）专题测试卷` |
| 报告主接口 | `GET /api/answerprod/web/answer/webreport` (返回扁平 `questions[]`) | `GET /api/answerprod/web/answer/webreport/questionGroup` (返回按题组 `groups[]`) |
| 答题卡接口 | `POST .../answer/report/answerSheetInfo` (扁平 `questionInfoList[]`) | `POST .../answer/report/groupAnswerSheetInfo` (按分组 `groupQuestionList[]`) |
| 历史报告 | 调用 `listPaperAnswerReport` + `getRecentAnswerReport` | 不调用 |
| 试卷可见性 | 不调用 `studyprod/web/paper/visibility` | 调用 (作业可能被教师关闭) |
| 顶部信息 | 用 `paperName` + `answerTime` | 用 `subjectName` + `title` + `useTimeStr` + `myTotalScore`/`totalScore` |
| `report_get` 中 `rightRate` | `1` (0-1 小数) | `0.5` (0-1 小数) |
| `report_get` 中 `assignPoints` | `false` | `true` (作业有赋分) |

**核心区别一句话**：
- `exam/analysis` = 单次答卷分析页（学生做完一份试卷/课后习题后看自己答题情况），按题目顺序扁平展示；
- `report` = 作业报告页（学生作业被批改后的报告），按题组分组展示，并多出可见性校验、关联作业 ID、赋分等字段。

---

## 1. 通用调用约定

### 1.1 网关

| 域名 | 用途 |
|---|---|
| `https://gateway.ewt360.com` | 主网关 (answerprod / usercenter / community / studyprod) |
| `https://web.ewt360.com` | 页面 origin / Referer |
| `https://cdn.ewt360.com` | 静态资源 + 用户上传图片 CDN |

### 1.2 通用请求头

实测从浏览器发起 XHR 时，请求头包含：

```
# 浏览器自动注入 (cookie)
Cookie: token=160000000-1-xxxxxxxxxxxxxxxx; _abfpc=...; cna=...; _bl_uid=...; QT_USER_UV_UUID=...

# 业务请求头 (页面 JS 设置)
Content-Type: application/json
token: 160000000-1-xxxxxxxxxxxxxxxx
platform: 1
bizCode: 204 | 205
userId: 160000000

# 浏览器自动注入 (CORS)
Origin: https://web.ewt360.com
Referer: https://web.ewt360.com/answer-pc/...?...
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0
Accept: */*
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
sec-ch-ua: "Not(A:Brand";v="8", "Chromium";v="151", "Microsoft Edge";v="151"
sec-ch-ua-mobile: ?0
sec-ch-ua-platform: "Windows"
Sec-Fetch-Site: same-site
Sec-Fetch-Mode: cors
Sec-Fetch-Dest: empty
```

注意：
- 主网关 `gateway.ewt360.com` 与页面 `web.ewt360.com` 跨子域，所以每次请求都会先发 `OPTIONS` 预检；
- `token` 同时在 cookie 和 header 中（header 优先），cookie 名为 `token`；
- 答题页业务不需要 EWT 网关签名 (`timestamp`/`sign`/`secretId`)，比 videoplayerprod/homeworkprod 简单。

### 1.3 统一响应格式

```json
{
  "success": true,
  "code": "200",
  "msg": "操作成功",
  "data": ...
}
```

- `data` 类型随接口变化（bool / object / array / number / null）；
- `success == false` 时按 `code` 走错误分支（如 `9984001` "本学科已关闭试题AI答疑"）。

---

## 2. 通用接口（两类页面都调用）

### 2.1 GET `/api/usercenter/user/baseinfo`

**用途**：获取登录用户基本信息（userId、姓名、头像等），是所有页面的首屏请求。

**请求**：
- Method: `GET`
- URL: `https://gateway.ewt360.com/api/usercenter/user/baseinfo?<毫秒时间戳>`
  - 时间戳用作缓存破坏（防代理缓存）
- Headers: 通用头

**响应 `data`**（关键字段）：
```json
{
  "userId": 160000000,
  "userName": "...",
  "realName": "...",
  "headImageUrl": "https://...",
  ...
}
```

### 2.2 POST `/api/community/webconfig/get`

**用途**：获取社区/Web 端配置（如客服二维码、是否展示反馈入口等）。

**请求**：通用头 + 空 body 或 `{}`。

**响应 `data`**：配置对象（与本任务无关，略）。

---

## 3. 报告主接口（两类页面共用，参数差异）

### 3.1 GET `/api/answerprod/web/answer/report` — 报告概要

**用途**：根据 `paperId` + `reportId` 取报告概要，是页面的核心首屏数据。

**请求 URL 差异**：

| 页面 | URL Query 参数 |
|---|---|
| `exam/analysis` (bizCode=204) | `paperId`, `platform=1`, `userId`, `expectReportStatus=2`, `bizCode=204`, `reportId` |
| `report` (bizCode=205) | 上述所有 + `extId=<homeworkId>`, `homeworkId=<homeworkId>` |

> `expectReportStatus=2` 表示期望报告状态为「已完成批改」；report 类页面额外传 `extId`（=homeworkId）做作业关联。

**响应 `data`**（实测）：
```json
{
  "paperId": "2272236290307785228",
  "userId": "160000000",
  "reportId": "2318559556986872029",
  "extId": 0,
  "platform": 1,
  "questionCount": 1,
  "rightRate": 0.5,            // 0~1 小数
  "finishAnswerTime": "2026-08-04 20:55:47",
  "finish": true,
  "answerTime": "355",         // 用时（秒）
  "assignPoints": true,        // report 页 true / analysis 页 false
  "h5SkipCover": true,
  "bizCode": 205,
  "subjectId": 1,
  "reportFlag": true,
  "scheduledPushlish": false,
  "scheduledPushlishTime": null,
  "updateTime": "1785848147000",
  "teacherRework": 0,
  "submitPaperTime": "1785848106000",
  "recomHomeworkList": null
}
```

**关键字段含义**：
- `finish`：是否已完成答题
- `assignPoints`：是否赋分（作业 = true，普通练习 = false）
- `reportFlag`：报告是否可读
- `submitPaperTime`：交卷毫秒时间戳
- `teacherRework`：是否被老师打回重做（0=否）

### 3.2 POST `/api/answerprod/web/answer/reCorrect/isReportCanBeReCorrect` — 是否可重新批改

**用途**：判断当前 `reportId` 是否允许触发重新批改（用于"申请重新批改"按钮的展示条件）。

**请求体**：
```json
// exam/analysis (bizCode=204)
{ "paperId": "...", "reportId": "...", "bizCode": "204", "platform": "1" }

// report (bizCode=205)
{ "paperId": "...", "reportId": "...", "bizCode": "205", "platform": "1", "homeworkId": "..." }
```

**响应 `data`**：`number`，实测为 `0`（不可重判）或 `1`（可重判）。

### 3.3 GET `/api/answerprod/web/paper/dowload/switch` — 下载开关

**用途**：判断该试卷是否允许下载 PDF/导出。

**请求**：
- URL: `?paperId=<paperId>&bizCode=<bizCode>`
- Method: `GET`

**响应 `data`**：`bool`，实测 `true`。

### 3.4 GET `/api/answerprod/web/answer/correct/result` — 批改结果概要

**用途**：查询批改是否完成、是否有教师评语。

**请求**：
- URL: `?paperId=<paperId>&platform=1&reportId=<reportId>&bizCode=<bizCode>`
- Method: `GET`

**响应 `data`**：
```json
{
  "correctResult": true,     // 是否批改完成
  "hasCorrect": true,        // 是否有批改数据
  "comment": null            // 教师评语（无则 null）
}
```

### 3.5 GET `/api/answerprod/common/paper/getPaperQuestionByPaperId` — 试卷题目索引

**用途**：按 `paperId` 拉试卷题目索引列表（不含题干详情，只有题目 ID 与展示号）。

**请求**：
- URL: `?paperId=<paperId>`
- Method: `GET`

**响应 `data`**：
```json
{
  "paperId": "2242575400780071280",
  "paperName": "J《六国论》带背与带练1 - 课后习题",
  "lessonBindListKnowledge": "",
  "questionList": [
    {
      "questionId": "1272506624367480491",
      "lessonId": null,
      "courseBindListKnowledge": "",
      "courseBindCustomize": "",
      "lessonIdFinal": null,
      "questionNoShow": "第1题",
      "subQuestionList": []
    },
    ...
  ]
}
```

### 3.6 GET `/api/answerprod/common/paper/isAllSubjectQuestion` — 是否全学科题目

**用途**：判断该试卷是否为多学科综合卷（影响 UI 是否显示学科切换器）。

**请求**：
- URL: `?bizCode=<bizCode>&paperId=<paperId>`
- Method: `GET`

**响应 `data`**：`number`，实测为 `1`（单学科）。

### 3.7 POST `/api/answerprod/web/answer/ai/qa/getAnswerAIQAPermission` — AI 答疑权限

**用途**：判断当前学科是否允许调用 AI 试题答疑。

**请求体**：
```json
// exam/analysis (bizCode=204)
{ "paperId": "...", "reportId": "...", "bizCode": "204", "platform": "1", "userId": "..." }

// report (bizCode=205)
{ "paperId": "...", "reportId": "...", "bizCode": "205", "platform": "1", "userId": "...", "homeworkId": "..." }
```

**响应**（实测学科关闭时）：
```json
{ "success": false, "code": "9984001", "msg": "本学科已关闭试题AI答疑", "data": null }
```

---

## 4. `exam/analysis` 页面 (bizCode=204) 专有接口

### 4.1 POST `/api/answerprod/web/answer/listPaperAnswerReport` — 列出该试卷的所有答题报告

**用途**：分页查询当前用户对该 `paperId` 的所有历史 `reportId`，用于"切换历史报告"下拉。

**请求体**：
```json
{
  "paperId": "2242575400780071280",
  "reportId": "2325776270277115987",
  "bizCode": "204",
  "platform": "1",
  "userId": "160000000"
}
```

**响应 `data`**：
```json
{
  "totalPages": 1,
  "pageIndex": 1,
  "pageSize": 10,
  "totalRecords": 1,
  "data": [
    {
      "paperId": "...",
      "userId": "...",
      "reportId": "...",
      "bizCode": 204,
      "platform": 1,
      "rightRate": 1,
      "isFinished": 1,
      "isCorrected": 1,
      "createTime": "1785491993000",
      "submitPaperTime": "1785492124000"
    }
  ],
  "havePrePage": false,
  "haveNextPage": false
}
```

### 4.2 POST `/api/answerprod/web/answer/getRecentAnswerReport` — 最近一次答题报告

**用途**：取该 `paperId` 最近一次答题报告（用于"再练一次"入口的 reportId 透传）。

**请求体**：
```json
{
  "paperId": "2242575400780071280",
  "bizCode": "204",
  "platform": "1",
  "userId": "160000000"
}
```

**响应 `data`**：单条报告对象（结构同 `listPaperAnswerReport.data[0]`）。

### 4.3 POST `/api/answerprod/common/answer/report/answerSheetInfo` — 答题卡（扁平）

**用途**：取答题卡详情，按题目顺序扁平返回（不分题组）。

**请求体**：
```json
{
  "paperId": "...",
  "reportId": "...",
  "platform": "1",
  "bizCode": "204",
  "userId": "160000000",
  "client": 1
}
```

**响应 `data`**：
```json
{
  "questionInfoList": [
    {
      "questionNumber": "1",
      "questionId": "1272506624367480491",
      "parentQuestionId": "0",
      "subjective": true,
      "answerFlag": true,
      "rightStatus": 1,                 // 1=对 2=错 3=半对
      "recordCorrectUserType": 1,
      "aiCorrectBizId": null,
      "score": null,
      "answerFrom": 1,
      "attachmentImages": [
        "https://cdn.ewt360.com/resources/answer-pc/uploads/2026/7/31/5535f2fe-d7c6-43b6-a450-413bef88e149.png"
      ]
    }
  ],
  "assignPoints": false,
  "subjectId": null,
  "imagesRiskList": null
}
```

### 4.4 GET `/api/answerprod/web/answer/webreport` — Web 报告（扁平 questions）

**用途**：取 Web 端报告完整内容（题干 / 选项 / 我的答案 / 正确答案 / 解析 / 知识点），扁平 `questions[]`。

**请求**：
- URL: `?platform=1&reportId=<reportId>&userId=<userId>&bizCode=204`
- Method: `GET`

**响应 `data`**（精简）：
```json
{
  "paperId": "...",
  "reportId": "...",
  "title": "J《六国论》带背与带练1 - 课后习题",
  "userTimeStr": "54秒",
  "rightRate": 100,
  "allRight": true,
  "questions": [
    {
      "id": "1272506624367480491",
      "scoreCriterion": "",
      "cate": 5,
      "cateName": "解答",
      "subjectQuestionType": 1010501,
      "subjectQuestionTypeName": "简答题",
      "questionContent": "<div ...>背诵默写《六国论》第一段和第二段。</div>",
      "options": [],
      "myAnswer": ["https://.../5535f2fe-...png"],
      "myAnswers": null,
      "attachmentImages": ["https://.../5535f2fe-...png"],
      "rightStatus": 1,
      "rightAnswer": ["<div ...>略</div>"],
      "isRecordCorrected": 1,
      "recordCorrectUserType": 1,
      "degreeRange": 5,
      "degreeRangeDesc": "中",
      "questionType": 0,
      "questionSource": 1,
      "source": 1,
      "audioUrl": "",
      "questionSort": 1,
      "analyse": "<div ...>能够准确默写文章即可...</div>",
      "method": null,
      "childQuestions": [],
      "knowledges": [{"id":"1010175","title":"固定篇目情境默写"}],
      "revision": true,
      "score": 0,
      "myScore": 0,
      "scoreList": [],
      "lessons": [],
      "collected": false,
      "subjectId": 1,
      "questionNo": 1,
      "questionNoShow": "1",
      "subjective": true,
      "groupSort": 1,
      "groupName": "名篇名句默写（一）",
      "groupInfo": "本题共1小题",
      "groupDeclare": "",
      "aiCorrectBizId": null,
      "imagesRiskList": null
    }
  ],
  "lessons": [],
  "rightKnowledges": [{"id":"1010175","title":"固定篇目情境默写","rate":100}],
  "subjectId": 1,
  "platform": 1,
  "bizCode": 204,
  "createPaperPara": null,
  "imagesRiskList": null
}
```

---

## 5. `report` 页面 (bizCode=205) 专有接口

### 5.1 GET `/api/studyprod/web/paper/visibility` — 试卷可见性

**用途**：作业可能被教师关闭查看权限，本接口返回 `false` 时页面会显示"作业不可见"提示。

**请求**：
- URL: `?paperId=<paperId>&reportId=<reportId>&bizCode=205&homeworkId=<homeworkId>`
- Method: `GET`

**响应 `data`**：`bool`，实测 `false`（教师关闭时）或 `true`。

### 5.2 GET `/api/answerprod/web/answer/webreport/questionGroup` — Web 报告（按题组分组）

**用途**：取 Web 端报告完整内容，**按题组 (`groups[]`) 分组返回**，每题带 `score`/`myScore`/`scoreList`。

**请求**：
- URL: `?paperId=<paperId>&reportId=<reportId>&platform=1&bizCode=205&homeworkId=<homeworkId>&userId=<userId>`
- Method: `GET`

**响应 `data`**（精简，重点字段）：
```json
{
  "subjectId": 1,
  "subjectName": "语文",
  "paperId": "...",
  "reportId": "...",
  "title": "J名篇名句默写带背与带练（必修下）专题测试卷",
  "useTimeStr": "5分55秒",
  "totalTimeStr": "60分钟",
  "myTotalScore": 80,
  "totalScore": 100,
  "lessons": [
    {
      "courseId": "53465",
      "lessonId": "123570",
      "playTime": "17分34秒",
      "img": "https://static.ewt360.com/...",
      "videoTitle": "名篇名句默写带背与带练（必修下）专题测试卷#1",
      "url": "/site-study/#/playVideo?courseId=53465&lessonId=123570&from=report_recommend",
      "questionId": "1281415130642573902"
    }
  ],
  "rightKnowledges": [{"id":"1010175","title":"固定篇目情境默写","rate":80}],
  "rightRate": 50,
  "allRight": false,
  "assignPointsFlag": true,
  "groups": [
    {
      "index": 1,
      "groupId": 61738540,
      "groupName": "名句名篇默写",
      "groupInfo": "本题共1小题，共100分",
      "groupDeclare": "",
      "totalQuestions": 1,
      "totalScore": 100,
      "myTotalScore": 80,
      "questions": [
        {
          "id": "1281415130642573902",
          "cate": 30,
          "cateName": "填空",
          "subjectQuestionType": 1013003,
          "subjectQuestionTypeName": "名句名篇默写",
          "questionContent": "<div ...>（1）...（2）...</div>",
          "options": [],
          "myAnswer": ["https://.../1785848091224-answer_1281415130642573902.png"],
          "myAnswers": null,
          "attachmentImages": ["https://.../1785848091224-answer_1281415130642573902.png"],
          "rightStatus": 2,
          "rightAnswer": ["以吾一日长乎尔", "毋吾以也", ...50项...],
          "isRecordCorrected": 1,
          "recordCorrectUserType": 1,
          "degreeRange": 5,
          "degreeRangeDesc": "中",
          "questionSort": 1,
          "analyse": "<div ...>略</div>",
          "method": null,
          "childQuestions": [],
          "knowledges": [{"id":"1010175","title":"固定篇目情境默写"}],
          "revision": true,
          "score": 100,
          "myScore": 80,
          "scoreList": [0,1,2,...,100],   // 赋分模式下每个空位的得分列表
          "lessons": [...],
          "collected": false,
          "subjectId": 1,
          "questionNo": 1,
          "questionNoShow": "1",
          "subjective": true,
          "groupSort": 1,
          "groupName": "名句名篇默写",
          "groupInfo": "本题共1小题，共100分",
          "aiCorrectBizId": null,
          "imagesRiskList": null
        }
      ],
      "rightQuestionsCount": 0,
      "rightRate": 0
    }
  ],
  "teacherReviewScore": null,
  "teacherReviewRank": null,
  "teacherReviewRankList": ["A+","A","B","C","D"],
  "teacherReviewComment": null,
  "teacherReviewImageList": [],
  "imagesRiskList": null
}
```

> 与 `webreport` 相比，`questionGroup` 多出：
> - 顶层 `subjectName` / `totalTimeStr` / `myTotalScore` / `totalScore` / `teacherReview*` 字段
> - `groups[]` 嵌套结构（每题组带 `totalScore`/`myTotalScore`/`rightQuestionsCount`）
> - 题目里的 `score`/`myScore`/`scoreList` 在赋分模式下有实际数值
> - `lessons[]` 嵌在题目内（推荐微课），且 `assignPointsFlag=true`

### 5.3 POST `/api/answerprod/common/answer/report/groupAnswerSheetInfo` — 答题卡（按分组）

**用途**：取答题卡详情，**按题组 (`groupQuestionList[]`) 分组返回**，每题带 `score`。

**请求体**：
```json
{
  "paperId": "...",
  "reportId": "...",
  "platform": "1",
  "bizCode": "205",
  "homeworkId": "10495544",
  "userId": "160000000",
  "client": 1
}
```

**响应 `data`**：
```json
{
  "paperId": "...",
  "paperName": "J名篇名句默写带背与带练（必修下）专题测试卷",
  "assignPoints": true,
  "groupQuestionList": [
    {
      "groupId": "61738540",
      "groupName": "名句名篇默写",
      "groupSort": 1,
      "rightRate": 50,
      "totalQuestions": 1,
      "totalScore": 100,
      "myTotalScore": 80,
      "questionInfoList": [
        {
          "questionNumber": "1",
          "questionId": "1281415130642573902",
          "parentQuestionId": "0",
          "subjective": true,
          "answerFlag": true,
          "rightStatus": 2,
          "recordCorrectUserType": 1,
          "aiCorrectBizId": null,
          "score": 100,
          "answerFrom": null,
          "attachmentImages": null
        }
      ]
    }
  ]
}
```

---

## 6. 调用时序（实测）

### 6.1 `exam/analysis` (bizCode=204) 时序

```
1. GET  /api/usercenter/user/baseinfo?<ts>
2. POST /api/community/webconfig/get
3. GET  /api/answerprod/web/answer/report?...&bizCode=204&reportId=<rid>
4. POST /api/answerprod/web/answer/reCorrect/isReportCanBeReCorrect
5. POST /api/answerprod/web/answer/listPaperAnswerReport
6. GET  /api/answerprod/web/paper/dowload/switch?paperId=<pid>&bizCode=204
7. GET  /api/answerprod/common/paper/getPaperQuestionByPaperId?paperId=<pid>
8. GET  /api/answerprod/web/answer/correct/result?...&bizCode=204
9. GET  /api/answerprod/common/paper/isAllSubjectQuestion?bizCode=204&paperId=<pid>
10. POST /api/answerprod/web/answer/getRecentAnswerReport
11. POST /api/answerprod/common/answer/report/answerSheetInfo
12. GET  /api/answerprod/web/answer/webreport?platform=1&reportId=<rid>&userId=<uid>&bizCode=204
13. POST /api/answerprod/web/answer/ai/qa/getAnswerAIQAPermission
```

### 6.2 `report` (bizCode=205) 时序

```
1. GET  /api/usercenter/user/baseinfo?<ts>
2. POST /api/community/webconfig/get
3. GET  /api/usercenter/user/baseinfo              (无时间戳，二次拉取)
4. GET  /api/studyprod/auth/function/check?functionCode=SVIP_COURSE_WEB&noAutoJump=true
5. GET  /api/studyprod/auth/live/backplay/authenticate
6. GET  /api/studyprod/web/paper/visibility?...
7. GET  /api/answerprod/web/answer/report?...&bizCode=205&reportId=<rid>&extId=<hid>&homeworkId=<hid>
8. GET  /api/answerprod/web/paper/dowload/switch?paperId=<pid>&bizCode=205
9. GET  /api/answerprod/web/answer/correct/result?...&bizCode=205
10. GET /api/answerprod/common/paper/getPaperQuestionByPaperId?paperId=<pid>
11. GET /api/answerprod/common/paper/isAllSubjectQuestion?bizCode=205&paperId=<pid>
12. GET /api/answerprod/web/answer/webreport/questionGroup?...&bizCode=205&homeworkId=<hid>&userId=<uid>
13. POST /api/answerprod/common/answer/report/groupAnswerSheetInfo
14. POST /api/answerprod/web/answer/reCorrect/isReportCanBeReCorrect
15. POST /api/answerprod/web/answer/ai/qa/getAnswerAIQAPermission
```

---

## 7. 错误码

| code | 含义 | 实测场景 |
|---|---|---|
| `200` | 操作成功 | 正常响应 |
| `9984001` | 本学科已关闭试题AI答疑 | `getAnswerAIQAPermission` 在语文学科返回 |

---

## 8. URL/响应字段映射速查表

| 字段 | `exam/analysis` | `report` | 备注 |
|---|---|---|---|
| URL `bizCode` | `204` | `205` | 业务码 |
| URL `homeworkId` | 无 | 必有 | 作业 ID |
| URL `assignPoints` | `false` | 不传 | 仅 analysis 显式传 |
| `report` 接口 `extId` | 不传 | = `homeworkId` | 作业关联外键 |
| `report` 接口 `homeworkId` | 不传 | 必传 | |
| 报告主接口 path | `webreport` | `webreport/questionGroup` | 扁平 vs 分组 |
| 答题卡接口 path | `answerSheetInfo` | `groupAnswerSheetInfo` | 扁平 vs 分组 |
| `assignPoints` 字段 | `false` | `true` | 是否赋分 |
| `rightRate` 字段 | 0~1 小数 | 0~1 小数 | 一致 |
| `score`/`myScore`/`scoreList` | 通常 0/空 | 实际分数 | report 页有赋分 |
| `subjectName` 顶层 | 无 | 有 | report 页显示学科 |
| `teacherReview*` 字段 | 无 | 有 | 教师点评 |
| `lessons[]` 顶层 | 有（推荐微课） | 嵌在题目内 | 位置不同 |
| `listPaperAnswerReport` | 调用 | 不调用 | 历史报告 |
| `getRecentAnswerReport` | 调用 | 不调用 | 最近报告 |
| `studyprod/web/paper/visibility` | 不调用 | 调用 | 作业可见性 |
