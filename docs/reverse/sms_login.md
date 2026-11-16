# EWT360 短信验证码登录 · 接口文档与 Python 参考实现

> 来源：Flutter 客户端 `ewt_auto_client/lib/features/auth/**` 与 `lib/core/**` 的直译抽取。
> 参考实现 `debug/reverse/sms_login.py` 与 Dart 侧字段、签名、请求头逐项对齐，未做推测性改写。

---

## 1. 流程总览

短信登录是一个**三步串行**流程，前后步之间有强依赖（`safeToken` → `checkToken` → `token`）：

```
┌──────────────────────────────────────────────────────────────┐
│ Step 1  POST /api/safecenter/business/control/type           │
│         入: bizCode / type=2 / mobile / timestamp / checkSign │
│         出: data.token (=safeToken) · data.mode               │
│         mode=1 → 需要滑块验证；mode=2 → 操作受限              │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ Step 2  POST /api/usercenter/user/login/sms/byLogin/safecenter│
│         入: platform=1 / mobile / safeToken [+captchaToken]   │
│         出: data.checkToken · data.existUser                  │
│         副作用: 向手机下发短信验证码                          │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ Step 3  POST /api/usercenter/user/login/mobile/login          │
│         入: platform=1 / mobile / smsCode / autoLogin /       │
│             checkToken                                        │
│         出: data.token · data.userId (会话令牌)               │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
             (可选) getUser / getSchoolUserInfo / baseinfo 补全资料
```

**关键约束**

- `safeToken` 与 `checkToken` 都是**一次性**的，且与手机号绑定；重发短信必须重走 Step 1。
- Step 2 / Step 3 必须带两个"看起来多余但不能少"的头：`token: 0`、`referurl: https://www.ewt360.com/`。
- 整个流程**不涉及 AES 密码加密**（那是账号密码登录/改密链路才用的）。

---

## 2. 通用约定

### 2.1 域名

| 用途 | 值 |
| --- | --- |
| 网关 | `https://gateway.ewt360.com` |

### 2.2 公共请求头

每次请求都由拦截器注入（对应 `SignInterceptor` + `AuthInterceptor`）：

| Header | 取值 / 算法 |
| --- | --- |
| `Content-Type` | `application/json` |
| `Accept` | `application/json, text/plain, */*` |
| `Accept-Language` | `zh-CN,zh;q=0.9,en-US;q=0.8` |
| `timestamp` | 当前毫秒时间戳（`int(time.time()*1000)`） |
| `sign` | `MD5(timestamp + "bdc739ff2dcf")` **大写** hex |
| `secretId` | `2` |
| `platform` | `1` |
| `token` | 已登录则填会话 token，否则填字符串 `0` |
| `Origin` | `https://www.ewt360.com` |
| `Referer` | `https://www.ewt360.com/` |
| `User-Agent` | Chrome/147 Edge/147 桌面 UA（见 `DEFAULT_UA`） |
| `sec-ch-ua` 等 | 见 `EXTRA_HEADERS`（`Sec-Fetch-*`、`DNT`、`sec-ch-ua-*`） |

### 2.3 响应包装与成功判定

```json
{ "success": true, "code": "200", "msg": "操作成功", "data": { } }
```

成功判定（Dart `ApiResponse.isSuccess`）：

```python
success is True  or  code in ("00000", "200")
```

### 2.4 固定常量

| 常量 | 值 | 出处 |
| --- | --- | --- |
| 签名密钥 | `bdc739ff2dcf` | `CryptoConstants.webSignSecretKey` |
| secretId | `2` | `webSecretId` |
| platform | `1` | `webPlatform` |
| safecenter 签名密钥 | `eo^nye1j#!wt2%v)` | `CryptoConstants.dlogSignKey` |
| 短信登录 bizCode | `mst1634782715743` | `CryptoConstants.smsCaptchaBizCode` |
| 注册 bizCode（参考） | `mst1634784055587` | `registerSmsCaptchaBizCode` |

---

## 3. 接口明细

### Step 1 — 获取安全令牌

```
POST /api/safecenter/business/control/type
```

**Body**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `bizCode` | string | 短信登录固定 `mst1634782715743` |
| `type` | string | 固定 `"2"` |
| `mobile` | string | 手机号 |
| `timestamp` | int | 毫秒时间戳，需与 `checkSign` 内的一致 |
| `checkSign` | string | 见下方算法 |

**checkSign 算法**（`AuthRemoteDataSource._generateCheckSign`）

```
checkSign = MD5( secret + bizCode + mobile + timestamp + secret )   # 32 位小写 hex
secret    = "eo^nye1j#!wt2%v)"
```

**响应 `data`**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `token` | string | 即 `safeToken`，Step 2 使用 |
| `mode` | int | `0` 无需验证 / `1` 需要滑块 / `2` 操作受限 |
| `msg` | string | mode≠0 时的提示文案 |

**mode 处理**（`AuthRepositoryImpl.sendSmsCode`）

- `mode == 1` → 需要滑块验证：用 `bizCode=mst1634782715743` 走滑块拿 `captchaToken`，再带它重发
- `mode == 2` → 直接失败，提示 `msg`（通常是频控）

---

### Step 2 — 发送短信验证码并取 checkToken

```
POST /api/usercenter/user/login/sms/byLogin/safecenter
```

**额外请求头（必带）**

```
token: 0
referurl: https://www.ewt360.com/
```

**Body**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `platform` | int | ✅ | 固定 `1` |
| `mobile` | string | ✅ | 手机号 |
| `safeToken` | string | ✅ | Step 1 返回的 `data.token` |
| `captchaToken` | string | ❌ | mode==1 滑块通过后附加 |

**响应 `data`**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `checkToken` | string | Step 3 使用 |
| `existUser` | bool | 该手机号是否已注册（`true` 表示老用户，可正常登录） |

---

### Step 3 — 短信验证码登录

```
POST /api/usercenter/user/login/mobile/login
```

**额外请求头（必带，与 Step 2 相同）**

```
token: 0
referurl: https://www.ewt360.com/
```

**Body**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `platform` | int | ✅ | 固定 `1` |
| `mobile` | string | ✅ | 手机号 |
| `smsCode` | string | ✅ | 收到的短信验证码 |
| `autoLogin` | bool | ✅ | 固定 `true` |
| `checkToken` | string | ✅ | Step 2 返回的 `checkToken` |

**响应 `data`**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `token` | string | 会话令牌，后续请求的 `token` 头 |
| `userId` | string/number | 用户 ID |
| `nickName` / `avatar` / `mobile` / `account` | string | 可能缺失 |

---

### 可选 — 补全会话资料

登录成功后，Dart 侧 `_buildSession` 会再拉三个接口补全字段（任一失败静默跳过）：

| 接口 | 用途 | 取用字段 |
| --- | --- | --- |
| `GET /api/eteacherproduct/school/getSchoolUserInfo` | 权威 userId / schoolId | `userId`、`schoolId` |
| `GET /api/usercenter/user/baseinfo` | 真名 / 头像 / 学校名 / 省份码 | `realName`、`photoUrl`\|`avatar`、`schoolName`、`account`\|`userName`、`mobile`、`memberProvinceCode` |
| `GET /api/usercenter/user/login/getUser` | Token 校验（本流程未用） | `userName`、`nickName`、`avatar`、`mobile` |

---

## 4. Python 使用

### 4.1 作为库调用

```python
from sms_login import SmsLoginClient, CaptchaRequiredError

client = SmsLoginClient(proxy="http://127.0.0.1:8888")   # 不需要代理则省略

try:
    sent = client.request_code("13800138000")
except CaptchaRequiredError as e:
    # 走滑块（bizCode=mst1634782715743）拿到 token 后重试
    sent = client.request_code("13800138000", captcha_token="<滑块 token>")

print(sent.check_token, sent.exist_user)

session = client.login("13800138000", sms_code="123456", check_token=sent.check_token)
print(session.token, session.user_id, session.school_id)
client.token  # 已写回，可继续调用其他业务接口
```

分步调用（调试单个环节时用）：

```python
safe = client.get_safe_token("13800138000")      # Step 1
sent = client.send_sms("13800138000", safe.safe_token)   # Step 2
session = client.login("13800138000", "123456", sent.check_token)  # Step 3
```

### 4.2 命令行

```bash
cd debug/reverse

# 只发短信，打印 checkToken
python sms_login.py send 13800138000

# 需要滑块时
python sms_login.py send 13800138000 --captcha-token <token>

# 交互登录：发短信 → 终端输入验证码 → 登录并补全资料
python sms_login.py login 13800138000

# 已有 checkToken 直接登录
python sms_login.py login 13800138000 --code 123456 --check-token <token>

# 抓包调试
python sms_login.py send 13800138000 --proxy http://127.0.0.1:8888 --dump
```

退出码：`0` 成功 / `1` 接口失败 / `2` 需要滑块验证。

---

## 5. 错误与风控

| 场景 | 表现 | 处理 |
| --- | --- | --- |
| 需要滑块 | Step 1 `mode == 1` | 抛 `CaptchaRequiredError`，带 `captchaToken` 重试 Step 2 |
| 操作受限 | Step 1 `mode == 2` | 抛 `RestrictedError`，提示 `msg`，等待后重试 |
| 验证码错误 / 过期 | Step 3 `success=false` | 抛 `SmsLoginError`，`code` 见响应 |
| checkToken 失效 | Step 3 失败 | 重走 Step 1 + Step 2（不要复用旧 token） |
| 非 JSON 响应 | 网关异常 / 被拦截 | 抛 `SmsLoginError("服务器返回非 JSON 响应")` |

> 风控码 `017129` / `017130` 是密码登录链路的滑块拦截码（见 Dart `_checkRiskCode`）；
> 短信链路的滑块走的是 Step 1 的 `mode == 1`，二者不是同一条判定路径。

---

## 6. 与 Dart 实现的对应关系

| Python | Dart |
| --- | --- |
| `SmsLoginClient.get_safe_token` | `AuthRemoteDataSource.getSmsSafeToken` |
| `SmsLoginClient.send_sms` | `AuthRemoteDataSource.sendSmsByLogin` |
| `SmsLoginClient.request_code` | `AuthRepositoryImpl.sendSmsCode` |
| `SmsLoginClient.login` | `AuthRemoteDataSource.loginWithSmsCode` + `AuthRepositoryImpl.loginWithSms` |
| `SmsLoginClient._enrich` | `AuthRepositoryImpl._buildSession` |
| `_headers` | `SignInterceptor` + `AuthInterceptor` |
| `_is_success` | `ApiResponse.isSuccess` |
| `CaptchaRequiredError` | `CaptchaRequiredException` |
| `SmsLoginError` | `AuthException` |

---

## 7. 环境

- Python 3.9+，依赖 `requests`（系统 Python 3.14 已自带 2.32.3）
- 若走本地抓包代理，建议同时把 `SmsLoginClient(verify_ssl=False)` 打开以校验自签名证书
