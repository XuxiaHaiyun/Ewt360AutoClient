#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""EWT360 短信验证码登录 —— Python 参考实现。

从 Flutter 客户端 `lib/features/auth/**` 抽取并直译，字段/签名/请求头与
Dart 侧逐项对齐（不做任何"看起来更合理"的改写）。

三步流程：
    Step 1  POST /api/safecenter/business/control/type            取 safeToken + mode
    Step 2  POST /api/usercenter/user/login/sms/byLogin/safecenter 发短信，取 checkToken
    Step 3  POST /api/usercenter/user/login/mobile/login           验证码登录，取 token

依赖：requests（系统 Python 3.14 已自带 2.32.3）
    pip install requests

命令行：
    # 只发短信（打印 safeToken / checkToken，用于手工分步调试）
    python sms_login.py send 13800138000

    # 完整交互：发短信 → 终端输入验证码 → 登录 → 补全会话信息
    python sms_login.py login 13800138000

    # 已有 checkToken + 验证码时直接登录
    python sms_login.py login 13800138000 --code 123456 --check-token <token>

    # 走代理 / 打印原始响应
    python sms_login.py send 13800138000 --proxy http://127.0.0.1:8888 --dump
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Dict, Optional

import requests

# ─────────────────────────── 常量（对齐 crypto_constants.dart / api_constants.dart）───────────────────────────

GATEWAY_DOMAIN = "https://gateway.ewt360.com"

# WEB 请求签名
WEB_SIGN_SECRET_KEY = "bdc739ff2dcf"
WEB_SECRET_ID = "2"
WEB_PLATFORM = "1"

# safecenter checkSign / DLOG 共用密钥
DLOG_SIGN_KEY = "eo^nye1j#!wt2%v)"

# 短信登录滑块验证 bizCode
SMS_CAPTCHA_BIZ_CODE = "mst1634782715743"

# 端点
URL_SAFECENTER_CONTROL_TYPE = "/api/safecenter/business/control/type"
URL_SMS_BY_LOGIN = "/api/usercenter/user/login/sms/byLogin/safecenter"
URL_SMS_LOGIN = "/api/usercenter/user/login/mobile/login"
URL_GET_USER = "/api/usercenter/user/login/getUser"
URL_SCHOOL_USER_INFO = "/api/eteacherproduct/school/getSchoolUserInfo"
URL_BASE_INFO = "/api/usercenter/user/baseinfo"

DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36 Edg/147.0.0.0"
)

# 与 EndpointConfig.defaults() 的 extraHeaders 一致
EXTRA_HEADERS = {
    "sec-ch-ua": '"Not(A:Brand";v="8", "Chromium";v="147", "Microsoft Edge";v="147"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Windows"',
    "Sec-Fetch-Site": "same-site",
    "Sec-Fetch-Mode": "cors",
    "Sec-Fetch-Dest": "empty",
    "DNT": "1",
}

DEFAULT_TIMEOUT = 15


# ─────────────────────────── 异常 ───────────────────────────

class SmsLoginError(Exception):
    """接口返回失败（业务码非成功）。"""

    def __init__(self, message: str, code: str = "", payload: Any = None):
        super().__init__(message)
        self.code = code
        self.payload = payload


class CaptchaRequiredError(SmsLoginError):
    """需要滑块验证（mode == 1）。

    解决办法：用 bizCode=mst1634782715743 走滑块拿到 captchaToken，
    再把它作为 captcha_token 重发短信。
    """

    def __init__(self, message: str = "需要滑块验证", biz_code: str = SMS_CAPTCHA_BIZ_CODE):
        super().__init__(message)
        self.biz_code = biz_code


class RestrictedError(SmsLoginError):
    """操作受限（mode == 2），通常是频控/风控拦截。"""


# ─────────────────────────── 结果模型 ───────────────────────────

@dataclass
class SafeTokenResult:
    """Step 1 结果。"""
    safe_token: str
    mode: int          # 0=无需验证 1=需要滑块 2=受限
    msg: str = ""
    raw: Dict[str, Any] = field(default_factory=dict)


@dataclass
class SendSmsResult:
    """Step 2 结果。"""
    check_token: str
    exist_user: bool   # 该手机号是否已注册
    raw: Dict[str, Any] = field(default_factory=dict)


@dataclass
class LoginResult:
    """Step 3 结果（登录响应 data）。"""
    token: str
    user_id: str = ""
    account: str = ""
    nick_name: str = ""
    avatar: str = ""
    mobile: str = ""
    school_id: str = ""
    school_name: str = ""
    real_name: str = ""
    province_code: str = ""
    raw: Dict[str, Any] = field(default_factory=dict)

    def __str__(self) -> str:  # pragma: no cover - 调试输出
        return (
            f"token={self.token}\n"
            f"userId={self.user_id}  schoolId={self.school_id}\n"
            f"account={self.account}  realName={self.real_name}\n"
            f"mobile={self.mobile}  provinceCode={self.province_code}"
        )


# ─────────────────────────── 客户端 ───────────────────────────

class SmsLoginClient:
    """短信验证码登录客户端。

    对应 Dart：
        AuthRemoteDataSource.getSmsSafeToken / sendSmsByLogin / loginWithSmsCode
        + AuthRepositoryImpl.sendSmsCode / loginWithSms / _buildSession
    """

    def __init__(
        self,
        proxy: Optional[str] = None,
        timeout: int = DEFAULT_TIMEOUT,
        user_agent: str = DEFAULT_UA,
        verify_ssl: bool = True,
        token: str = "0",
    ) -> None:
        self.timeout = timeout
        self.user_agent = user_agent
        self.verify_ssl = verify_ssl
        self.token = token          # 登录后写回，供后续接口使用
        self.dump = False           # 打印原始响应

        self.session = requests.Session()
        if proxy:
            self.session.proxies.update({"http": proxy, "https": proxy})

    # ── 底层请求 ──

    def _headers(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        """构造网关请求头。

        SignInterceptor:  md5(timestamp + secretKey).upper()
        AuthInterceptor:  token / User-Agent / Origin / Referer + extraHeaders
        """
        timestamp = str(int(time.time() * 1000))
        sign = hashlib.md5(
            (timestamp + WEB_SIGN_SECRET_KEY).encode("utf-8")
        ).hexdigest().upper()

        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en-US;q=0.8",
            "timestamp": timestamp,
            "sign": sign,
            "secretId": WEB_SECRET_ID,
            "platform": WEB_PLATFORM,
            "token": self.token if self.token else "0",
            "Origin": "https://www.ewt360.com",
            "Referer": "https://www.ewt360.com/",
            "User-Agent": self.user_agent,
        }
        headers.update(EXTRA_HEADERS)
        if extra:
            headers.update(extra)
        return headers

    def _post(self, path: str, body: Dict[str, Any], extra_headers: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
        url = GATEWAY_DOMAIN + path
        resp = self.session.post(
            url,
            data=json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            headers=self._headers(extra_headers),
            timeout=self.timeout,
            verify=self.verify_ssl,
        )
        resp.raise_for_status()
        try:
            payload = resp.json()
        except ValueError:
            raise SmsLoginError("服务器返回非 JSON 响应", code=str(resp.status_code))

        if self.dump:
            print(f"[dump] {path} -> {json.dumps(payload, ensure_ascii=False)}")

        if not _is_success(payload):
            raise SmsLoginError(
                payload.get("msg") or "请求失败",
                code=str(payload.get("code") or ""),
                payload=payload,
            )
        return payload

    # ── Step 1：安全令牌 ──

    def get_safe_token(self, phone: str, biz_code: str = SMS_CAPTCHA_BIZ_CODE) -> SafeTokenResult:
        """POST /api/safecenter/business/control/type

        checkSign = MD5(secret + bizCode + mobile + timestamp + secret)
        """
        timestamp = int(time.time() * 1000)
        check_sign = hashlib.md5(
            f"{DLOG_SIGN_KEY}{biz_code}{phone}{timestamp}{DLOG_SIGN_KEY}".encode("utf-8")
        ).hexdigest()

        payload = self._post(
            URL_SAFECENTER_CONTROL_TYPE,
            {
                "bizCode": biz_code,
                "type": "2",
                "mobile": phone,
                "timestamp": timestamp,
                "checkSign": check_sign,
            },
        )
        data = payload.get("data") or {}
        return SafeTokenResult(
            safe_token=str(data.get("token") or ""),
            mode=int(data.get("mode") or 0),
            msg=str(data.get("msg") or ""),
            raw=data,
        )

    # ── Step 2：发送短信 ──

    def send_sms(self, phone: str, safe_token: str, captcha_token: Optional[str] = None) -> SendSmsResult:
        """POST /api/usercenter/user/login/sms/byLogin/safecenter

        注意这两个额外头（Dart 侧显式传，缺一不可）：
            token: 0
            referurl: https://www.ewt360.com/
        """
        body: Dict[str, Any] = {
            "platform": 1,
            "mobile": phone,
            "safeToken": safe_token,
        }
        if captcha_token:
            body["captchaToken"] = captcha_token

        payload = self._post(
            URL_SMS_BY_LOGIN,
            body,
            extra_headers={"token": "0", "referurl": "https://www.ewt360.com/"},
        )
        data = payload.get("data") or {}
        return SendSmsResult(
            check_token=str(data.get("checkToken") or ""),
            exist_user=bool(data.get("existUser")),
            raw=data,
        )

    def request_code(self, phone: str, captcha_token: Optional[str] = None) -> SendSmsResult:
        """Step1 + Step2 合并：拿安全令牌并发短信。

        mode == 1 → CaptchaRequiredError（需带 captcha_token 重试）
        mode == 2 → RestrictedError
        """
        safe = self.get_safe_token(phone)
        if safe.mode == 1:
            raise CaptchaRequiredError(safe.msg or "需要滑块验证")
        if safe.mode == 2:
            raise RestrictedError(safe.msg or "操作受限，请稍后再试")
        return self.send_sms(phone, safe.safe_token, captcha_token)

    # ── Step 3：验证码登录 ──

    def login(self, phone: str, sms_code: str, check_token: str, fetch_profile: bool = True) -> LoginResult:
        """POST /api/usercenter/user/login/mobile/login"""
        payload = self._post(
            URL_SMS_LOGIN,
            {
                "platform": 1,
                "mobile": phone,
                "smsCode": sms_code,
                "autoLogin": True,
                "checkToken": check_token,
            },
            extra_headers={"token": "0", "referurl": "https://www.ewt360.com/"},
        )
        data = payload.get("data") or {}
        token = str(data.get("token") or "")
        if not token:
            raise SmsLoginError("登录响应未返回 token", payload=payload)

        self.token = token  # 后续请求携带

        result = LoginResult(
            token=token,
            user_id=str(data.get("userId") or ""),
            account=str(data.get("account") or phone),
            nick_name=str(data.get("nickName") or ""),
            avatar=str(data.get("avatar") or ""),
            mobile=str(data.get("mobile") or phone),
            raw=data,
        )
        if fetch_profile:
            self._enrich(result)
        return result

    def _enrich(self, result: LoginResult) -> None:
        """补全 userId / schoolId / 真名 / 头像 / 学校名 / 省份码。

        与 AuthRepositoryImpl._buildSession 一致：任一接口失败都静默跳过，
        不影响登录结果。
        """
        try:
            school = self._get_json(URL_SCHOOL_USER_INFO)
            result.user_id = str(school.get("userId") or result.user_id)
            result.school_id = str(school.get("schoolId") or "")
        except Exception:
            pass

        try:
            base = self._get_json(URL_BASE_INFO)
            result.real_name = str(base.get("realName") or result.real_name)
            result.avatar = str(base.get("photoUrl") or base.get("avatar") or result.avatar)
            result.school_name = str(base.get("schoolName") or "")
            result.account = str(base.get("account") or base.get("userName") or result.account)
            result.mobile = str(base.get("mobile") or result.mobile)
            result.province_code = str(base.get("memberProvinceCode") or "")
        except Exception:
            pass

    def _get_json(self, path: str) -> Dict[str, Any]:
        resp = self.session.get(
            GATEWAY_DOMAIN + path,
            headers=self._headers(),
            timeout=self.timeout,
            verify=self.verify_ssl,
        )
        resp.raise_for_status()
        payload = resp.json()
        if self.dump:
            print(f"[dump] {path} -> {json.dumps(payload, ensure_ascii=False)}")
        if not _is_success(payload):
            raise SmsLoginError(payload.get("msg") or "请求失败", code=str(payload.get("code") or ""))
        return payload.get("data") or {}


def _is_success(payload: Dict[str, Any]) -> bool:
    """网关成功判定：success==true 或 code in ('00000','200')。"""
    code = str(payload.get("code") or "")
    return bool(payload.get("success")) or code in ("00000", "200")


# ─────────────────────────── CLI ───────────────────────────

def _build_client(args: argparse.Namespace) -> SmsLoginClient:
    client = SmsLoginClient(proxy=args.proxy, timeout=args.timeout)
    client.dump = args.dump
    return client


def cmd_send(args: argparse.Namespace) -> int:
    client = _build_client(args)
    try:
        result = client.request_code(args.phone, captcha_token=args.captcha_token)
    except CaptchaRequiredError as e:
        print(f"[需要滑块] {e}  bizCode={e.biz_code}")
        print("拿到 captchaToken 后重试：--captcha-token <token>")
        return 2
    except (RestrictedError, SmsLoginError) as e:
        print(f"[失败] {e} (code={getattr(e, 'code', '')})")
        return 1

    print(f"[已发送] checkToken={result.check_token}")
    print(f"         existUser={result.exist_user}")
    return 0


def cmd_login(args: argparse.Namespace) -> int:
    client = _build_client(args)

    check_token = args.check_token
    if not check_token:
        try:
            sent = client.request_code(args.phone, captcha_token=args.captcha_token)
        except CaptchaRequiredError as e:
            print(f"[需要滑块] {e}  bizCode={e.biz_code}")
            return 2
        except (RestrictedError, SmsLoginError) as e:
            print(f"[失败] {e} (code={getattr(e, 'code', '')})")
            return 1
        check_token = sent.check_token
        print(f"[已发送] 短信已下发，existUser={sent.exist_user}")

    code = args.code
    if not code:
        try:
            code = input("请输入短信验证码: ").strip()
        except EOFError:
            print("[失败] 未提供验证码，用 --code 传入")
            return 1
    if not code:
        print("[失败] 验证码为空")
        return 1

    try:
        session = client.login(args.phone, code, check_token)
    except SmsLoginError as e:
        print(f"[登录失败] {e} (code={getattr(e, 'code', '')})")
        return 1

    print("[登录成功]")
    print(session)
    return 0


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description="EWT360 短信验证码登录")
    parser.add_argument("--proxy", help="HTTP 代理，如 http://127.0.0.1:8888")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="超时秒数")
    parser.add_argument("--dump", action="store_true", help="打印接口原始响应")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_send = sub.add_parser("send", help="仅发送短信验证码")
    p_send.add_argument("phone")
    p_send.add_argument("--captcha-token", help="滑块验证令牌（mode==1 时必填）")
    p_send.set_defaults(func=cmd_send)

    p_login = sub.add_parser("login", help="发短信 + 验证码登录")
    p_login.add_argument("phone")
    p_login.add_argument("--code", help="短信验证码（不传则交互输入）")
    p_login.add_argument("--check-token", help="跳过发短信，直接复用已有 checkToken")
    p_login.add_argument("--captcha-token", help="滑块验证令牌（mode==1 时必填）")
    p_login.set_defaults(func=cmd_login)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
