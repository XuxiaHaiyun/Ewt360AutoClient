# -*- coding: utf-8 -*-
"""
EWT360 收藏夹（错题本）获取答案 · 可运行 Python

功能：
  1. 列出收藏夹（错题本）            GET /api/wrongquestion/label/list
  2. 列出某收藏夹内的题目（翻页）     GET /api/answerprod/web/wrongquestion/label/getquestion
  3. 拉取单题详情（题干+答案+解析）   GET /api/answerprod/web/wrongquestion/collect/question/info
  4. （可选）拉取单题解析            GET /api/answerprod/web/wrongquestion/collect/question/analysis

依据：
  ewt_auto_client/lib/features/answer/data/datasources/answer_remote_datasource.dart
  （「收藏夹 API (wrongquestion)」段落）+ core/network 拦截器 + core/constants/crypto_constants.dart

依赖：
  pip install requests

用法：
  1. 把下方 TOKEN 换成浏览器 cookie 里的真实 token（形如 161000000-1-xxxxxxxx）
  2. 至少设置 SUBJECT_ID（学科 ID；0=全部）
  3. 运行：python favorites_answer.py
  4. 脚本会打印每个接口的「原始响应」，方便对照真实字段（文档中响应体为推断，以实测为准）

说明：
  - 收藏夹接口用【默认】请求头（Origin/Referer = www.ewt360.com），不是答案接口的 web.ewt360.com。
  - 必须带 sign 签名（MD5(timestamp + secretKey).upper()，secretKey="bdc739ff2dcf"）。
  - 接口 2 有多 URL 回退，本脚本自动依次尝试。
"""

import hashlib
import json
import time
from typing import Any, Dict, List, Optional, Tuple

import requests

# ============================================================
# 一、运行时常量（替换为真实值）
# ============================================================
GATEWAY_HOST = "https://gateway.ewt360.com"

# 登录身份：从浏览器 cookie 中取，cookie 名为 "token"
TOKEN = "161000000-1-xxxxxxxxxxxxxxxx"   # TODO: 替换为真实 token

# 学科 ID：1=语文 2=数学 3=英语 ...（具体编号以平台为准，0=全部）
SUBJECT_ID = 0                            # TODO: 替换为目标学科 ID

# 签名密钥（CryptoConstants.webSignSecretKey）
SIGN_SECRET_KEY = "bdc739ff2dcf"
SECRET_ID = "2"                           # CryptoConstants.webSecretId
PLATFORM = "1"                            # CryptoConstants.webPlatform

# 默认 Origin/Referer（注意：不是 web.ewt360.com）
DEFAULT_ORIGIN = "https://www.ewt360.com"
DEFAULT_REFERER = "https://www.ewt360.com/"

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36 Edg/147.0.0.0"
)


# ============================================================
# 二、URL 常量
# ============================================================
URL_LABEL_LIST   = "/api/wrongquestion/label/list"
# 接口 2 的多 URL 回退（依次尝试）
URL_GET_QUESTION = [
    "/api/answerprod/web/wrongquestion/label/getquestion",
    "/api/answerprod/web/wrongquestion/collect/label/getquestion",
    "/api/wrongquestion/label/getquestion",
]
URL_QUESTION_INFO     = "/api/answerprod/web/wrongquestion/collect/question/info"
URL_QUESTION_ANALYSIS = "/api/answerprod/web/wrongquestion/collect/question/analysis"


# ============================================================
# 三、签名与请求头
# ============================================================
def make_sign(secret_key: str = SIGN_SECRET_KEY) -> Tuple[str, str]:
    """生成 (timestamp_ms, sign)

    sign = MD5(timestamp + secretKey).upper()
    对齐 SignInterceptor.generateSign。
    """
    ts = str(int(time.time() * 1000))
    sign = hashlib.md5((ts + secret_key).encode("utf-8")).hexdigest().upper()
    return ts, sign


def default_headers() -> Dict[str, str]:
    """收藏夹接口默认请求头（AuthInterceptor + SignInterceptor）"""
    ts, sign = make_sign()
    return {
        "Content-Type": "application/json",
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "User-Agent": USER_AGENT,
        "Origin": DEFAULT_ORIGIN,
        "Referer": DEFAULT_REFERER,
        "token": TOKEN,
        "platform": PLATFORM,
        "secretId": SECRET_ID,
        "timestamp": ts,
        "sign": sign,
        "sec-ch-ua": '"Not(A:Brand";v="8", "Chromium";v="147", "Microsoft Edge";v="147"',
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": '"Windows"',
        "Sec-Fetch-Site": "same-site",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Dest": "empty",
        "DNT": "1",
    }


# ============================================================
# 四、HTTP 工具
# ============================================================
def _request(method: str, url: str, *,
             params: Optional[Dict[str, Any]] = None,
             headers: Optional[Dict[str, str]] = None,
             timeout: int = 15,
             verbose: bool = True) -> Dict[str, Any]:
    """发送请求并解析统一 JSON 响应。

    返回 {"success", "code", "msg", "data", "raw"}
    """
    full_url = url if url.startswith("http") else f"{GATEWAY_HOST}{url}"
    hdrs = headers or default_headers()
    if verbose:
        print(f"\n[SEND] {method} {full_url}")
        if params:
            print(f"       query={params}")
    resp = requests.request(method, full_url, params=params, headers=hdrs, timeout=timeout)
    if verbose:
        print(f"       -> HTTP {resp.status_code}")
        print(f"       raw={resp.text[:600]}")
    try:
        j = resp.json()
    except Exception:
        return {"success": False, "code": str(resp.status_code),
                "msg": f"非 JSON 响应: {resp.text[:200]}", "data": None, "raw": {}}
    return {
        "success": bool(j.get("success", False)) or j.get("code") == "200",
        "code": j.get("code", ""),
        "msg": j.get("msg") or j.get("message") or "",
        "data": j.get("data"),
        "raw": j,
    }


# ============================================================
# 五、接口封装
# ============================================================
def get_label_list(subject_id: int = SUBJECT_ID) -> Dict[str, Any]:
    """1. 获取收藏夹（错题本）列表

    GET /api/wrongquestion/label/list?subjectId={subjectId}&questionId=0
    """
    return _request("GET", URL_LABEL_LIST,
                    params={"subjectId": subject_id, "questionId": 0})


def get_questions_from_label(label_id: Any, subject_id: int = SUBJECT_ID,
                             offset: int = 0, limit: int = 50) -> Dict[str, Any]:
    """2. 获取收藏夹内题目（多 URL 回退）

    GET .../wrongquestion/label/getquestion?labelId=&subjectId=&offset=&limit=
    """
    params = {"labelId": label_id, "subjectId": subject_id,
              "offset": offset, "limit": limit}
    last = None
    for endpoint in URL_GET_QUESTION:
        r = _request("GET", endpoint, params=params)
        if r["success"]:
            return r
        last = r
    return last or {"success": False, "code": "", "msg": "所有收藏夹接口均失败",
                    "data": None, "raw": {}}


def get_question_info(question_id: str, subject_id: int = SUBJECT_ID,
                      label_id: Any = -1) -> Dict[str, Any]:
    """3. 获取收藏题目详情（题干 + 答案 + 解析）

    GET .../collect/question/info?questionId=&subjectId=&labelId=
    """
    return _request("GET", URL_QUESTION_INFO,
                    params={"questionId": question_id, "subjectId": subject_id,
                            "labelId": label_id})


def get_question_analysis(question_id: str, subject_id: int = SUBJECT_ID,
                          label_id: Any = -1) -> Dict[str, Any]:
    """4. （可选）获取收藏题目解析

    GET .../collect/question/analysis?questionId=&subjectId=&labelId=
    """
    return _request("GET", URL_QUESTION_ANALYSIS,
                    params={"questionId": question_id, "subjectId": subject_id,
                            "labelId": label_id})


# ============================================================
# 六、端到端 Demo：拉取一个收藏夹的全部答案
# ============================================================
def run_favorites_demo(subject_id: int = SUBJECT_ID,
                       target_label_id: Optional[Any] = None,
                       with_analysis: bool = False) -> None:
    """列出收藏夹 → 列出题目（翻页）→ 逐题拉答案。

    target_label_id 为 None 时自动取第一个收藏夹。
    """
    print("=" * 70)
    print(f"[FAVORITES DEMO] subjectId={subject_id}")
    print("=" * 70)

    # 1. 收藏夹列表
    r = get_label_list(subject_id)
    if not r["success"] or not r["data"]:
        print(f"获取收藏夹列表失败: {r['msg']}")
        return
    labels = r["data"] if isinstance(r["data"], list) else r["data"].get("list", [])
    print(f"\n找到 {len(labels)} 个收藏夹:")
    for lb in labels:
        lid = lb.get("id") or lb.get("labelId")
        name = lb.get("label") or lb.get("labelName") or "(未命名)"
        cnt = lb.get("questionCount", "?")
        print(f"   - labelId={lid}  名称={name}  题数={cnt}")

    # 选定收藏夹
    if target_label_id is not None:
        label_id = target_label_id
    else:
        first = labels[0]
        label_id = first.get("id") or first.get("labelId")
    print(f"\n>>> 处理收藏夹 labelId={label_id}")

    # 2. 翻页拉取题目
    all_qids: List[str] = []
    offset = 0
    limit = 50
    while True:
        r = get_questions_from_label(label_id, subject_id, offset=offset, limit=limit)
        if not r["success"] or not r["data"]:
            print(f"  获取题目失败 (offset={offset}): {r['msg']}")
            break
        d = r["data"]
        items = d.get("list", d) if isinstance(d, dict) else d
        if not items:
            break
        for it in items:
            qid = it.get("questionId") or it.get("id")
            if qid:
                all_qids.append(str(qid))
        total = d.get("total") if isinstance(d, dict) else None
        if total is not None and offset + limit >= int(total):
            break
        offset += limit
        if offset > 2000:  # 安全上限
            break
    print(f"  共收集到 {len(all_qids)} 个题目 ID")

    # 3. 逐题拉答案
    print("\n" + "-" * 70)
    print("逐题拉取详情（题干/答案/解析）:")
    print("-" * 70)
    for i, qid in enumerate(all_qids, 1):
        info = get_question_info(qid, subject_id, label_id)
        if not info["success"] or not info["data"]:
            print(f"  [{i}] questionId={qid} 详情获取失败: {info['msg']}")
            continue
        data = info["data"]
        # 不同接口字段名可能不同，尽量兼容取值
        answer = (data.get("answerContent") or {}).get("correctAnswer") \
            or data.get("correctAnswer") or data.get("answer") or "(见原始响应)"
        print(f"  [{i}] questionId={qid}")
        print(f"       答案={answer}")
        if with_analysis:
            ana = get_question_analysis(qid, subject_id, label_id)
            if ana["success"] and ana["data"]:
                ac = ana["data"].get("analysisContent") or ana["data"].get("analysis")
                print(f"       解析={(ac[:120] if isinstance(ac, str) else ac)}")


# ============================================================
# 七、入口
# ============================================================
if __name__ == "__main__":
    if not TOKEN or TOKEN.startswith("160000000-1-"):
        print("提示: 请先把本文件顶部的 TOKEN 换成你浏览器 cookie 里的真实 token。")
        print("      继续运行将使用占位 token，多半会返回未登录/空数据。\n")

    # 默认：自动取第一个收藏夹，拉全部答案（不带独立解析接口）。
    # 想指定收藏夹：run_favorites_demo(SUBJECT_ID, target_label_id=123456)
    # 想带解析接口：run_favorites_demo(SUBJECT_ID, with_analysis=True)
    run_favorites_demo(SUBJECT_ID)
