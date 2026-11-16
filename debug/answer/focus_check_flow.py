# -*- coding: utf-8 -*-
"""
认真度检测 (focus check) 通过过程与逻辑 —— Python 伪代码

来源对齐 (Dart 实现):
  - ewt_auto_client/lib/features/player/domain/services/playback_engine.dart
        _performFocusCheck / _sendVideoCheck / _solveFocusCaptchaProactively /
        _resolveFocusInteractivePointId / _generateVideoCheckPoints
  - ewt_auto_client/lib/features/player/domain/entities/serious_check_config.dart
  - ewt_auto_client/lib/features/player/data/datasources/player_remote_datasource.dart
        addVideoss / addVideocss / getSeriousCheckDownGradeConfig / getVideodp
  - ewt_auto_client/lib/core/captcha/captcha_service.dart (滑块求解)
  - ewt_auto_client/lib/core/captcha/captcha_net.dart (滑块网络层)
  - ewt_auto_client/lib/core/constants/api_constants.dart

文档对齐:
  - debug/player_behavior/mstplayer_seriousness_check_doc.md (§2.0.5 / §3'.1 / §3'.6 / §3'.7 / §6)

整体链路 (心跳循环内, 每个检测点触发一次):
  1. 播放时间到达 videoCheckPoint 检测点
  2. 降级判断 (level>0 → 仅日志, 直接返回)
  3. 解析 interactivePointId + 计算 type
  4. act=3 暂停 (collect 上报)
  5. 首报 addVideoss/addVideocss (seriousCheckResult=0, 无 token)
  6. 主动解算滑块 (仅黑名单用户) → captchaToken
  7. 模拟用户点击等待 (~2s 快刷 / ~5s 常规)
  8. 二次上报 addVideoss/addVideocss (seriousCheckResult=2, 黑名单携带 captchaToken)
  9. act=2 恢复 + playbackProgress 持久化 → 继续播放

说明: 本文件为伪代码, 仅描述流程与判断条件, 不真实发起网络请求。
"""

from dataclasses import dataclass
from typing import List, Optional


# ============================================================
# 一、枚举与配置
# ============================================================

class SeriousCheckResultEnum:
    """addVideoss/addVideocss 上报中 seriousCheckResult 字段枚举"""
    INIT_LOG = 0      # 检测弹窗显示时 (首报, 无 token)
    ERROR_LOG = 1     # 检测失败/错过时 (倒计时超时)
    SUCCESS_LOG = 2   # 检测通过时 (二次上报, 黑名单携带 captchaToken)


class CollectActionEnum:
    """collect 上报 action 枚举 (播放行为埋点)"""
    START = 1         # 开始播放
    PLAYING = 2       # 播放中 / 恢复
    PAUSE = 3         # 暂停 (检测点触发时)
    END = 4           # 结束


@dataclass
class SeriousCheckConfig:
    """认真度检测降级配置 (对应 serious_check_config.dart)

    来源: GET /api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig
        ?schoolId=&videoType=
    响应 data: {key, level, tips, needLog, description}
    """
    level: int = 1           # 0=正常检测, >0=降级 (接口失败默认 1, 安全 fallback)
    tips: str = ""           # 降级提示文案
    need_log: int = 0        # 是否记录日志 (1=记录, 与降级判断无关)
    description: str = ""

    @property
    def is_downgrade(self) -> bool:
        """降级模式: 仅记录日志, 不执行 act=3 暂停 / 滑块 / addVideoss 打断"""
        return self.level > 0

    @property
    def is_enabled(self) -> bool:
        """认真度检测功能是否可用 (执行完整流程)"""
        return not self.is_downgrade


@dataclass
class InteractiveConfig:
    """互动题配置 (来自 getExternalVideoInfo)"""
    id: str                       # interactiveConfigId
    time_point_ms: int           # interactiveTimePoint (毫秒)


@dataclass
class VideoSession:
    """视频会话上下文"""
    school_id: str
    homework_id: str
    lesson_id: str
    duration: float               # 视频时长 (秒)
    content_type: int            # 1=普通视频, 其他=非互动 (如 11 校本视频)
    interactive_configs: List[InteractiveConfig]  # 互动题配置, 空表示无互动题
    # ... 其余字段省略


# ============================================================
# 二、API 端点 (伪, 仅展示 URL 与请求体结构)
# ============================================================

GATEWAY_HOST = "https://gateway.ewt360.com"
FILEGATEWAY_HOST = "https://filegateway.ewt360.com"   # ecaptcha 独立域名, 无需 EWT 签名

# 认真度检测相关
URL_GET_SERIOUS_DOWNGRADE = GATEWAY_HOST + "/api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig"
URL_GET_VIDEODP = GATEWAY_HOST + "/api/homeworkprod/homework/student/getVideodp"
URL_ADD_VIDEOSS = GATEWAY_HOST + "/api/homeworkprod/homework/student/addVideoss"   # 非黑名单 (ev 组件)
URL_ADD_VIDEOCSS = GATEWAY_HOST + "/api/homeworkprod/homework/student/addVideocss"  # 黑名单 (ek 组件)
URL_INTERACTIVE_DETAIL = GATEWAY_HOST + "/api/videoplayerprod/videoplayer/getInteractiveConfigDetail"

# ecaptcha 滑块 (业务层)
URL_CAPTCHA_GET = FILEGATEWAY_HOST + "/api/captcha/captcha/get"
URL_CAPTCHA_VERIFY = FILEGATEWAY_HOST + "/api/captcha/captcha/verify"

CAPTCHA_BIZ_CODE = "mst"   # 视频检测业务码 (homework-play-video.js 硬编码)


# ============================================================
# 三、初始化阶段 (播放前一次性查询)
# ============================================================

def init_serious_check_context(session: VideoSession) -> dict:
    """播放前查询认真度检测降级配置 + 黑名单状态。

    对齐 playback_engine.dart 初始化段 (§getSeriousCheckDownGradeConfig / §getVideodp)。

    返回上下文 dict, 供心跳循环使用。
    """
    ctx = {
        "serious_config": SeriousCheckConfig(level=1),  # 默认降级 (安全 fallback)
        "is_blacklisted": False,                         # 默认普通用户
        "video_check_points": [],                        # 客户端生成的检测点时间数组 (秒)
    }

    # 1) 认真度检测降级配置 (失败非致命, 沿用默认降级)
    try:
        cfg_json = http_get(URL_GET_SERIOUS_DOWNGRADE,
                            params={"schoolId": session.school_id, "videoType": 1})
        data = cfg_json.get("data") or {}
        ctx["serious_config"] = SeriousCheckConfig(
            level=parse_int(data.get("level"), default=1),
            tips=data.get("tips", ""),
            need_log=parse_int(data.get("needLog"), default=0),
            description=data.get("description", ""),
        )
    except Exception as e:
        log(f"getSeriousCheckDownGradeConfig 失败(非致命): {e}")

    # 2) 黑名单状态 (决定走滑块型 ek 还是确认型 ev)
    #    data:true → 用户在黑名单 → 走滑块型 (ek 组件, ecaptcha)
    #    data:false → 普通用户 → 走确认型 (ev 组件, 仅点击"我知道了")
    try:
        dp_json = http_get(URL_GET_VIDEODP,
                           params={"schoolId": session.school_id, "lessonId": session.lesson_id})
        ctx["is_blacklisted"] = bool(dp_json.get("data"))
    except Exception as e:
        log(f"getVideodp 失败(非致命, 默认普通用户): {e}")

    # 3) 客户端生成 videoCheckPoint 检测点数组 (基于时长和互动点位置)
    ctx["video_check_points"] = generate_video_check_points(
        session.duration, session.interactive_configs
    )

    log(f"认真度检测: {('已降级' if ctx['serious_config'].is_downgrade else '正常')} "
        f"(level={ctx['serious_config'].level}, needLog={ctx['serious_config'].need_log})")
    log(f"黑名单状态: {('在黑名单 → 滑块型' if ctx['is_blacklisted'] else '普通用户 → 确认型')}")
    log(f"检测点: {ctx['video_check_points']}")
    return ctx


def generate_video_check_points(duration: float,
                                interactive_configs: List[InteractiveConfig]) -> List[int]:
    """客户端生成 videoCheckPoint 检测点数组 (秒)。

    对齐 playback_engine.dart _generateVideoCheckPoints / _mhRange:
      - 起始 ~121s
      - 结束 ~0.8 * duration
      - count 个均匀点 (count 由时长决定, 间距 ~60s)
      - 互动题时间点也并入检测点集合

    注: 真实生成算法见源码, 此处仅示意。
    """
    if duration <= 0:
        return []
    start = 121
    end = int(0.8 * duration)
    if end <= start:
        return []
    # 均匀生成 (间距 60s, 对齐 _mhRange step=60)
    points = list(range(start, end + 1, 60))
    # 并入互动题时间点 (毫秒 → 秒)
    for cfg in interactive_configs:
        t_sec = cfg.time_point_ms // 1000
        if start <= t_sec <= end and t_sec not in points:
            points.append(t_sec)
    points.sort()
    return points


# ============================================================
# 四、检测点触发判定 (心跳循环内)
# ============================================================

def check_focus_checkpoint_reached(played_seconds: float,
                                   last_played_seconds: float,
                                   check_points: List[int]) -> Optional[int]:
    """判断播放时间是否跨越了某个检测点。

    对齐浏览器 Interactive.startCheck 的"比较"逻辑 (不生成, 仅比较):
        if n > last_played_time and n <= current_time:
            trigger checkpoint n

    返回触发的检测点时间 (秒), 未触发返回 None。
    注意: 暂停时不检测 (调用方保证非暂停态)。
    """
    for cp in check_points:
        if cp > last_played_seconds and cp <= played_seconds:
            return cp
    return None


# ============================================================
# 五、认真度检测点完整时序 (核心)
# ============================================================

def perform_focus_check(session: VideoSession,
                        ctx: dict,
                        pti: int,
                        played_seconds: float,
                        cp_index: int,
                        cp_total: int,
                        check_point_time: Optional[int] = None,
                        fast_brush: bool = False) -> None:
    """认真度检测点完整时序 (对应 playback_engine.dart _performFocusCheck)。

    时序:
      act=3(pause) → 首报 addVideoss/addVideocss(0, 无token) +
      主动解算滑块(仅黑名单) → ~click_delay 用户点击 →
      二次上报(2, captchaToken) → act=2(恢复) → playbackProgress

    参数:
      pti:             当前播放时段索引 (collect 上报用)
      played_seconds:  当前播放位置 (秒, 日志显示用)
      cp_index/cp_total: 当前检测点序号 / 总数 (UI 显示 "已完成/全部")
      check_point_time: 客户端生成的检测点时间 (秒, 日志显示)
      fast_brush:      快刷模式 (压缩等待时间)
    """
    serious_cfg: SeriousCheckConfig = ctx["serious_config"]
    is_blacklisted: bool = ctx["is_blacklisted"]

    cp_time_str = f"{check_point_time}s" if check_point_time is not None else "?"
    log(f"认真度检测 {cp_index}/{cp_total} "
        f"(检测点={cp_time_str}, 当前={int(played_seconds)}s, "
        f"黑名单={'是→滑块' if is_blacklisted else '否→确认'})")

    # —— 降级模式: 仅记录日志, 不执行任何打断/滑块操作 ——
    # 对齐 §2.0.5: level>0 为降级, 播放器不弹窗, 仅后端记录日志。
    # 进度上报照常进行, 但不执行 act=3 暂停和滑块验证。
    if serious_cfg.is_downgrade:
        log(f"  认真度检测 {cp_index}/{cp_total} 已降级 (仅日志): {serious_cfg.tips}")
        return

    # —— 解析 interactivePointId (互动视频用真实 ID, 普通视频为 null) ——
    # 对齐 §3'.6: interactivePointId = interactiveVideo ? getInteractiveConfigDetail.id : null
    interactive_point_id = resolve_focus_interactive_point_id(session)

    # —— 计算 addVideoss.type ——
    # 对齐 §3'.6: type = interactiveVideo ? 3 : (contentType==1 ? 1 : 2)
    is_interactive = bool(session.interactive_configs)
    add_video_type = 3 if is_interactive else (1 if session.content_type == 1 else 2)
    log(f"  addVideoss 参数: type={add_video_type} "
        f"({'互动视频' if is_interactive else '普通视频' if session.content_type == 1 else '其他非互动'}), "
        f"interactivePointId={interactive_point_id or 'null'}")

    # —— act=3 检测点暂停 (collect 上报) ——
    send_collect(session, action=CollectActionEnum.PAUSE, stay_ms=0, pti=pti)

    # —— 首报: seriousCheckResult=0, 无 token ——
    # 非黑名单→addVideoss (ev 组件) / 黑名单→addVideocss (ek 组件)
    api_name_0 = "addVideocss" if is_blacklisted else "addVideoss"
    try:
        send_video_check(session,
                         serious_check_result=SeriousCheckResultEnum.INIT_LOG,
                         type=add_video_type,
                         interactive_point_id=interactive_point_id,
                         captcha_token=None,
                         is_blacklisted=is_blacklisted)
        log(f"  {api_name_0}(0) 首报 ok (type={add_video_type}, ipId={interactive_point_id})")
    except Exception as e:
        log(f"  {api_name_0}(0) 首报失败: {e}")

    # —— 主动解算滑块 (仅黑名单用户) ——
    # 对齐浏览器 ek 组件: componentDidMount 内主动挂载 ecaptcha,
    # 而非等待服务端下发 017129/017130 风险码再被动弹窗。
    # 普通用户 (ev 组件) 不解算滑块, 直接走二次上报。
    captcha_token: Optional[str] = None
    if is_blacklisted:
        try:
            captcha_token = solve_focus_captcha_proactively()
            if captcha_token:
                log(f"  主动解算滑块成功: captchaToken={captcha_token[:16]}...")
            else:
                log("  主动解算未拿到 token, 二次上报不带 captchaToken")
        except Exception as e:
            log(f"  主动解算滑块异常: {e}")
    else:
        log("  普通用户 (ev 组件), 跳过滑块解算, 直接二次上报")

    # —— 模拟用户点击通过 (~2s 快刷 / ~5s 常规) ——
    click_delay = 2 if fast_brush else 5
    sleep(click_delay)

    # —— 二次上报: seriousCheckResult=2, 仅黑名单用户携带 captchaToken ——
    report_token = captcha_token if is_blacklisted else None
    api_name_2 = "addVideocss" if is_blacklisted else "addVideoss"
    try:
        send_video_check(session,
                         serious_check_result=SeriousCheckResultEnum.SUCCESS_LOG,
                         type=add_video_type,
                         interactive_point_id=interactive_point_id,
                         captcha_token=report_token,
                         is_blacklisted=is_blacklisted)
        if report_token:
            log(f"  {api_name_2}(2) 二次上报 ok (黑名单用户, 携带 captchaToken)")
        else:
            log(f"  {api_name_2}(2) 二次上报 ok (无 captchaToken)")
    except Exception as e:
        log(f"  二次上报异常: {e}")

    # —— act=2 恢复 + 事件触发进度持久化 ——
    send_collect(session, action=CollectActionEnum.PLAYING, stay_ms=0, pti=pti)
    persist_progress(session)
    log("继续播放...")


# ============================================================
# 六、认真度检测 / 互动点上报统一入口
# ============================================================

def send_video_check(session: VideoSession,
                     serious_check_result: int,
                     type: int,
                     interactive_point_id: Optional[str],
                     captcha_token: Optional[str],
                     is_blacklisted: bool) -> None:
    """按黑名单状态自动选择接口 (对应 _sendVideoCheck)。

    对齐浏览器 homework-play-video chunk 的 ev/ek 组件分流:
      - 非黑名单 (ev 组件) → POST /student/addVideoss
      - 黑名单   (ek 组件) → POST /student/addVideocss

    两接口请求体参数完全一致, 仅 URL 不同:
      {schoolId, homeworkId, lessonId, type, interactivePointId,
       platform, seriousCheckResult, captchaToken?}
    """
    url = URL_ADD_VIDEOCSS if is_blacklisted else URL_ADD_VIDEOSS
    payload = {
        "schoolId": int(session.school_id),
        "homeworkId": int(session.homework_id),
        "lessonId": session.lesson_id,
        "type": type,
        "interactivePointId": interactive_point_id,   # 普通视频显式 null (与 HAR 一致)
        "platform": 1,
        "seriousCheckResult": serious_check_result,
    }
    # captchaToken 仅黑名单用户二次上报携带 (由调用方控制是否传入)
    if captcha_token:
        payload["captchaToken"] = captcha_token
    http_post(url, json=payload)


def resolve_focus_interactive_point_id(session: VideoSession) -> Optional[str]:
    """解析认真度检测点的 interactivePointId (对应 _resolveFocusInteractivePointId)。

    对齐 §3'.6:
      - 互动视频 (interactiveConfigs 非空): 取首个互动点的 getInteractiveConfigDetail.id
      - 普通视频: 返回 None (与 HAR 一致, addVideoss 显式发送 null)
    """
    if not session.interactive_configs:
        return None
    try:
        cfg_id = session.interactive_configs[0].id
        detail = http_get(URL_INTERACTIVE_DETAIL,
                          params={"interactiveConfigId": cfg_id})
        return detail.get("data", {}).get("id")
    except Exception:
        return None


# ============================================================
# 七、主动解算滑块 (仅黑名单用户)
# ============================================================

def solve_focus_captcha_proactively() -> Optional[str]:
    """主动求解认真度检测滑块, 返回 captchaToken 或 None。

    对应 playback_engine.dart _solveFocusCaptchaProactively +
    captcha_service.dart CaptchaService.solveAutomatically。
    """
    try:
        return solve_slide_captcha_smart()
    except Exception:
        return None


def solve_slide_captcha_smart() -> Optional[str]:
    """滑块验证完整自动求解流程 (对应 captcha_service.dart)。

    流程:
      1. GET 验证码 → 拿到背景图 / 滑块图 / pieceY / captchaSessionId
      2. 视觉预测缺口 x (locate_gap_rectified)
      3. 局部 verify 扫描 (pred_x ±12, step=3) → 命中后邻域细扫 (±2)
      4. 未命中则全图扫描兜底 (step=4)
    返回验证通过后的 captchaToken。
    """
    # 1) 获取验证码
    captcha = captcha_get()           # {sessionId, pieceY, backgroundImage, pieceImage, captchaToken}
    session_id = captcha["sessionId"]
    y = captcha["pieceY"]
    fallback_token = captcha.get("captchaToken", "")

    # 2) 视觉预测缺口 x
    pred_x = None
    try:
        pred_x = locate_gap_rectified(captcha["backgroundImage"], captcha["pieceImage"], y)
    except Exception:
        pass   # 视觉失败, 直接全图扫描

    # 3) 局部 verify 扫描 (pred_x ±12, step=3)
    if pred_x is not None:
        token = local_verify_scan(session_id, pred_x, y, half=12, step=3,
                                  fallback_token=fallback_token)
        if token:
            return token

    # 4) 全图扫描兜底 (step=4)
    token = full_verify_scan(session_id, y, step=4, fallback_token=fallback_token)
    if token:
        return token

    raise Exception("滑块验证自动求解失败")


def local_verify_scan(session_id: str, pred_x: int, y: int,
                      half: int, step: int, fallback_token: str) -> Optional[str]:
    """局部 verify 扫描 (对应 _localVerifyScan)。

    在 [pred_x - half, pred_x + half] 内以 step 步长扫描,
    命中后邻域细扫 (±radius=2) 确认最佳点。
    """
    lo = max(2, pred_x - half)
    hi = min(290, pred_x + half + 1)
    for x in range(lo, hi, step):
        result = captcha_verify(session_id, x, y)   # {success, captchaToken}
        if result["success"]:
            fine = fine_scan(session_id, x, y, radius=2)
            return fine or (result.get("captchaToken") or fallback_token)
    return None


def full_verify_scan(session_id: str, y: int, step: int,
                     fallback_token: str) -> Optional[str]:
    """全图 verify 扫描兜底 (对应 _fullVerifyScan)。

    粗扫 step=4, 命中后细扫。
    """
    for x in range(0, 290, step):
        result = captcha_verify(session_id, x, y)
        if result["success"]:
            fine = fine_scan(session_id, x, y, radius=2)
            return fine or (result.get("captchaToken") or fallback_token)
    return None


def fine_scan(session_id: str, hit_x: int, y: int, radius: int) -> Optional[str]:
    """命中后邻域细扫 (对应 _fineScan)。

    在 hit_x ± radius 内逐点 verify, 取非空 captchaToken 的最佳点。
    """
    best = None
    for dx in range(-radius, radius + 1):
        xx = hit_x + dx
        if xx < 0 or xx >= 290:
            continue
        result = captcha_verify(session_id, xx, y)
        if result["success"] and result.get("captchaToken"):
            best = result["captchaToken"]
    return best


# ============================================================
# 八、互动视频检测点变体 (互动题时间点触发)
# ============================================================

def perform_interactive_focus_check(session: VideoSession,
                                    ctx: dict,
                                    cfg: InteractiveConfig,
                                    pti: int) -> None:
    """互动视频检测点变体 (对应 playback_engine.dart 互动题处理段)。

    与普通检测点不同: 互动视频检测点会先提交互动题答案, 再上报认真度检测。
    时序:
      1. getInteractiveConfigDetail → 取题目
      2. submitAnswer (空答) → 拿到正确答案
      3. submitAnswer (正确答案)
      4. addVideoss/addVideocss: seriousCheckResult 0 → 2 (type=3, ipId=cfg.id)
    """
    is_blacklisted = ctx["is_blacklisted"]
    api_name = "addVideocss" if is_blacklisted else "addVideoss"

    # 1) 取互动题详情
    try:
        detail = http_get(URL_INTERACTIVE_DETAIL, params={"interactiveConfigId": cfg.id})
        scene_id = detail.get("data", {}).get("interactiveSceneId")
        question_id = detail.get("data", {}).get("questionId")
    except Exception as e:
        log(f"  互动题详情加载失败: {e}")
        return

    # 2) submitAnswer (空答) → 拿正确答案
    correct = None
    try:
        r0 = submit_answer(scene_id, question_id, my_answers=[""], lesson_id=session.lesson_id)
        answers = (r0.get("answers") or [])
        if answers:
            correct = answers[0]
    except Exception as e:
        log(f"  submitAnswer(空答) 失败: {e}")

    # 3) submitAnswer (正确答案)
    if correct:
        try:
            submit_answer(scene_id, question_id, my_answers=[correct], lesson_id=session.lesson_id)
            log("  submitAnswer(正确答案) ok")
        except Exception as e:
            log(f"  submitAnswer(正确答案) 失败: {e}")

    # 4) 认真度检测/互动点上报: seriousCheckResult 0 → 2 (type=3, ipId=cfg.id)
    try:
        send_video_check(session,
                         serious_check_result=SeriousCheckResultEnum.INIT_LOG,
                         type=3,
                         interactive_point_id=cfg.id,
                         captcha_token=None,
                         is_blacklisted=is_blacklisted)
        send_video_check(session,
                         serious_check_result=SeriousCheckResultEnum.SUCCESS_LOG,
                         type=3,
                         interactive_point_id=cfg.id,
                         captcha_token=None,
                         is_blacklisted=is_blacklisted)
        log(f"  {api_name}(0→2) 记录通过 ok (ipId={cfg.id})")
    except Exception as e:
        log(f"  {api_name} 失败: {e}")


# ============================================================
# 九、心跳循环主流程 (检测点触发的入口)
# ============================================================

def heartbeat_loop(session: VideoSession, ctx: dict, fast_brush: bool = False) -> None:
    """心跳循环主流程 (伪, 仅展示检测点触发判定与调用)。

    对齐 playback_engine.dart 心跳循环: 墙钟固定 60s/120s (不随 speed 缩短),
    每轮检查播放时间是否跨越检测点。
    """
    check_points: List[int] = ctx["video_check_points"]
    last_played = 0.0
    cp_done = 0
    cp_total = len(check_points)

    while not cancelled():
        # 模拟一轮心跳后的播放进度推进 (伪)
        played = advance_playback(session)

        # —— 认真度检测点判定 (暂停态不检测) ——
        if not is_paused():
            cp = check_focus_checkpoint_reached(played, last_played, check_points)
            if cp is not None:
                cp_done += 1
                perform_focus_check(
                    session, ctx,
                    pti=current_pti(session),
                    played_seconds=played,
                    cp_index=cp_done,
                    cp_total=cp_total,
                    check_point_time=cp,
                    fast_brush=fast_brush,
                )

        last_played = played
        sleep(60)   # 墙钟固定 60s/120s

        # 进度达标提前结束
        if played >= session.duration * 0.81:
            break


# ============================================================
# 十、底层伪实现 (仅占位, 表明调用点)
# ============================================================

def http_get(url, params=None): ...   # 伪: gateway 需 EWT 签名, ecaptcha 无需签名
def http_post(url, json=None): ...
def send_collect(session, action, stay_ms, pti): ...   # collect 播放行为埋点
def persist_progress(session): ...                      # playbackProgress 进度持久化
def locate_gap_rectified(bg_img, piece_img, y): ...     # 视觉预测缺口 x
def captcha_get(): ...                                  # POST /api/captcha/captcha/get
def captcha_verify(session_id, x, y): ...               # POST /api/captcha/captcha/verify
def submit_answer(scene_id, question_id, my_answers, lesson_id): ...
def advance_playback(session): ...                      # 推进播放进度, 返回当前秒
def current_pti(session): ...                           # 当前播放时段索引
def is_paused(): ...
def cancelled(): ...
def sleep(s): ...
def log(msg): ...
def parse_int(v, default=0): ...


# ============================================================
# 入口
# ============================================================

if __name__ == "__main__":
    session = VideoSession(
        school_id="10000",
        homework_id="10495544",
        lesson_id="117890",
        duration=763.0,
        content_type=1,
        interactive_configs=[],   # 当前视频无互动题 → 走普通检测点
    )
    ctx = init_serious_check_context(session)
    heartbeat_loop(session, ctx, fast_brush=False)
