# 收藏夹获取答案 · API 文档

> 适用对象：EWT360「错题/收藏夹」（wrongquestion label）里收藏的题目，批量拉取**题干 + 答案 + 解析**。
> 方案整理自 `ewt_auto_client/lib/features/answer/data/datasources/answer_remote_datasource.dart`
> 的「收藏夹 API (wrongquestion)」段落，以及 `core/network` 的拦截器与 `core/constants/crypto_constants.dart`。
>
> ⚠️ **请求侧（URL / 参数 / 请求头）为源码确认；响应体字段为按代码推断 + 需 HAR 实测核对，运行 `favorites_answer.py` 即可打印真实响应。**

---

## 0. 通用约定

### 0.1 域名
全部走网关：`https://gateway.ewt360.com`

### 0.2 请求头（默认拦截器注入，与答案 report 接口不同！）
收藏夹接口走 **默认 `AuthInterceptor` + `SignInterceptor`**，即：

| Header | 值 | 来源 |
|---|---|---|
| `token` | 登录 token（cookie 名 `token`，失败兜底 `"0"`） | AuthInterceptor |
| `User-Agent` | `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36 Edg/147.0.0.0` | EndpointConfig |
| `Origin` | `https://www.ewt360.com` | EndpointConfig |
| `Referer` | `https://www.ewt360.com/` | EndpointConfig |
| `timestamp` | 毫秒时间戳（字符串） | SignInterceptor |
| `sign` | `MD5(timestamp + secretKey).upper()` | SignInterceptor |
| `secretId` | `2` | CryptoConstants.webSecretId |
| `platform` | `1` | CryptoConstants.webPlatform |
| `sec-ch-ua` / `sec-ch-ua-mobile` / `sec-ch-ua-platform` / `Sec-Fetch-*` / `DNT` | 固定值，见下 | EndpointConfig.extraHeaders |

**关键差异**：答案 `answerprod` 接口（report/webreport/paper 等）要求 `Origin/Referer = https://web.ewt360.com`；**但收藏夹接口用默认 `www.ewt360.com`**（`answer_remote_datasource.dart` 中收藏夹方法未覆盖为 `_answerHeaders`）。若实测返回越权/空数据，可先尝试把 `Origin/Referer` 改成 `web.ewt360.com`。

### 0.3 签名算法（Python 实现）
```python
import hashlib, time
def make_sign(secret_key: str = "bdc739ff2dcf") -> tuple[str, str]:
    ts = str(int(time.time() * 1000))
    sign = hashlib.md5((ts + secret_key).encode()).hexdigest().upper()
    return ts, sign
# secretKey = CryptoConstants.webSignSecretKey = "bdc739ff2dcf"
```

### 0.4 统一响应结构
```json
{ "success": true, "code": "200", "msg": "", "data": <见各接口> }
```
所有方法以 `success == true` 判定成功；失败时 `data` 多为 `null`。

---

## 1. 获取收藏夹（错题本）列表

`GET /api/wrongquestion/label/list`

### 请求头
见 §0.2 默认头（含 `token`、`sign` 等）。

### 请求体（Query）
| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `subjectId` | int | 是 | 学科 ID（数学/语文/英语…）；传 `0` 表示全部 |
| `questionId` | int | 否 | 固定传 `0`（源码写死） |

示例：`?subjectId=1&questionId=0`

### 响应体（推断，待核对）
```json
{
  "success": true, "code": "200", "msg": "",
  "data": [
    { "id": 123456, "label": "我的收藏", "subjectId": 1,
      "questionCount": 12, "createTime": 1690000000000 }
  ]
}
```
> `id` / `label` 即后续 `labelId` / 收藏夹名。`questionCount` 用于分页总量。

---

## 2. 获取收藏夹内题目列表

`GET /api/answerprod/web/wrongquestion/label/getquestion`

> 源码做了 **多 URL 回退**（依次尝试，成功即返回）：
> 1. `/api/answerprod/web/wrongquestion/label/getquestion` ✅ 首选
> 2. `/api/answerprod/web/wrongquestion/collect/label/getquestion`
> 3. `/api/wrongquestion/label/getquestion`

### 请求头
见 §0.2 默认头。

### 请求体（Query）
| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `labelId` | int | 是 | 来自接口 1 的 `id` |
| `subjectId` | int | 是 | 学科 ID |
| `offset` | int | 否 | 偏移，默认 `0` |
| `limit` | int | 否 | 每页条数，默认 `50` |

示例：`?labelId=123456&subjectId=1&offset=0&limit=50`

### 响应体（推断，待核对）
```json
{
  "success": true, "code": "200", "msg": "",
  "data": {
    "total": 12,
    "list": [
      { "questionId": "1728260591849136339", "subjectId": 1,
        "labelId": 123456, "addTime": 1690000000000 }
    ]
  }
}
```
> 循环翻页：`offset += limit` 直到 `offset >= total`。

---

## 3. 获取收藏题目详情（含答案）

`GET /api/answerprod/web/wrongquestion/collect/question/info`

### 请求头
见 §0.2 默认头。

### 请求体（Query）
| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `questionId` | string | 是 | 来自接口 2 的 `questionId` |
| `subjectId` | int | 是 | 学科 ID |
| `labelId` | int/string | 否 | 收藏夹 ID；无则传 `-1` |

示例：`?questionId=1728260591849136339&subjectId=1&labelId=123456`

### 响应体（推断，待核对）
```json
{
  "success": true, "code": "200", "msg": "",
  "data": {
    "questionId": "1728260591849136339",
    "questionContent": { "stem": "...", "options": [...] },
    "answerContent": { "correctAnswer": "B", "analysis": "..." },
    "myAnswer": null
  }
}
```
> 这是「获取答案」的核心接口；`answerContent.correctAnswer` / `analysis` 即所需答案与解析。

---

## 4. 获取收藏题目解析（单独拉取）

`GET /api/answerprod/web/wrongquestion/collect/question/analysis`

### 请求头
见 §0.2 默认头。

### 请求体（Query）
与接口 3 完全一致：`questionId` / `subjectId` / `labelId`（`-1` 表示无）。

### 响应体（推断，待核对）
```json
{
  "success": true, "code": "200", "msg": "",
  "data": {
    "questionId": "1728260591849136339",
    "analysisContent": { "text": "详细解析...", "videoUrl": "..." }
  }
}
```
> 若接口 3 已返回完整解析，可不调用本接口。

---

## 5. 端到端调用时序（获取一整个收藏夹的答案）

```
1. GET  /api/wrongquestion/label/list            → 拿到 labelId 列表
2. GET  /api/answerprod/web/wrongquestion/label/getquestion?labelId&subjectId&offset&limit
                                                  → 拿到 questionId 列表（翻页）
3. for each questionId:
     GET /api/answerprod/web/wrongquestion/collect/question/info?questionId&subjectId&labelId
                                                  → 题干 + 答案 + 解析
     （可选）GET /api/answerprod/web/wrongquestion/collect/question/analysis?...
```

对应可运行代码见 `favorites_answer.py`（`run_favorites_demo`）。
