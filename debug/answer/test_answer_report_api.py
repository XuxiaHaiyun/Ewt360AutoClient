# -*- coding: utf-8 -*-
"""
EWT answer-pc 答题报告/分析页面 API 调用测试代码

覆盖两类页面：
  - /answer-pc/exam/analysis  (bizCode=204, 单次答卷分析, 扁平 questions)
  - /answer-pc/report          (bizCode=205, 作业报告, 按题组 groups)

依据：Edge DevTools MCP 抓包分析 (debug/answer/answer_report_api_doc.md)

依赖：
  pip install requests

用法：
  1. 将下方 TOKEN / USER_ID 替换为登录后从浏览器 cookie 获取的真实值
  2. 直接运行：python test_answer_report_api.py
  3. 选择页面类型运行 demo：run_analysis_demo() 或 run_report_demo()
"""

import json
import time
from typing import Any, Dict, Optional

import requests


# ============================================================
# 一、运行时常量（替换为真实值）
# ============================================================
GATEWAY_HOST = "https://gateway.ewt360.com"
ANSWER_ORIGIN = "https://web.ewt360.com"

# 登录身份（从浏览器 cookie 中获取，cookie 名为 "token"）
TOKEN = "160000000-1-xxxxxxxxxxxxxxxx"  # 替换为真实 token
USER_ID = "160000000"                    # token 第一段

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"
)

DEFAULT_PLATFORM = "1"


# ============================================================
# 二、URL 常量
# ============================================================
# 通用
URL_USER_BASEINFO        = "/api/usercenter/user/baseinfo"
URL_COMMUNITY_WEBCONFIG  = "/api/community/webconfig/get"

# 共用（参数差异）
URL_ANSWER_REPORT        = "/api/answerprod/web/answer/report"
URL_RECORRECT_CHECK      = "/api/answerprod/web/answer/reCorrect/isReportCanBeReCorrect"
URL_DOWNLOAD_SWITCH      = "/api/answerprod/web/paper/dowload/switch"
URL_CORRECT_RESULT       = "/api/answerprod/web/answer/correct/result"
URL_PAPER_QUESTION_LIST  = "/api/answerprod/common/paper/getPaperQuestionByPaperId"
URL_IS_ALL_SUBJECT       = "/api/answerprod/common/paper/isAllSubjectQuestion"
URL_AI_QA_PERMISSION     = "/api/answerprod/web/answer/ai/qa/getAnswerAIQAPermission"

# exam/analysis (bizCode=204) 专有
URL_LIST_PAPER_REPORT    = "/api/answerprod/web/answer/listPaperAnswerReport"
URL_RECENT_REPORT        = "/api/answerprod/web/answer/getRecentAnswerReport"
URL_ANSWER_SHEET_INFO    = "/api/answerprod/common/answer/report/answerSheetInfo"
URL_WEBREPORT            = "/api/answerprod/web/answer/webreport"

# report (bizCode=205) 专有
URL_PAPER_VISIBILITY     = "/api/studyprod/web/paper/visibility"
URL_WEBREPORT_GROUP      = "/api/answerprod/web/answer/webreport/questionGroup"
URL_GROUP_SHEET_INFO     = "/api/answerprod/common/answer/report/groupAnswerSheetInfo"


# ============================================================
# 三、Headers 构造
# ============================================================
def common_headers(biz_code: str) -> Dict[str, str]:
    """通用业务请求头

    实测页面 JS 会显式设置 token/platform/bizCode/userId 四个自定义头，
    Content-Type=application/json，Origin/Referer 指向 web.ewt360.com。
    """
    return {
        "Content-Type": "application/json",
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Origin": ANSWER_ORIGIN,
        "Referer": f"{ANSWER_ORIGIN}/",
        "User-Agent": USER_AGENT,
        "token": TOKEN,
        "platform": DEFAULT_PLATFORM,
        "bizCode": biz_code,
        "userId": USER_ID,
        "sec-ch-ua": '"Not(A:Brand";v="8", "Chromium";v="151", "Microsoft Edge";v="151"',
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": '"Windows"',
        "Sec-Fetch-Site": "same-site",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Dest": "empty",
    }


def page_refer_url(biz_code: str, paper_id: str, report_id: str,
                   homework_id: Optional[str] = None,
                   assign_points: Optional[bool] = None) -> str:
    """构造与浏览器地址栏一致的 Referer URL

    不同页面 Query 顺序与参数略有差异，对齐线上真实 URL。
    """
    if biz_code == "204":
        # /answer-pc/exam/analysis?assignPoints=false&bizCode=204&paperId=X&platform=1&reportId=X
        ap = "false" if assign_points is False else "false"
        return (f"{ANSWER_ORIGIN}/answer-pc/exam/analysis?"
                f"assignPoints={ap}&bizCode=204&paperId={paper_id}"
                f"&platform=1&reportId={report_id}")
    else:
        # /answer-pc/report?bizCode=205&homeworkId=X&paperId=X&platform=1&reportId=X
        hid = homework_id or ""
        return (f"{ANSWER_ORIGIN}/answer-pc/report?"
                f"bizCode=205&homeworkId={hid}&paperId={paper_id}"
                f"&platform=1&reportId={report_id}")


# ============================================================
# 四、HTTP 工具
# ============================================================
def _request(method: str, url: str, *,
             params: Optional[Dict[str, Any]] = None,
             body: Optional[Dict[str, Any]] = None,
             headers: Optional[Dict[str, str]] = None,
             timeout: int = 15) -> Dict[str, Any]:
    """发送 HTTP 请求并解析统一 JSON 响应。

    统一响应格式：{success, code, msg, data}
    返回：{"success": bool, "code": str, "msg": str, "data": Any, "raw": dict}
    """
    full_url = url if url.startswith("http") else f"{GATEWAY_HOST}{url}"
    print(f"[SEND] {method} {full_url}")
    if params:
        print(f"       query={params}")
    if body is not None:
        print(f"       body={json.dumps(body, ensure_ascii=False)[:300]}...")

    resp = requests.request(method, full_url, params=params,
                            json=body if body is not None else None,
                            headers=headers, timeout=timeout)
    print(f"       -> HTTP {resp.status_code}: {resp.text[:200]}")
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
# 五、通用接口（两类页面都调用）
# ============================================================
def get_user_baseinfo() -> Dict[str, Any]:
    """获取登录用户基本信息

    GET /api/usercenter/user/baseinfo?<ts>
    页面用时间戳作 cache-buster，Python 端可直接不传。
    """
    ts = int(time.time() * 1000)
    return _request("GET", URL_USER_BASEINFO,
                    params={"_": ts},
                    headers=common_headers(biz_code="204"))


def get_community_webconfig() -> Dict[str, Any]:
    """获取 Web 端社区配置（客服二维码、反馈入口等）

    POST /api/community/webconfig/get
    """
    return _request("POST", URL_COMMUNITY_WEBCONFIG,
                    body={},
                    headers=common_headers(biz_code="204"))


# ============================================================
# 六、报告主接口（两类页面共用，参数差异）
# ============================================================
def get_answer_report(paper_id: str, report_id: str, biz_code: str,
                      homework_id: Optional[str] = None,
                      user_id: str = USER_ID) -> Dict[str, Any]:
    """获取答题报告概要

    GET /api/answerprod/web/answer/report

    - bizCode=204 (analysis): 不传 extId/homeworkId
    - bizCode=205 (report)  : 传 extId=homeworkId & homeworkId
    """
    params = {
        "paperId": paper_id,
        "platform": DEFAULT_PLATFORM,
        "userId": user_id,
        "expectReportStatus": "2",   # 期望报告状态：已完成批改
        "bizCode": biz_code,
        "reportId": report_id,
    }
    if biz_code == "205" and homework_id:
        params["extId"] = homework_id
        params["homeworkId"] = homework_id

    refer = page_refer_url(biz_code, paper_id, report_id, homework_id)
    headers = common_headers(biz_code)
    headers["Referer"] = refer
    return _request("GET", URL_ANSWER_REPORT, params=params, headers=headers)


def check_re_correct(paper_id: str, report_id: str, biz_code: str,
                     homework_id: Optional[str] = None) -> Dict[str, Any]:
    """是否可重新批改

    POST /api/answerprod/web/answer/reCorrect/isReportCanBeReCorrect
    返回 data: 0(不可重判) / 1(可重判)
    """
    body = {
        "paperId": paper_id,
        "reportId": report_id,
        "bizCode": biz_code,
        "platform": DEFAULT_PLATFORM,
    }
    if biz_code == "205" and homework_id:
        body["homeworkId"] = homework_id

    return _request("POST", URL_RECORRECT_CHECK, body=body,
                    headers=common_headers(biz_code))


def get_download_switch(paper_id: str, biz_code: str) -> Dict[str, Any]:
    """下载开关

    GET /api/answerprod/web/paper/dowload/switch?paperId=X&bizCode=X
    返回 data: bool
    """
    return _request("GET", URL_DOWNLOAD_SWITCH,
                    params={"paperId": paper_id, "bizCode": biz_code},
                    headers=common_headers(biz_code))


def get_correct_result(paper_id: str, report_id: str, biz_code: str) -> Dict[str, Any]:
    """批改结果概要

    GET /api/answerprod/web/answer/correct/result?paperId=X&platform=1&reportId=X&bizCode=X
    返回 data: {correctResult, hasCorrect, comment}
    """
    return _request("GET", URL_CORRECT_RESULT,
                    params={"paperId": paper_id, "platform": DEFAULT_PLATFORM,
                            "reportId": report_id, "bizCode": biz_code},
                    headers=common_headers(biz_code))


def get_paper_question_list(paper_id: str, biz_code: str = "204") -> Dict[str, Any]:
    """试卷题目索引

    GET /api/answerprod/common/paper/getPaperQuestionByPaperId?paperId=X
    返回 data: {paperId, paperName, questionList:[{questionId, questionNoShow, ...}]}
    """
    return _request("GET", URL_PAPER_QUESTION_LIST,
                    params={"paperId": paper_id},
                    headers=common_headers(biz_code))


def is_all_subject_question(paper_id: str, biz_code: str) -> Dict[str, Any]:
    """是否多学科综合卷

    GET /api/answerprod/common/paper/isAllSubjectQuestion?bizCode=X&paperId=X
    返回 data: 1(单学科) / 0(多学科)
    """
    return _request("GET", URL_IS_ALL_SUBJECT,
                    params={"bizCode": biz_code, "paperId": paper_id},
                    headers=common_headers(biz_code))


def get_ai_qa_permission(paper_id: str, report_id: str, biz_code: str,
                         homework_id: Optional[str] = None,
                         user_id: str = USER_ID) -> Dict[str, Any]:
    """AI 试题答疑权限

    POST /api/answerprod/web/answer/ai/qa/getAnswerAIQAPermission
    返回 data: null（关闭时）；success=false, code=9984001 表示本学科已关闭
    """
    body = {
        "paperId": paper_id,
        "reportId": report_id,
        "bizCode": biz_code,
        "platform": DEFAULT_PLATFORM,
        "userId": user_id,
    }
    if biz_code == "205" and homework_id:
        body["homeworkId"] = homework_id

    return _request("POST", URL_AI_QA_PERMISSION, body=body,
                    headers=common_headers(biz_code))


# ============================================================
# 七、exam/analysis 页面 (bizCode=204) 专有接口
# ============================================================
def list_paper_answer_report(paper_id: str, report_id: str,
                             user_id: str = USER_ID) -> Dict[str, Any]:
    """列出该试卷的所有历史答题报告

    POST /api/answerprod/web/answer/listPaperAnswerReport
    返回 data: {totalPages, pageIndex, pageSize, totalRecords, data:[...], havePrePage, haveNextPage}
    """
    body = {
        "paperId": paper_id,
        "reportId": report_id,
        "bizCode": "204",
        "platform": DEFAULT_PLATFORM,
        "userId": user_id,
    }
    return _request("POST", URL_LIST_PAPER_REPORT, body=body,
                    headers=common_headers("204"))


def get_recent_answer_report(paper_id: str, user_id: str = USER_ID) -> Dict[str, Any]:
    """获取最近一次答题报告

    POST /api/answerprod/web/answer/getRecentAnswerReport
    返回 data: 单条报告对象
    """
    body = {
        "paperId": paper_id,
        "bizCode": "204",
        "platform": DEFAULT_PLATFORM,
        "userId": user_id,
    }
    return _request("POST", URL_RECENT_REPORT, body=body,
                    headers=common_headers("204"))


def get_answer_sheet_info(paper_id: str, report_id: str,
                          user_id: str = USER_ID) -> Dict[str, Any]:
    """答题卡详情（扁平）

    POST /api/answerprod/common/answer/report/answerSheetInfo
    返回 data: {questionInfoList:[...], assignPoints, subjectId, imagesRiskList}
    """
    body = {
        "paperId": paper_id,
        "reportId": report_id,
        "platform": DEFAULT_PLATFORM,
        "bizCode": "204",
        "userId": user_id,
        "client": 1,
    }
    return _request("POST", URL_ANSWER_SHEET_INFO, body=body,
                    headers=common_headers("204"))


def get_webreport(paper_id: str, report_id: str,
                  user_id: str = USER_ID) -> Dict[str, Any]:
    """Web 报告（扁平 questions 数组）

    GET /api/answerprod/web/answer/webreport?platform=1&reportId=X&userId=X&bizCode=204
    返回 data: {paperId, reportId, title, userTimeStr, rightRate, allRight, questions:[...], ...}
    """
    params = {
        "platform": DEFAULT_PLATFORM,
        "reportId": report_id,
        "userId": user_id,
        "bizCode": "204",
    }
    refer = page_refer_url("204", paper_id, report_id)
    headers = common_headers("204")
    headers["Referer"] = refer
    return _request("GET", URL_WEBREPORT, params=params, headers=headers)


# ============================================================
# 八、report 页面 (bizCode=205) 专有接口
# ============================================================
def get_paper_visibility(paper_id: str, report_id: str,
                         homework_id: str) -> Dict[str, Any]:
    """试卷可见性（作业可能被教师关闭）

    GET /api/studyprod/web/paper/visibility?paperId=X&reportId=X&bizCode=205&homeworkId=X
    返回 data: bool
    """
    return _request("GET", URL_PAPER_VISIBILITY,
                    params={"paperId": paper_id, "reportId": report_id,
                            "bizCode": "205", "homeworkId": homework_id},
                    headers=common_headers("205"))


def get_webreport_question_group(paper_id: str, report_id: str,
                                 homework_id: str,
                                 user_id: str = USER_ID) -> Dict[str, Any]:
    """Web 报告（按题组 groups 分组）

    GET /api/answerprod/web/answer/webreport/questionGroup
        ?paperId=X&reportId=X&platform=1&bizCode=205&homeworkId=X&userId=X
    返回 data: {subjectId, subjectName, title, useTimeStr, myTotalScore, totalScore,
                groups:[{groupId, groupName, totalScore, myTotalScore, questions:[...]}],
                teacherReview*, ...}
    """
    params = {
        "paperId": paper_id,
        "reportId": report_id,
        "platform": DEFAULT_PLATFORM,
        "bizCode": "205",
        "homeworkId": homework_id,
        "userId": user_id,
    }
    refer = page_refer_url("205", paper_id, report_id, homework_id)
    headers = common_headers("205")
    headers["Referer"] = refer
    return _request("GET", URL_WEBREPORT_GROUP, params=params, headers=headers)


def get_group_answer_sheet_info(paper_id: str, report_id: str,
                                homework_id: str,
                                user_id: str = USER_ID) -> Dict[str, Any]:
    """答题卡详情（按题组分组）

    POST /api/answerprod/common/answer/report/groupAnswerSheetInfo
    返回 data: {paperId, paperName, assignPoints,
                groupQuestionList:[{groupId, groupName, totalScore, myTotalScore,
                                    questionInfoList:[...]}]}
    """
    body = {
        "paperId": paper_id,
        "reportId": report_id,
        "platform": DEFAULT_PLATFORM,
        "bizCode": "205",
        "homeworkId": homework_id,
        "userId": user_id,
        "client": 1,
    }
    return _request("POST", URL_GROUP_SHEET_INFO, body=body,
                    headers=common_headers("205"))


# ============================================================
# 九、Demo：复刻两类页面的完整调用时序
# ============================================================
def run_analysis_demo(paper_id: str, report_id: str) -> None:
    """复刻 /answer-pc/exam/analysis (bizCode=204) 的完整 API 调用时序

    使用示例：
      run_analysis_demo("2242575400780071280", "2325776270277115987")
    """
    print("=" * 70)
    print(f"[ANALYSIS DEMO] paperId={paper_id} reportId={report_id}")
    print("=" * 70)

    biz_code = "204"

    # 1. 用户基本信息
    get_user_baseinfo()
    # 2. 社区配置
    get_community_webconfig()
    # 3. 报告概要
    r = get_answer_report(paper_id, report_id, biz_code)
    if r["success"] and r["data"]:
        d = r["data"]
        print(f"  -> 报告概要: 题数={d.get('questionCount')}, 正确率={d.get('rightRate')}, "
              f"用时={d.get('answerTime')}秒, 赋分={d.get('assignPoints')}")
    # 4. 是否可重判
    check_re_correct(paper_id, report_id, biz_code)
    # 5. 历史报告列表
    list_paper_answer_report(paper_id, report_id)
    # 6. 下载开关
    get_download_switch(paper_id, biz_code)
    # 7. 试卷题目索引
    get_paper_question_list(paper_id, biz_code)
    # 8. 批改结果
    get_correct_result(paper_id, report_id, biz_code)
    # 9. 是否多学科
    is_all_subject_question(paper_id, biz_code)
    # 10. 最近报告
    get_recent_answer_report(paper_id)
    # 11. 答题卡（扁平）
    get_answer_sheet_info(paper_id, report_id)
    # 12. Web 报告（扁平 questions）
    r = get_webreport(paper_id, report_id)
    if r["success"] and r["data"]:
        d = r["data"]
        qs = d.get("questions") or []
        print(f"  -> Web报告: 标题={d.get('title')}, 题目数={len(qs)}, "
              f"正确率={d.get('rightRate')}%, 全对={d.get('allRight')}")
        for q in qs:
            print(f"     - 题{q.get('questionNo')}: {q.get('cateName')}/"
                  f"{q.get('subjectQuestionTypeName')}, rightStatus={q.get('rightStatus')}, "
                  f"myScore={q.get('myScore')}/{q.get('score')}")
    # 13. AI 答疑权限
    get_ai_qa_permission(paper_id, report_id, biz_code)


def run_report_demo(paper_id: str, report_id: str, homework_id: str) -> None:
    """复刻 /answer-pc/report (bizCode=205) 的完整 API 调用时序

    使用示例：
      run_report_demo("2272236290307785228", "2318559556986872029", "10495544")
    """
    print("=" * 70)
    print(f"[REPORT DEMO] paperId={paper_id} reportId={report_id} homeworkId={homework_id}")
    print("=" * 70)

    biz_code = "205"

    # 1. 用户基本信息
    get_user_baseinfo()
    # 2. 社区配置
    get_community_webconfig()
    # 3. 试卷可见性（report 页特有）
    r = get_paper_visibility(paper_id, report_id, homework_id)
    if r["success"]:
        print(f"  -> 试卷可见性: {r['data']}")
        if r["data"] is False:
            print("  !! 作业已被教师关闭查看权限，后续接口仍可调用但页面会拦截展示")
    # 4. 报告概要
    r = get_answer_report(paper_id, report_id, biz_code, homework_id)
    if r["success"] and r["data"]:
        d = r["data"]
        print(f"  -> 报告概要: 题数={d.get('questionCount')}, 正确率={d.get('rightRate')}, "
              f"用时={d.get('answerTime')}秒, 赋分={d.get('assignPoints')}")
    # 5. 下载开关
    get_download_switch(paper_id, biz_code)
    # 6. 批改结果
    get_correct_result(paper_id, report_id, biz_code)
    # 7. 试卷题目索引
    get_paper_question_list(paper_id, biz_code)
    # 8. 是否多学科
    is_all_subject_question(paper_id, biz_code)
    # 9. Web 报告（按题组分组，report 页核心）
    r = get_webreport_question_group(paper_id, report_id, homework_id)
    if r["success"] and r["data"]:
        d = r["data"]
        groups = d.get("groups") or []
        print(f"  -> Web报告(分组): 学科={d.get('subjectName')}, 标题={d.get('title')}, "
              f"得分={d.get('myTotalScore')}/{d.get('totalScore')}, 题组数={len(groups)}")
        for g in groups:
            qs = g.get("questions") or []
            print(f"     - 题组[{g.get('groupName')}]: 题数={g.get('totalQuestions')}, "
                  f"得分={g.get('myTotalScore')}/{g.get('totalScore')}")
            for q in qs:
                print(f"       题{q.get('questionNo')}: {q.get('cateName')}/"
                      f"{q.get('subjectQuestionTypeName')}, rightStatus={q.get('rightStatus')}, "
                      f"myScore={q.get('myScore')}/{q.get('score')}")
    # 10. 答题卡（按分组）
    get_group_answer_sheet_info(paper_id, report_id, homework_id)
    # 11. 是否可重判
    check_re_correct(paper_id, report_id, biz_code, homework_id)
    # 12. AI 答疑权限
    get_ai_qa_permission(paper_id, report_id, biz_code, homework_id)


# ============================================================
# 十、入口
# ============================================================
if __name__ == "__main__":
    # 5 个标签页的真实参数（从用户提供的 URL 中提取）

    # === exam/analysis (bizCode=204) ===
    ANALYSIS_CASES = [
        # (paperId, reportId)
        ("2242575400780071280", "2325776270277115987"),  # 标签页 [0]
        ("1728260591849136339", "2325124345780502586"),  # 标签页 [7]
        ("1728266965580579611", "2326408291894633017"),  # 标签页 [8]
    ]

    # === report (bizCode=205) ===
    REPORT_CASES = [
        # (paperId, reportId, homeworkId)
        ("2272236290307785228", "2318559556986872029", "10495544"),  # 标签页 [2]
        ("1982884601261179573", "2325777524407706291", "10495544"),  # 标签页 [4]
    ]

    print("##### 1. 运行 exam/analysis (bizCode=204) demo #####")
    run_analysis_demo(*ANALYSIS_CASES[0])

    print()
    print("##### 2. 运行 report (bizCode=205) demo #####")
    run_report_demo(*REPORT_CASES[0])
