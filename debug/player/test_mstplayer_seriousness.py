# -*- coding: utf-8 -*-
"""
mstplayer-v3.0.37 认真度检测接口调用测试代码

覆盖四类认真度检测：
  1. 确认型（illegalModal + ConfirmModal）：服务端返回 699001 错误码触发弹窗
  2. 互动型（bizInteractive 互动题）：到达指定时间点弹出题目，提交答案
  3. 滑块型（ecaptcha，业务层实现）：检测到异常时弹出滑块验证 → captchaToken → addVideocss 上报
  4. 被动防作弊（服务器时间同步、反自动化脚本检测）

  （滑块型由业务层 homework-play-video.js + ecaptcha SDK (5564.js) 实现，与 mstplayer SDK 独立）

依赖：requests
安装：pip install requests

实测响应结构（gateway API 统一格式）：
  { "success": bool, "code": string, "msg": string, "data": object|null }

实测错误码：
  - getInteractiveConfigDetail?interactiveConfigId=1  → code:"500",   msg:"获取交互配置异常"
  - submitAnswer (无效题目)                            → code:"626101", msg:"从interactive-video服务获取题目详情为空"

关联文档：
  - mstplayer_seriousness_check_doc.md（认真度检测详细分析）
  - mstplayer_behavior_doc.md（看课埋点基础）
  - test_mstplayer_api.py（签名算法与看课埋点上报，本文件复用其常量与签名函数）
"""

import hashlib
import json
import time

import requests

# 复用基础测试代码中的常量与签名实现，避免重复
from test_mstplayer_api import (
    USER_ID, TOKEN, LESSON_ID, COURSE_ID, VIDEO_BIZ_CODE,
    SCHOOL_ID, VIDEO_TYPE, SDK_VERSION,
    GATEWAY_HOST, REFER_URL, BROWSER_VER,
    MstPlayerReporter, make_secret_key, ServerClock,
    FC_PLAYING, CLOG_WATCH,
)


# ============================================================
# 一、互动型（答题型）API 端点
# ============================================================
INTERACTIVE_DETAIL_URL = (GATEWAY_HOST
                          + "/api/videoplayerprod/videoplayer/getInteractiveConfigDetail")
SUBMIT_ANSWER_URL = (GATEWAY_HOST
                     + "/api/videoplayerprod/videoplayer/submitAnswer")

# 互动题相关枚举（对应源码 CateEnum / RightStatusEnum / InteractiveEndEnum）
class CateEnum:
    RADIO = 1            # 单选
    MULTI_SELECT = 2     # 多选
    JUDGE = 3            # 判断

class QuestionContentTypeEnum:
    IMAGE = 1
    VIDEO = 2

class RightStatusEnum:
    UNCHECK = 0          # 未校验
    CORRECT = 1          # 正确
    HALF_CORRECT = 2     # 部分正确
    INCORRECT = 3        # 错误

class InteractiveEndEnum:
    NORMAL = 0           # 正常答题后关闭
    SKIP = 1             # 用户手动跳过
    AUTO_SKIP = 2        # 倒计时自动跳过
    ANSWER_SKIP = 3      # 未校验答案直接关闭
    INIT_SKIP = 4        # 初始化失败跳过

# 服务端错误码（认真度相关）
SERVER_CODE_POINT_ILLEGAL = "699001"        # 看课数据非法 → 触发确认型弹窗
SERVER_CODE_POINT_SIGNATURE = "699101"      # 签名错误
SERVER_CODE_POINT_PARAMS = "699102"         # 参数错误
CLIENT_CODE_POINT_ILLEGAL = 2002            # ErrorEnum.POINT_ILLEGAL

# 认真度检测相关服务端接口（本次新增）
LESSON_DETAIL_URL = GATEWAY_HOST + "/api/homeworkprod/player/getLessonDetailV2"
VIDEODP_URL = GATEWAY_HOST + "/api/homeworkprod/homework/student/getVideodp"
ADD_STUDP_URL = GATEWAY_HOST + "/api/homeworkprod/homework/student/addStudp"
SERIOUS_CHECK_DOWNGRADE_URL = GATEWAY_HOST + "/api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig"
CAB_URL = GATEWAY_HOST + "/api/homeworkprod/homework/student/cab"

# ============================================================
# 一'、滑块型（ecaptcha，业务层）API 端点与常量
# ============================================================
# ecaptcha SDK 走独立的 filegateway 域名，与 mstplayer 走的 gateway 不同
FILEGATEWAY_HOST = "https://filegateway.ewt360.com"
CAPTCHA_GET_URL = FILEGATEWAY_HOST + "/api/captcha/captcha/get"
CAPTCHA_VERIFY_URL = FILEGATEWAY_HOST + "/api/captcha/captcha/verify"

# addVideocss 上报接口（"添加视频检测点"的拼音缩写，与 CSS 无关）
ADD_VIDEOCSS_URL = GATEWAY_HOST + "/api/homeworkprod/homework/student/addVideocss"

# ecaptcha 业务码：mst(视频) + 时间戳，由 homework-play-video.js 中硬编码
ECAPTCHA_BIZ_CODE = "mst1784513466143"
# 验证码类型：2=滑块
ECAPTCHA_TYPE = "2"
# checkSign 签名密钥（来自 5564.js，md5(bizCode+mobile+deviceToken+token+timestamp+SECRET)）
ECAPTCHA_SECRET = "eo^nye1j#!wt2%v)"


class SeriousCheckResultEnum:
    """addVideocss 上报中 seriousCheckResult 字段的枚举（来自 homework-play-video.js）"""
    INIT_LOG = 0       # 检测弹窗显示时（初始化上报）
    ERROR_LOG = 1      # 检测失败/错过时
    SUCCESS_LOG = 2    # 检测通过时（携带 captchaToken）


class AddVideoCssTypeEnum:
    """
    addVideocss 上报中 type 字段的枚举。
    源码：type: interactiveVideo ? 3 : (contentType===1 ? 1 : 2)
    注意：type 取决于 interactiveVideo 和 contentType，与是否滑块型（isBlacklisted）无关。
    """
    NORMAL = 1         # interactiveVideo=false 且 contentType=1（普通录播视频 video_record）
    OTHER = 2          # interactiveVideo=false 且 contentType≠1（含 contentType=11 校长寄语 video_school 及其他）
    INTERACTIVE = 3    # interactiveVideo=true（互动视频 video_interact）


def calc_add_videocss_type(interactive_video: bool, content_type: int) -> int:
    """
    根据源码逻辑计算 addVideocss 的 type 字段值。
    源码：type: interactiveVideo ? 3 : (1===contentType ? 1 : 2)
    """
    if interactive_video:
        return AddVideoCssTypeEnum.INTERACTIVE
    return AddVideoCssTypeEnum.NORMAL if content_type == 1 else AddVideoCssTypeEnum.OTHER


def calc_interactive_point_id(interactive_video: bool):
    """
    根据源码逻辑计算 addVideocss 的 interactivePointId 字段值。
    源码：interactivePointId: interactiveVideo ? 100 : null
    注意：不是固定 100，而是取决于 interactiveVideo。
    """
    return 100 if interactive_video else None


# 11 年级特殊：lessonId 需 +2e6 上报
GRADE11_LESSON_ID_OFFSET = 2_000_000


# ============================================================
# 二、通用网关请求工具
# ============================================================
def _gateway_headers(content_type_json: bool = True):
    h = {
        "Accept": "application/json, text/plain, */*",
        "token": TOKEN,
        "Origin": "https://teacher.ewt360.com",
        "Referer": REFER_URL,
        "User-Agent": BROWSER_VER,
    }
    if content_type_json:
        h["Content-Type"] = "application/json"
    return h


def _print_send(method: str, url: str, body=None):
    print(f"[SEND] {method} {url}")
    if body is not None:
        b = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        print(f"       body={b[:300]}{'...' if len(b) > 300 else ''}")


def _print_resp(resp: requests.Response):
    print(f"       -> HTTP {resp.status_code}: {resp.text[:300]}")
    try:
        return resp.json()
    except Exception:
        return {}


# ============================================================
# 三、互动型：获取题目详情
# ============================================================
def get_interactive_config_detail(interactive_config_id: str,
                                  video_biz_code: str = VIDEO_BIZ_CODE,
                                  timeout: int = 15):
    """
    GET //gateway.ewt360.com/api/videoplayerprod/videoplayer/getInteractiveConfigDetail

    Query:
      interactiveConfigId : 互动配置ID（Long 类型，来自 interactiveInfo.interactiveConfigList[].id）
      videoBizCode        : 视频业务码（如 "1013"）

    返回 data 结构（推测，基于源码使用方式）:
      {
        "id": "configId",
        "interactiveSceneId": "sceneId",
        "question": {
          "id": "questionId",
          "cate": 1,                    # CateEnum: 1=单选 2=多选 3=判断
          "questionContentType": 1,     # 1=图片 2=视频
          "imageUrl": "https://...",
          "answers": ["A"]              # 正确答案
        }
      }
    """
    params = {
        "interactiveConfigId": interactive_config_id,
        "videoBizCode": video_biz_code,
    }
    url = INTERACTIVE_DETAIL_URL
    _print_send("GET", url + "?" + "&".join(f"{k}={v}" for k, v in params.items()))
    resp = requests.get(url, params=params, headers=_gateway_headers(),
                        timeout=timeout)
    return _print_resp(resp)


# ============================================================
# 四、互动型：提交答案
# ============================================================
def submit_interactive_answer(interactive_scene_id: str, question_id: str,
                              my_answers: list, total_seconds: int,
                              video_biz_code: str = VIDEO_BIZ_CODE,
                              lesson_id: str = LESSON_ID, timeout: int = 15):
    """
    POST //gateway.ewt360.com/api/videoplayerprod/videoplayer/submitAnswer

    Body:
      interactiveSceneId : 互动场景ID
      questionId         : 题目ID
      myAnswers          : 用户选择的答案列表，如 ["A"] 或 ["A","B"]
      totalSeconds       : 答题耗时（秒）
      videoBizCode       : 视频业务码
      lessonId           : 课程ID

    返回 data 结构:
      { "rightStatus": 1 }   # RightStatusEnum: 0=未校验 1=正确 2=部分正确 3=错误
    """
    body = {
        "interactiveSceneId": interactive_scene_id,
        "questionId": question_id,
        "myAnswers": my_answers,
        "totalSeconds": total_seconds,
        "videoBizCode": video_biz_code,
        "lessonId": lesson_id,
    }
    _print_send("POST", SUBMIT_ANSWER_URL, body)
    resp = requests.post(SUBMIT_ANSWER_URL, headers=_gateway_headers(),
                         json=body, timeout=timeout)
    return _print_resp(resp)


# ============================================================
# 五、互动型：完整答题流程模拟
# ============================================================
def simulate_interactive_flow(mock_config_id: str = "1",
                              mock_scene_id: str = "1",
                              mock_question_id: str = "1"):
    """
    模拟 BizInteractive 插件的完整答题流程：
      1. 到达 interactiveTimePoint → 暂停播放
      2. 调用 getInteractiveConfigDetail 加载题目
      3. 用户选择答案
      4. 调用 submitAnswer 提交
      5. 根据 rightStatus 显示答题结果
      6. 关闭弹窗，恢复播放（hideWithType）

    注意：当前视频（lessonId=117890）未配置互动题（interactiveInfo 为空），
          此处使用 mock ID 仅用于演示 API 调用与流程，服务端会返回错误。
          如需真实测试，请从有互动题配置的视频中获取真实 configId。
    """
    print("=" * 60)
    print("互动型认真度检测 - 完整答题流程模拟")
    print("=" * 60)
    print(f"  [步骤1] 到达互动题时间点，暂停播放器")
    print(f"          player.pause(); controlBar.hide();")

    # 步骤2：加载题目详情
    print(f"\n  [步骤2] 加载互动题详情 (configId={mock_config_id})")
    detail = get_interactive_config_detail(mock_config_id)
    success = detail.get("success", False)
    data = detail.get("data")

    if not success or not data:
        # 对应源码 doLoadDetail 的 catch 分支
        print(f"\n  [加载失败] code={detail.get('code')} msg={detail.get('msg')}")
        print(f"           → 源码行为: loadingLayer.showRetry() 显示'重试'按钮")
        print(f"           → 触发 InteractiveEvent.ERROR_SKIP")
        print(f"           → hideWithType(InteractiveEndEnum.INIT_SKIP)")
        return detail

    # 步骤3：解析题目（基于源码 Question 组件渲染逻辑）
    question = data.get("question", {})
    cate = question.get("cate", CateEnum.RADIO)
    cate_name = {1: "单选", 2: "多选", 3: "判断"}.get(cate, "未知")
    print(f"\n  [步骤3] 题目渲染")
    print(f"          questionId={question.get('id')}")
    print(f"          cate={cate} ({cate_name})")
    print(f"          contentType={question.get('questionContentType')}")
    if question.get("imageUrl"):
        print(f"          imageUrl={question['imageUrl'][:80]}...")

    # 步骤4：模拟用户选择答案
    my_answers = question.get("answers", ["A"])  # 演示：直接选正确答案
    print(f"\n  [步骤4] 用户选择答案: {my_answers}")

    # 步骤5：提交答案
    print(f"\n  [步骤5] 提交答案")
    start_ts = time.time()
    result = submit_interactive_answer(
        interactive_scene_id=data.get("interactiveSceneId", mock_scene_id),
        question_id=question.get("id", mock_question_id),
        my_answers=my_answers,
        total_seconds=int(time.time() - start_ts) or 5,
    )
    right_status = (result.get("data") or {}).get("rightStatus",
                                                   RightStatusEnum.UNCHECK)
    status_name = {0: "未校验", 1: "正确", 2: "部分正确", 3: "错误"}.get(
        right_status, "未知")

    # 步骤6：根据 rightStatus 决定关闭方式（对应源码 onCheckAnswer）
    print(f"\n  [步骤6] 答题结果: rightStatus={right_status} ({status_name})")
    if right_status == RightStatusEnum.UNCHECK:
        print(f"          → hideWithType(InteractiveEndEnum.ANSWER_SKIP)")
    else:
        print(f"          → endLayer.show({right_status == RightStatusEnum.CORRECT})")
        print(f"          → hideWithType(InteractiveEndEnum.NORMAL)")
    print(f"          → player.silencePlay() 自动继续播放")
    return result


# ============================================================
# 六、确认型：699001 错误响应处理模拟
# ============================================================
def mock_699001_response(msg: str = "检测到异常观看行为，本次学习记录已暂停") -> dict:
    """
    构造一个模拟的 699001 服务端响应，用于演示确认型检测的触发流程。

    真实场景下，当 collect/batch 上报的看课数据被服务端判定为非法时
    （例如：检测到倍速作弊、时间戳篡改、心跳异常等），服务端返回：
      { "code": 699001, "msg": "...", "data": null }
    """
    return {
        "code": 699001,
        "msg": msg,
        "data": None,
    }


def handle_point_illegal(response: dict, illegal_modal: bool = True):
    """
    复刻 BizPoint.fcUpload 的 catch 分支处理逻辑（对应源码）：

    if (699001 === n):
        this.ignoreUploadPause();                       // 不再上报暂停事件
        this.checkDiffTime(data.ts, getMillisecond()-l); // 校准服务器时间
        player.trigger("error", makeError(POINT_ILLEGAL, e2));
        if (illegalModal):
            player.trigger(EConfirmModalEvent.SHOW, {
                title: "视频已暂停",
                content: e2.msg,
                confirmText: "我知道了"
            });
    """
    print("=" * 60)
    print("确认型认真度检测 - 699001 错误响应处理模拟")
    print("=" * 60)
    code = response.get("code")
    msg = response.get("msg", "")
    print(f"  收到服务端响应: code={code} msg={msg}")

    if code != 699001:
        print(f"  → 非 699001，不触发确认型弹窗（其他错误码走 POINT_FC/POINT_SIGNATURE_ERROR 分支）")
        return False

    print(f"\n  [源码行为]")
    print(f"    1. ErrorEnum.POINT_ILLEGAL (2002) 触发 player.trigger('error')")
    print(f"    2. ignoreUploadPause()  → 暂停事件不再上报，避免循环")
    print(f"    3. checkDiffTime()      → 用响应 ts 校准服务器时间")
    print(f"    4. illegalModal={illegal_modal}")
    if illegal_modal:
        print(f"\n  [弹窗触发] EConfirmModalEvent.SHOW")
        print(f"    title:       视频已暂停")
        print(f"    content:     {msg}")
        print(f"    confirmText: 我知道了")
        print(f"\n  [用户交互]")
        print(f"    用户点击 '我知道了' → onClose 回调 → 弹窗关闭")
        print(f"    视频保持暂停状态，用户需手动点击播放继续")
    else:
        print(f"    illegalModal=false → 不弹窗，仅 error 事件")
    return True


def simulate_confirm_modal_flow():
    """
    演示完整流程：
      1. 播放器正常上报心跳（DRY_RUN）
      2. 服务端返回 699001（mock）
      3. 客户端触发确认型弹窗
    """
    # 步骤1：构造一次正常的心跳上报（不实际发送）
    print()
    print("[步骤1] 构造一次正常心跳上报（DRY_RUN，不发送）")
    reporter = MstPlayerReporter()
    reporter.begin_time = reporter.clock.now()
    ev = reporter._build_event(FC_PLAYING, CLOG_WATCH, 60000, 60000,
                               reporter.begin_time, 60, 763)
    payload = reporter.build_payload(ev, reporter.begin_time)
    print(f"  signature={payload['signature']}")
    print(f"  action={ev['action']} stay_time={ev['stay_time']}")

    # 步骤2：模拟服务端返回 699001
    print(f"\n[步骤2] 模拟服务端返回 699001（看课数据被判定为非法）")
    mock_resp = mock_699001_response()

    # 步骤3：客户端处理
    print(f"\n[步骤3] 客户端 BizPoint.fcUpload catch 分支处理")
    handle_point_illegal(mock_resp, illegal_modal=True)


# ============================================================
# 六·补、检测点位置与认真度检测降级接口测试
# ============================================================
def get_lesson_detail(lesson_id: str = LESSON_ID, course_id: str = COURSE_ID,
                      homework_id: int = 10495544, timeout: int = 15):
    """
    POST /api/homeworkprod/player/getLessonDetailV2

    关键返回字段（用于检测点位置判断）：
      - needCheckPoint:    课程是否需要检测点（课程级开关）
      - interactiveVideo:  该视频是否为互动视频（视频级配置）
      - videoPlayTime:     视频总时长（秒）
    """
    body = {
        "schoolId": SCHOOL_ID,
        "lessonId": lesson_id,
        "courseId": course_id,
        "homeworkId": homework_id,
        "videoType": VIDEO_TYPE,
    }
    _print_send("POST", LESSON_DETAIL_URL, body)
    resp = requests.post(LESSON_DETAIL_URL, headers=_gateway_headers(),
                         json=body, timeout=timeout)
    return _print_resp(resp)


def get_videodp(timeout: int = 15):
    """
    GET /api/homeworkprod/homework/student/getVideodp?schoolId=

    【重要】查询当前用户是否在黑名单中（不是"检测点全局开关"）。

    源码逻辑（homework-play-video.js 的 Context Provider）：
      let {data: e} = await getVideodp();
      setIsBlacklisted(!!e);   // data:true → isBlacklisted=true → 走滑块型(ek 组件)

    返回 data:bool：
      true  = 用户在黑名单中，到达检测点时渲染 ek 组件（滑块型）
      false = 普通用户，到达检测点时渲染 ev 组件（普通确认型）

    实测当前用户：data=true（已在黑名单）
    """
    params = {"schoolId": SCHOOL_ID}
    _print_send("GET", VIDEODP_URL + f"?schoolId={SCHOOL_ID}")
    resp = requests.get(VIDEODP_URL, params=params, headers=_gateway_headers(),
                        timeout=timeout)
    return _print_resp(resp)


def check_blacklist_status(timeout: int = 15):
    """
    查询当前用户是否在黑名单中（基于 getVideodp 接口）。

    返回:
      (is_blacklisted: bool, raw_resp: dict)

    源码：isBlacklisted = !!getVideodp().data
    """
    resp = get_videodp(timeout=timeout)
    data = resp.get("data")
    is_blacklisted = bool(data)
    print(f"  [黑名单状态] isBlacklisted={is_blacklisted} (data={data!r})")
    if is_blacklisted:
        print(f"  [结论] 当前用户在黑名单中，到达检测点会走滑块型(ek 组件)")
    else:
        print(f"  [结论] 当前用户不在黑名单中，到达检测点会走普通确认型(ev 组件)")
    return is_blacklisted, resp


def add_studp(event: dict = None, timeout: int = 15):
    """
    GET /api/homeworkprod/homework/student/addStudp

    上报黑名单事件到服务端（反自动化检测命中时调用）。

    源码逻辑（homework-play-video.js 的 updateIsBlacklisted）：
      let a = async function(e) {
        await p.WY({url: "/api/homeworkprod/homework/student/addStudp",
                    method: "GET", params: {}});  // ← 事件详情 e 未作为参数传递！
        A.ZP.warn(e, A.vY.student_watch_class_anticheat);  // 阿里云日志上报详情
      };

    注意：
      1. 接口 method 是 GET（虽然语义上是上报）
      2. 事件详情（type/desc/message/lessonId/homeworkId/url）未通过接口参数传递，
         而是通过阿里云日志（aliLogJs 的 A.ZP.warn）上报
      3. 接口仅通知服务端"有黑名单事件"，服务端持久化黑名单记录

    事件结构示例：
      {
        "type": "UNTRUSTED_EVENT",
        "desc": "【学生看课使用插件】认真度检测-Fiber直调toCheck",
        "message": "检测到对toCheck方法的直接调用（Fiber遍历），疑似脚本操作",
        "lessonId": "117890",
        "homeworkId": "10495544",
        "url": "https://teacher.ewt360.com/..."
      }
    """
    # 事件详情仅打印，不传给接口（与源码一致）
    if event:
        print(f"  [事件详情] (仅阿里云日志上报，不传接口)")
        for k, v in event.items():
            print(f"    {k}: {v}")
    _print_send("GET", ADD_STUDP_URL)
    resp = requests.get(ADD_STUDP_URL, params={}, headers=_gateway_headers(),
                        timeout=timeout)
    return _print_resp(resp)


def get_serious_check_downgrade_config(timeout: int = 15):
    """
    GET /api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig?schoolId=&videoType=

    返回认真度检测降级配置：
      - level=0: 正常检测
      - level>0: 降级（高峰期关闭检测，提示"当前为使用高峰期，课程视频监测功能暂不可用"）
    """
    params = {"schoolId": SCHOOL_ID, "videoType": VIDEO_TYPE}
    _print_send("GET", SERIOUS_CHECK_DOWNGRADE_URL
                + f"?schoolId={SCHOOL_ID}&videoType={VIDEO_TYPE}")
    resp = requests.get(SERIOUS_CHECK_DOWNGRADE_URL, params=params,
                        headers=_gateway_headers(), timeout=timeout)
    return _print_resp(resp)


def get_cab(lesson_id: str = LESSON_ID, homework_id: int = 10495544,
            timeout: int = 15):
    """
    GET /api/homeworkprod/homework/student/cab?schoolId=&lessonId=&homeworkId=

    返回 data:bool，用途未确认（疑似检测点相关布尔开关）。
    """
    params = {"schoolId": SCHOOL_ID, "lessonId": lesson_id, "homeworkId": homework_id}
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    _print_send("GET", CAB_URL + "?" + qs)
    resp = requests.get(CAB_URL, params=params, headers=_gateway_headers(),
                        timeout=timeout)
    return _print_resp(resp)


def demo_detection_point_apis():
    """
    演示检测点位置相关接口的调用与响应解析。
    这些接口决定了：
      1. 当前课程是否需要检测点（needCheckPoint）
      2. 当前视频是否配置了互动题（interactiveVideo）
      3. 认真度检测是否被降级（level）
    """
    print("=" * 60)
    print("检测点位置与认真度降级接口测试")
    print("=" * 60)

    # 1) getLessonDetailV2
    print("\n[1] getLessonDetailV2 - 课程详情（含检测点开关）")
    lesson = get_lesson_detail()
    data = lesson.get("data") or {}
    print(f"    needCheckPoint    = {data.get('needCheckPoint')}")
    print(f"    interactiveVideo  = {data.get('interactiveVideo')}")
    print(f"    videoPlayTime     = {data.get('videoPlayTime')}")
    print(f"    lessonName        = {data.get('lessonName')}")

    # 2) getVideodp
    print("\n[2] getVideodp - 视频检测点全局开关")
    dp = get_videodp()
    print(f"    data = {dp.get('data')}  (True=启用检测点功能)")

    # 3) getSeriousCheckDownGradeConfig
    print("\n[3] getSeriousCheckDownGradeConfig - 认真度检测降级配置")
    dg = get_serious_check_downgrade_config()
    dg_data = dg.get("data") or {}
    level = dg_data.get("level")
    print(f"    level   = {level}  (0=正常, >0=降级)")
    print(f"    tips    = {dg_data.get('tips')}")
    print(f"    desc    = {dg_data.get('description')}")

    # 4) cab
    print("\n[4] cab - 疑似检测点相关布尔开关")
    cab = get_cab()
    print(f"    data = {cab.get('data')}")

    # 综合判断
    print("\n[综合判断]")
    need_cp = data.get("needCheckPoint")
    is_interactive = data.get("interactiveVideo")
    if level and level > 0:
        print(f"    → 认真度检测已降级（level={level}），所有检测暂不可用")
    elif need_cp and is_interactive:
        print(f"    → 课程需要检测点，且当前视频配置了互动题，将弹出答题型检测")
    elif need_cp and not is_interactive:
        print(f"    → 课程需要检测点，但当前视频无互动题配置，仅靠确认型(699001)检测")
    else:
        print(f"    → 课程不需要检测点")


# ============================================================
# 六'、滑块型（ecaptcha）API 调用与完整流程模拟
# ============================================================
def _ecaptcha_check_sign(biz_code: str, mobile: str, device_token: str,
                         token: str, timestamp: int) -> str:
    """
    复刻 5564.js 中的 checkSign 签名算法：
      md5(bizCode + mobile + deviceToken + token + timestamp + SECRET)

    说明：mobile/deviceToken/token 在视频场景下均为空字符串，
         实际签名 = md5(bizCode + "" + "" + "" + timestamp + SECRET)
    """
    raw = (biz_code + mobile + device_token + token
           + str(timestamp) + ECAPTCHA_SECRET)
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def _filegateway_headers(content_type_json: bool = True):
    """ecaptcha 走 filegateway 域名，请求头与 gateway 略有差异（无 token 必填项）"""
    h = {
        "Accept": "application/json, text/plain, */*",
        "Origin": "https://teacher.ewt360.com",
        "Referer": REFER_URL,
        "User-Agent": BROWSER_VER,
    }
    if content_type_json:
        h["Content-Type"] = "application/json"
    return h


def get_captcha_img(biz_code: str = ECAPTCHA_BIZ_CODE,
                    captcha_type: str = ECAPTCHA_TYPE,
                    mobile: str = "", device_token: str = "",
                    token: str = "", timestamp: int = None,
                    timeout: int = 15):
    """
    POST https://filegateway.ewt360.com/api/captcha/captcha/get

    获取滑块验证码图片。请求体含 checkSign 签名。

    Body:
      bizCode      : 业务码 "mst1784513466143"
      type         : "2" 滑块
      mobile       : 用户手机号（视频场景空）
      deviceToken  : 设备令牌（视频场景空）
      token        : 用户 token（视频场景空）
      timestamp    : 当前时间戳（毫秒）
      checkSign    : md5(bizCode+mobile+deviceToken+token+timestamp+SECRET)

    返回 data 结构:
      {
        "captchaSessionId": "session_xxx",
        "captchaImgBase64": "data:image/png;base64,...",   # 背景图 + 滑块拼图
        "captchaToken": ""                                  # 白名单时直接返回 token
      }
    """
    ts = timestamp if timestamp is not None else int(time.time() * 1000)
    sign = _ecaptcha_check_sign(biz_code, mobile, device_token, token, ts)
    body = {
        "bizCode": biz_code,
        "type": captcha_type,
        "mobile": mobile,
        "deviceToken": device_token,
        "token": token,
        "timestamp": ts,
        "checkSign": sign,
    }
    _print_send("POST", CAPTCHA_GET_URL, body)
    resp = requests.post(CAPTCHA_GET_URL, headers=_filegateway_headers(),
                         json=body, timeout=timeout)
    return _print_resp(resp)


def verify_captcha(captcha_session_id: str, marks: list,
                   biz_code: str = ECAPTCHA_BIZ_CODE,
                   captcha_type: str = ECAPTCHA_TYPE, timeout: int = 15):
    """
    POST https://filegateway.ewt360.com/api/captcha/captcha/verify

    验证用户拖动轨迹。marks 为用户拖动轨迹点列表 [{x,y,t}, ...]，
    SDK 内部会 JSON.stringify 后作为 verifyData 发送。

    Body:
      bizCode          : 业务码
      type             : "2" 滑块
      captchaSessionId : get 接口返回的会话 ID
      verifyData       : JSON.stringify(marks)，如 '[{"x":1,"y":2,"t":0},...]'

    返回 data 结构:
      {
        "verifyResult": true,
        "captchaToken": "token_xxx"   # 验证成功时返回
      }
    """
    body = {
        "bizCode": biz_code,
        "type": captcha_type,
        "captchaSessionId": captcha_session_id,
        "verifyData": json.dumps(marks, ensure_ascii=False, separators=(",", ":")),
    }
    _print_send("POST", CAPTCHA_VERIFY_URL, body)
    resp = requests.post(CAPTCHA_VERIFY_URL, headers=_filegateway_headers(),
                         json=body, timeout=timeout)
    return _print_resp(resp)


def report_add_videocss(homework_id: int, lesson_id: str,
                        serious_check_result: int,
                        css_type: int = AddVideoCssTypeEnum.NORMAL,
                        interactive_point_id=100,
                        captcha_token: str = None, platform: int = 1,
                        timeout: int = 15):
    """
    POST https://gateway.ewt360.com/api/homeworkprod/homework/student/addVideocss

    上报认真度检测结果。注意：addVideocss ≠ "添加视频CSS"，
    而是"添加视频检测点(video check point)"的拼音缩写。

    Body:
      homeworkId          : 作业 ID
      lessonId            : 课程 ID（11 年级需 Number(lessonId) + 2e6）
      type                : 1=普通视频(contentType=1), 2=其他非互动(contentType≠1), 3=互动视频
                            源码：interactiveVideo ? 3 : (contentType===1 ? 1 : 2)
      interactivePointId  : interactiveVideo?100:null（不是固定 100！）
                            源码：interactivePointId: interactiveVideo ? 100 : null
      platform            : 1
      seriousCheckResult  : 0=initLog, 1=errorLog, 2=successLog
      captchaToken        : 仅 successLog 时携带

    返回 gateway 统一格式：
      { "success": bool, "code": "0"/"200", "msg": "", "data": null }
    """
    body = {
        "homeworkId": homework_id,
        "lessonId": lesson_id,
        "type": css_type,
        "interactivePointId": interactive_point_id,
        "platform": platform,
        "seriousCheckResult": serious_check_result,
    }
    # 仅 successLog 时携带 captchaToken（与源码一致）
    if serious_check_result == SeriousCheckResultEnum.SUCCESS_LOG:
        body["captchaToken"] = captcha_token or ""
    _print_send("POST", ADD_VIDEOCSS_URL, body)
    resp = requests.post(ADD_VIDEOCSS_URL, headers=_gateway_headers(),
                         json=body, timeout=timeout)
    return _print_resp(resp)


def _gen_fake_drag_marks(distance: int = 120, steps: int = 30) -> list:
    """
    生成一份"看起来像人手拖动"的轨迹点列表（仅供 verify_captcha 接口演示）。

    真实 ecaptcha SDK 会捕获 mousedown/mousemove/mouseup 事件，
    记录每个点的 {x, y, t}。这里用匀加速+抖动模拟，无法通过服务端行为分析，
    实际测试预计返回 verifyResult=false（符合预期，仅演示 API 调用）。

    注意：业务层 _nativeClickHandler 会检测 event.isTrusted=false 的模拟点击，
    但此处只演示 verify 接口的 HTTP 调用，不涉及前端事件，不触发该检测。
    """
    marks = []
    start_ts = int(time.time() * 1000)
    # 匀加速模型：v = a*t, x = 0.5*a*t^2
    for i in range(steps):
        t = i / (steps - 1)
        # 加入轻微抖动
        x = int(distance * (0.5 * t * (1 + t)))
        y = int((i % 3) - 1)  # y 方向 ±1 像素抖动
        ts = start_ts + i * 16  # ~60fps
        marks.append({"x": x, "y": y, "t": ts})
    # 末尾加一个松开点
    marks.append({"x": distance, "y": 0, "t": start_ts + steps * 16})
    return marks


def simulate_slider_flow(homework_id: int = 10495544,
                         lesson_id: str = LESSON_ID,
                         interactive_video: bool = False,
                         content_type: int = 1):
    """
    模拟业务层 homework-play-video.js 中 ek 组件（滑块型）的完整流程：

    触发前提（缺一不可）：
      a. 用户已被加入黑名单（isBlacklisted=true）
         触发方式：Fiber 直调 toCheck / 模拟点击 event.isTrusted=false
      b. 播放时间到达 videoCheckPoint 检测点（客户端生成的时间点数组）
         → earnestCheckVisible=true
      c. renderEarnestCheck 根据 isBlacklisted=true 渲染 ek 组件

    ek.componentDidMount 流程：
      1. 上报 initLog（seriousCheckResult=0）
      2. 暂停播放器
      3. 初始化 ecaptcha → POST captcha/get 获取滑块图
      4. 用户拖动滑块 → POST captcha/verify 验证轨迹
         ├─ 成功 → 返回 captchaToken
         │   ↓
         │ 5. 上报 successLog（seriousCheckResult=2 + captchaToken）
         │   ↓
         │ 6. "你真棒，通过检测～" → 继续播放
         └─ 失败 → 上报 errorLog（seriousCheckResult=1） → 重新加载
      7. 30s 倒计时未完成 → 上报 errorLog → "你错过了检测"

    参数:
      interactive_video : 是否互动视频（影响 type 和 interactivePointId）
      content_type      : contentType（1=普通, 11=校长寄语, 其他）
                          源码：type = interactiveVideo ? 3 : (contentType===1 ? 1 : 2)
                          源码：interactivePointId = interactiveVideo ? 100 : null

    注意：本测试默认真实发起网络请求（无 DRY_RUN），
          由于 _gen_fake_drag_marks 生成的轨迹无法通过服务端行为分析，
          预期 verifyResult=false，仅用于演示接口调用流程。
    """
    # 根据源码逻辑计算 type 和 interactivePointId
    css_type = calc_add_videocss_type(interactive_video, content_type)
    interactive_point_id = calc_interactive_point_id(interactive_video)

    print("=" * 60)
    print("滑块型认真度检测（ecaptcha, ek 组件）- 完整流程模拟")
    print("=" * 60)
    print(f"  [参数] interactive_video={interactive_video}, content_type={content_type}")
    print(f"  [计算] type={css_type}, interactivePointId={interactive_point_id}")
    print(f"  [前提] isBlacklisted=true（用户已被反自动化检测拉黑）")
    print(f"  [前提] 播放时间已到达 videoCheckPoint 检测点")

    # 步骤1：ek 组件挂载，触发检测
    print(f"\n  [步骤1] ek 组件 componentDidMount → 暂停播放器，弹出检测弹窗")
    print(f"          UI: spc_video_earnest_check_box")
    print(f"          提示: '近期看课操作异常，请您完成下方检测。'")
    print(f"          倒计时: 30s")

    # 步骤2：initLog 上报
    print(f"\n  [步骤2] 上报 initLog（seriousCheckResult=0）")
    init_resp = report_add_videocss(
        homework_id=homework_id, lesson_id=lesson_id,
        serious_check_result=SeriousCheckResultEnum.INIT_LOG,
        css_type=css_type,
        interactive_point_id=interactive_point_id,
    )
    print(f"          initLog resp: success={init_resp.get('success')} "
          f"code={init_resp.get('code')}")

    # 步骤3：初始化 ecaptcha，获取滑块图
    print(f"\n  [步骤3] 初始化 ecaptcha → POST captcha/get 获取滑块图")
    captcha_resp = get_captcha_img()
    captcha_data = captcha_resp.get("data") or {}
    session_id = captcha_data.get("captchaSessionId", "")
    direct_token = captcha_data.get("captchaToken", "")
    img_b64 = captcha_data.get("captchaImgBase64", "")

    print(f"          captchaSessionId: {session_id}")
    print(f"          captchaImgBase64: {img_b64[:50] + '...' if img_b64 else '(空)'}")
    print(f"          captchaToken(直发): {direct_token or '(空，需要验证)'}")

    # 白名单用户可能直接拿到 token，跳过验证
    if direct_token:
        print(f"\n  [白名单] 服务端直接下发 captchaToken，跳过滑块验证")
        token = direct_token
    else:
        # 步骤4：模拟用户拖动并验证
        print(f"\n  [步骤4] 模拟用户拖动滑块 → POST captcha/verify")
        marks = _gen_fake_drag_marks(distance=120, steps=30)
        print(f"          verifyData: {len(marks)} 个轨迹点")
        verify_resp = verify_captcha(session_id, marks)
        verify_data = verify_resp.get("data") or {}
        verify_result = verify_data.get("verifyResult", False)
        token = verify_data.get("captchaToken", "")
        print(f"          verifyResult: {verify_result}")
        print(f"          captchaToken: {token or '(空)'}")

        if not verify_result:
            # 验证失败 → 上报 errorLog
            print(f"\n  [验证失败] '验证失败，请按提示重新操作～'")
            print(f"          业务行为: 重新加载滑块图，用户重试")
            print(f"\n  [步骤5'] 上报 errorLog（验证失败）")
            err_resp = report_add_videocss(
                homework_id=homework_id, lesson_id=lesson_id,
                serious_check_result=SeriousCheckResultEnum.ERROR_LOG,
                css_type=css_type,
                interactive_point_id=interactive_point_id,
            )
            print(f"          errorLog resp: success={err_resp.get('success')}")
            print(f"\n  [说明] 由于模拟轨迹无法通过服务端行为分析，本次流程在验证失败处终止。")
            print(f"          真实用户拖动会通过验证，进入 successLog 上报。")
            return verify_resp

    # 步骤5：成功上报 successLog
    print(f"\n  [步骤5] 上报 successLog（携带 captchaToken）")
    success_resp = report_add_videocss(
        homework_id=homework_id, lesson_id=lesson_id,
        serious_check_result=SeriousCheckResultEnum.SUCCESS_LOG,
        css_type=css_type,
        interactive_point_id=interactive_point_id,
        captcha_token=token,
    )
    print(f"          successLog resp: success={success_resp.get('success')}")

    # 步骤6：通过提示
    print(f"\n  [步骤6] message.success('你真棒，通过检测～')")
    print(f"          player.play() 继续播放")
    return success_resp


def demo_anti_automation_detection():
    """
    演示业务层反自动化脚本检测机制（来自 homework-play-video.js）。

    【重要】反自动化检测是滑块型（ek 组件）的触发前提！
    一旦命中以下任一检测，会调用 updateIsBlacklisted 将 isBlacklisted 置为 true，
    之后用户到达检测点时将渲染 ek 组件（滑块型）而非 ev 组件（普通确认型）。

    1. Fiber 遍历直调 toCheck 检测：
       this.toCheck = () => {
         if (!em) {
           em = true;
           this.context.updateIsBlacklisted({
             type: "UNTRUSTED_EVENT",
             desc: "【学生看课使用插件】认真度检测-Fiber直调toCheck",
             message: "检测到对toCheck方法的直接调用（Fiber遍历），疑似脚本操作",
             ...
           });
         }
       };

    2. 模拟点击检测（event.isTrusted=false）：
       this._nativeClickHandler = async e => {
         if (!e.isTrusted || !(e instanceof MouseEvent)) {
           this.context.updateIsBlacklisted({
             type: "UNTRUSTED_EVENT",
             desc: "【学生看课使用插件】认真度检测-模拟点击通过",
             message: "检测到对认真度检测的模拟点击，event.isTrusted=false",
             ...
           });
           e.preventDefault();
           e.stopPropagation();
           e.stopImmediatePropagation();
           return;
         }
         // 真实点击 → 正常流程
       };

    3. 播放列表点击检测：同样基于 event.isTrusted

    黑名单状态流转：
      isBlacklisted=false（普通用户）→ ev 组件（点击"我知道了"即可）
                ↓ 命中反自动化检测
      isBlacklisted=true（黑名单用户）→ ek 组件（必须拖滑块验证）

    说明：这些检测在前端事件层完成，无法通过 HTTP 接口模拟。
          updateIsBlacklisted 还会调用 /api/homeworkprod/homework/student/addStudp 上报黑名单事件。
    """
    print("=" * 60)
    print("反自动化脚本检测（业务层 homework-play-video.js）")
    print("=" * 60)
    print("  【重要】反自动化检测是滑块型(ek)的触发前提！")
    print("  命中后 isBlacklisted=true，后续检测点都走滑块型")
    print()
    print("  检测项 1: Fiber 遍历直调 toCheck 方法")
    print("    触发: 脚本通过 React Fiber 树找到组件实例，直接调用 .toCheck()")
    print("    行为: updateIsBlacklisted({type:'UNTRUSTED_EVENT', ...})")
    print()
    print("  检测项 2: 模拟点击（event.isTrusted=false）")
    print("    触发: 脚本通过 element.click() 或 dispatchEvent 触发点击")
    print("    行为: preventDefault + stopPropagation + updateIsBlacklisted")
    print()
    print("  检测项 3: 播放列表 lesson-item 模拟点击")
    print("    触发: 脚本模拟点击课程列表切换讲次")
    print("    行为: 同上，加入黑名单")
    print()
    print("  [状态流转]")
    print("    isBlacklisted=false → ev 组件（普通确认型，点击'我知道了'）")
    print("    isBlacklisted=true  → ek 组件（滑块型，必须拖滑块验证）")
    print()
    print("  [黑名单服务端持久化]")
    print("    1. getVideodp 接口：查询用户是否在黑名单（data:true=在黑名单）")
    print("       每次初始化/切换视频时调用，结果直接赋给 isBlacklisted")
    print("    2. addStudp 接口：反自动化检测命中时调用，通知服务端加入黑名单")
    print("       事件详情通过阿里云日志(aliLogJs)上报，不通过接口参数")
    print("    3. 黑名单状态保存在服务端，非纯前端 state")
    print("    4. 实测当前用户(USER_ID=160000000)已在黑名单中(data:true)")
    print()
    print("  [结论] 这些检测在前端事件层完成，纯 HTTP 调用无法绕过。")
    print("        updateIsBlacklisted 调用 addStudp 接口上报，服务端持久化。")


# ============================================================
# 七、被动防作弊机制演示（服务器时间同步）
# ============================================================
def demo_server_time_sync():
    """
    演示 checkDiffTime 机制：
      每次上报响应的 data.ts 用于校准 _diffTime，
      report_time = 本地时间 + _diffTime，确保使用服务器同步时间，
      防止篡改本地时间作弊。

    偏差超过 10 秒会记录 warn 日志（type=diff_10）。
    """
    print("=" * 60)
    print("被动防作弊 - 服务器时间同步演示")
    print("=" * 60)
    clock = ServerClock()
    local_before = int(time.time() * 1000)
    # 模拟服务器返回的 ts（比本地快 5 秒）
    server_ts = local_before + 5000
    clock.sync(server_ts)
    local_after = int(time.time() * 1000)
    print(f"  本地时间戳:  {local_before}")
    print(f"  服务器 ts:   {server_ts} (比本地快 5000ms)")
    print(f"  diff_ms:     {clock.diff_ms}")
    print(f"  校准后 now:  {clock.now()}")
    print(f"  偏差检查:    {abs(clock.diff_ms)}ms {'< 10000 正常' if abs(clock.diff_ms) < 10000 else '>= 10000 触发 warn 日志'}")


# ============================================================
# 八、主入口
# ============================================================
def main():
    print("#" * 60)
    print("# mstplayer-v3.0.37 + 业务层 认真度检测接口调用测试")
    print("# 当前视频 lessonId={} (interactiveInfo 为空，仅演示 API 调用)".format(LESSON_ID))
    print("#" * 60)

    # 0) 检测点位置与认真度降级接口测试
    demo_detection_point_apis()

    # 0.5) 黑名单状态查询（决定走滑块型还是普通型）
    print()
    print("=" * 60)
    print("黑名单状态查询（getVideodp）- 决定渲染 ev 还是 ek 组件")
    print("=" * 60)
    check_blacklist_status()

    # 1) 互动型：完整答题流程模拟（使用 mock ID，服务端会返回错误）
    print()
    simulate_interactive_flow(mock_config_id="1")

    # 2) 确认型：699001 错误响应处理模拟（纯本地，不发网络请求）
    print()
    simulate_confirm_modal_flow()

    # 3) 滑块型（ecaptcha, ek 组件）：完整流程模拟（真实发起网络请求）
    #    默认参数：interactive_video=False, content_type=1
    #    → type=1 (普通视频), interactivePointId=null (非互动视频)
    print()
    simulate_slider_flow(interactive_video=False, content_type=1)

    # 4) 反自动化脚本检测演示（纯本地，说明业务层防作弊机制）
    print()
    demo_anti_automation_detection()

    # 5) 被动防作弊：服务器时间同步演示
    print()
    demo_server_time_sync()

    print()
    print("#" * 60)
    print("# 测试完成")
    print("#")
    print("# 说明:")
    print("#   - 检测点位置: 互动题位置(interactiveTimePoint)由服务端下发；")
    print("#                认真度检测点(videoCheckPoint)由客户端基于视频时长计算")
    print("#   - 互动型:     当前视频未配置互动题，使用 mock ID 演示 API 调用与流程")
    print("#                如需真实测试，请从有互动题的视频中获取真实 configId")
    print("#   - 确认型:     699001 由服务端判定返回，无法主动触发，本文件用 mock 演示")
    print("#   - 反调试型:   antiDebug 默认 false，当前未启用（AliAdapter 配置）")
    print("#   - 滑块型:     业务层 ek 组件（isBlacklisted=true 时渲染）+ ecaptcha SDK")
    print("#                触发前提: 反自动化检测命中 → addStudp 上报 → 服务端加黑")
    print("#                → getVideodp 返回 data:true → isBlacklisted=true → 到达检测点")
    print("#                type = interactiveVideo?3:(contentType===1?1:2)")
    print("#                interactivePointId = interactiveVideo?100:null (不是固定100)")
    print("#   - 黑名单:     服务端持久化，getVideodp 查询，addStudp 上报")
    print("#                当前用户实测已在黑名单中(data:true)")
    print("#   - 反自动化:   业务层检测 event.isTrusted / Fiber 遍历，是滑块型的触发前提")
    print("#" * 60)


if __name__ == "__main__":
    main()
