# -*- coding: utf-8 -*-
"""
mstplayer-v3.0.37 看课埋点接口调用测试代码

依据 Edge DevTools 实测抓包 + 源码分析还原。包含：
  1. 签名算法 (HMAC-SHA1) 复现与自检
  2. 看课埋点上报 (collect/batch) 请求构造与发送
  3. 作业任务进度查询 (getUserHomeworkLessonTaskInfo)
  4. 完整心跳模拟流程 (播放 -> 60s 心跳 -> 暂停)

依赖：requests
安装：pip install requests
"""

import hmac
import hashlib
import json
import time
import uuid
from urllib.parse import urlencode

import requests


# ============================================================
# 一、运行时常量（实测抓取，见 mstplayer_behavior_doc.md 第 8 节）
# ============================================================
USER_ID = 160000000
TOKEN = "160000000-1-xxxxxxxxxxxxxxxx"                       # 即 mstid
SESSION_ID = "160000000_7d6c8388-c6b6-44db-93ca-e40b08324e26"  # x-bfe-session-id
CLIENT_IP = "117.189.108.122"
SCHOOL_ID = "10000"
MEMBER_PROVINCE_CODE = "520000"
VIDEO_BIZ_CODE = "1013"
LESSON_ID = "117890"
COURSE_ID = "48419"
VIDEO_TYPE = 1
INTERVAL_TIME = 60          # 心跳周期(秒)
SECRET = "5373c0e70a15c97150bbef12522b6b90"   # 签名密钥
SDK_VERSION = "3.0.37"
SN = "ewt_web_video_detail"
BROWSER_VER = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
               "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36 Edg/150.0.0.0")
RESOLUTION = "1707*1067"

# 域名
BFE_HOST = "https://bfe.ewt360.com"
GATEWAY_HOST = "https://gateway.ewt360.com"
COLLECT_URL = f"{BFE_HOST}/monitor/web/collect/batch"
TASK_INFO_URL = f"{GATEWAY_HOST}/api/homeworkprod/homework/student/getUserHomeworkLessonTaskInfo"
REFER_URL = ("https://teacher.ewt360.com/ewtbend/bend/index/index.html"
             "#/homework/play-videos?role=student&courseId=48419&lessonId=117890"
             "&videoType=1&homeworkId=10495544&onlyMustLearn=1&isNewPlayer=1"
             "&videoPoint=0&date=1785427200000")

# 状态枚举
FC_START, FC_PLAYING, FC_PAUSED, FC_END = 1, 2, 3, 4   # action
CLOG_WATCH, CLOG_PAUSED = 1, 3                           # status


# ============================================================
# 二、签名算法（对应源码 makeSecretKey）
# ============================================================
def make_secret_key(action: int, duration: int, mstid: str, timestamp: int,
                    secret: str = SECRET) -> str:
    """
    还原 JS:
      function makeSecretKey(e, t){
        let r="";
        Object.keys(e).sort().forEach((k,i)=> r += (i?"&":"") + k + "=" + e[k]);
        // HMAC-SHA1(t, r) -> HEX
      }
    e = {action, duration, mstid, timestamp, version, signatureMethod, signatureVersion}
    """
    params = {
        "action": action,
        "duration": duration,
        "mstid": mstid,
        "timestamp": timestamp,
        "version": "2022-08-02",
        "signatureMethod": "HMAC-SHA1",
        "signatureVersion": "1.0",
    }
    # 按 key 字典序排序后拼接 key=value&key=value
    sign_str = "&".join(f"{k}={params[k]}" for k in sorted(params.keys()))
    digest = hmac.new(secret.encode("utf-8"), sign_str.encode("utf-8"),
                      hashlib.sha1).hexdigest()
    return digest


def _self_test_signature():
    """用三组真实抓包样本自检签名实现是否正确"""
    cases = [
        # (action, duration, timestamp, expected_signature)
        (2, 0,     1785476038703, "afb3686fd2c2a9cec6912f4ab7aaa693a26ecac4"),
        (2, 17674, 1785476056371, "9ac0e2212ce88502769f1aaccd9f1bd2d1de524c"),
        (3, 0,     1785476056375, "f4aff5484f91f1e9af5932f07faef47012ccc2b0"),
    ]
    print("=" * 60)
    print("签名算法自检 (HMAC-SHA1)")
    print("=" * 60)
    all_ok = True
    for action, duration, ts, expected in cases:
        got = make_secret_key(action, duration, TOKEN, ts)
        ok = got == expected
        all_ok &= ok
        print(f"  action={action} duration={duration} ts={ts}")
        print(f"    expected={expected}")
        print(f"    got     ={got}")
        print(f"    {'✅ PASS' if ok else '❌ FAIL'}")
    print("-" * 60)
    print(f"签名自检: {'全部通过' if all_ok else '存在失败'}\n")
    return all_ok


# ============================================================
# 三、时间工具
# ============================================================
# _diffTime = 服务器时间戳 - performance.now() 基准
# 浏览器里 report_time = floor(performance.now()) + _diffTime
# Python 无 performance.now()，直接用服务器时间(校准后的毫秒时间戳)作为 report_time
class ServerClock:
    """服务器时间同步器：首次响应 data.ts 后校准本地与服务器时差"""
    def __init__(self):
        self.diff_ms = 0   # server - local

    def sync(self, server_ts_ms: int, local_ts_ms: int = None):
        local_ts_ms = local_ts_ms or int(time.time() * 1000)
        self.diff_ms = server_ts_ms - local_ts_ms

    def now(self) -> int:
        return int(time.time() * 1000) + self.diff_ms


# ============================================================
# 四、看课埋点上报 (collect/batch)
# ============================================================
class MstPlayerReporter:
    """复刻 BizPoint 插件的上报行为"""

    def __init__(self, begin_time: int = None):
        self.clock = ServerClock()
        # begin_time: 开始播放的服务器时间戳
        self.begin_time = begin_time or self.clock.now()
        self._uuid = uuid.uuid4().hex[:8]   # 模拟浏览器生成的 8 位 uuid
        self._up_index = 0
        self._last_upload_time = self.begin_time
        self._last_media_time_ms = 0

    # ---- 生成 EventPackage 单条事件 ----
    def _build_event(self, action: int, status: int, stay_time: int,
                     media_time: int, report_time: int, current_time_sec: float,
                     duration_sec: float, speed: int = 1, quality: str = "高清"):
        self._up_index += 1
        return {
            "lesson_id": str(LESSON_ID),
            "course_id": str(COURSE_ID),
            "stay_time": stay_time,                       # duration 参数 = 真实停留时长
            "media_time": media_time,
            "status": status,
            "begin_time": self.begin_time,
            "report_time": report_time,
            "point_time_id": max(1, int(current_time_sec // INTERVAL_TIME) + 1)
                             if current_time_sec else 1,
            "point_time": 1000 * INTERVAL_TIME,           # 60000
            "point_num": max(1, int(duration_sec // INTERVAL_TIME) + 1)
                        if duration_sec else 1,
            "video_type": VIDEO_TYPE,
            "speed": speed,
            "quality": quality,
            "action": action,
            "fallback": 0,
            "uuid": f"{self._uuid}_{self._up_index}",
        }

    # ---- 组装完整请求体 ----
    def build_payload(self, event: dict, report_time: int):
        common = {
            "userid": USER_ID,
            "ip": CLIENT_IP,
            "os": "Windows",
            "resolution": RESOLUTION,
            "mstid": TOKEN,
            "browser": "Edge",
            "browser_ver": BROWSER_VER,
            "playerType": 1,
            "sdkVersion": SDK_VERSION,
            "videoBizCode": VIDEO_BIZ_CODE,
            "memberProvinceCode": MEMBER_PROVINCE_CODE,
            "schoolId": str(SCHOOL_ID),
            "schoolProvinceCode": MEMBER_PROVINCE_CODE,
        }
        signature = make_secret_key(
            action=event["action"],
            duration=event["stay_time"],
            mstid=TOKEN,
            timestamp=report_time,
        )
        return {
            "CommonPackage": common,
            "EventPackage": [event],
            "signature": signature,
            "sn": SN,
            "_": report_time,
        }

    # ---- 组装 URL query ----
    def build_query(self, event: dict):
        return {
            "TrVideoBizCode": VIDEO_BIZ_CODE,
            "TrFallback": event["fallback"],
            "TrUserId": USER_ID,
            "TrLessonId": event["lesson_id"],
            "TrUuId": event["uuid"],
            "sdkVersion": SDK_VERSION,
            "_": int(time.time() * 1000),    # 防缓存时间戳
        }

    # ---- 发送 ----
    def send(self, payload: dict, query: dict, timeout: int = 15):
        headers = {
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "x-bfe-session-id": SESSION_ID,
            "token": TOKEN,
            "Origin": "https://teacher.ewt360.com",
            "Referer": REFER_URL,
            "User-Agent": BROWSER_VER,
        }
        url = f"{COLLECT_URL}?{urlencode(query)}"
        print(f"[SEND] POST {url}")
        print(f"       body={json.dumps(payload, ensure_ascii=False)[:300]}...")
        resp = requests.post(url, headers=headers, data=json.dumps(payload, ensure_ascii=False),
                             timeout=timeout)
        print(f"       -> HTTP {resp.status_code}: {resp.text[:200]}")
        try:
            data = resp.json()
        except Exception:
            data = {}
        # 用响应 ts 校准服务器时间
        ts = (data.get("data") or {}).get("ts")
        if ts:
            self.clock.sync(ts)
        return data

    # ---- 高层事件封装 ----
    def report_play(self, current_time_sec: float = 0, duration_sec: float = 763):
        """onPlay -> uploadPlayLike: action=PLAYING, status=WATCH, 0,0"""
        report_time = self.clock.now()
        event = self._build_event(FC_PLAYING, CLOG_WATCH, 0, 0, report_time,
                                  current_time_sec, duration_sec)
        return self._dispatch(event, report_time)

    def report_heartbeat(self, stay_time_ms: int, media_time_ms: int,
                         current_time_sec: float, duration_sec: float = 763):
        """uploadWatchLike: action=PLAYING, status=WATCH, 心跳周期累计时长"""
        report_time = self.clock.now()
        event = self._build_event(FC_PLAYING, CLOG_WATCH, stay_time_ms, media_time_ms,
                                  report_time, current_time_sec, duration_sec)
        return self._dispatch(event, report_time)

    def report_pause(self, stay_time_ms: int, media_time_ms: int,
                     current_time_sec: float, duration_sec: float = 763):
        """onPause -> uploadPauseLike: 先发 WATCH 心跳，再发 PAUSED"""
        report_time = self.clock.now()
        # 1) WATCH 心跳
        ev1 = self._build_event(FC_PLAYING, CLOG_WATCH, stay_time_ms, media_time_ms,
                                report_time, current_time_sec, duration_sec)
        r1 = self._dispatch(ev1, report_time)
        # 2) PAUSED 事件
        report_time2 = self.clock.now()
        ev2 = self._build_event(FC_PAUSED, CLOG_PAUSED, 0, 0, report_time2,
                                current_time_sec, duration_sec)
        r2 = self._dispatch(ev2, report_time2)
        return r1, r2

    def _dispatch(self, event, report_time):
        payload = self.build_payload(event, report_time)
        query = self.build_query(event)
        return self.send(payload, query)


# ============================================================
# 五、作业任务进度查询
# ============================================================
def get_user_homework_lesson_task_info(homework_id: int = 10495544,
                                       content_type: int = 1):
    headers = {
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "token": TOKEN,
        "referUrl": REFER_URL,
        "Origin": "https://teacher.ewt360.com",
        "Referer": REFER_URL,
        "User-Agent": BROWSER_VER,
    }
    body = {
        "schoolId": SCHOOL_ID,
        "homeworkId": homework_id,
        "lessonId": LESSON_ID,
        "contentType": content_type,
    }
    print(f"[SEND] POST {TASK_INFO_URL}")
    print(f"       body={body}")
    resp = requests.post(TASK_INFO_URL, headers=headers, json=body, timeout=15)
    print(f"       -> HTTP {resp.status_code}: {resp.text[:300]}")
    return resp.json()


# ============================================================
# 六、主流程：签名自检 + 单次上报演示 + 心跳模拟
# ============================================================
def main():
    # 1) 签名自检（不发网络请求）
    if not _self_test_signature():
        print("签名实现有误，终止")
        return

    # 2) 查询作业任务进度（只读接口，安全）
    print("=" * 60)
    print("作业任务进度查询")
    print("=" * 60)
    try:
        task_info = get_user_homework_lesson_task_info()
        print(f"  playTime={task_info.get('data', {}).get('playTime')}")
        print(f"  finishPlayTime={task_info.get('data', {}).get('finishPlayTime')}")
    except Exception as e:
        print(f"  查询失败: {e}")
    print()

    # 3) 看课埋点上报演示
    #    注意：实际发送会向服务器写入看课记录。
    #    若仅需验证请求构造，将 DRY_RUN 置 True 跳过网络发送。
    DRY_RUN = True
    print("=" * 60)
    print(f"看课埋点上报演示 (DRY_RUN={DRY_RUN})")
    print("=" * 60)

    reporter = MstPlayerReporter()
    # 以服务器当前时间作为 begin_time
    reporter.begin_time = reporter.clock.now()
    print(f"  begin_time = {reporter.begin_time}")
    print(f"  uuid       = {reporter._uuid}")

    if DRY_RUN:
        # 仅构造请求、打印，不发送
        ev = reporter._build_event(FC_PLAYING, CLOG_WATCH, 0, 0,
                                   reporter.begin_time, 0, 763)
        payload = reporter.build_payload(ev, reporter.begin_time)
        query = reporter.build_query(ev)
        print("\n  [构造] 播放事件 payload:")
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        print("\n  [构造] query:", query)

        # 校验自身签名一致性
        re_sig = make_secret_key(ev["action"], ev["stay_time"], TOKEN, reporter.begin_time)
        print(f"\n  签名一致性: payload.signature={payload['signature']}")
        print(f"              recomputed        ={re_sig}")
        print(f"              {'✅ 一致' if payload['signature'] == re_sig else '❌ 不一致'}")
        return

    # ---- 真实发送流程（DRY_RUN=False 时执行）----
    # 播放
    reporter.report_play(current_time_sec=0, duration_sec=763)
    time.sleep(2)

    # 模拟 60s 心跳
    reporter.report_heartbeat(stay_time_ms=60000, media_time_ms=60000,
                              current_time_sec=60, duration_sec=763)
    time.sleep(2)

    # 暂停
    reporter.report_pause(stay_time_ms=5000, media_time_ms=5000,
                          current_time_sec=65, duration_sec=763)


if __name__ == "__main__":
    main()
