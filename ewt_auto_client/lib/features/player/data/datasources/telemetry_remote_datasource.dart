/// 看课埋点遥测数据源：collect/batch 上报（sn=moses_ewt_video_detail_2026，bizCode=2013），
/// 实现 BFE→CLOG→DLOG→IPLOG 四级降级链，含服务器时间同步(ServerClock)与 HMAC-SHA1 签名。
/// report_time 必须使用服务器同步时间，否则可能触发 699101 签名错误。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/crypto/crypto_utils.dart';
import '../../../../core/network/api_helper.dart';
import '../../../../core/network/dio_client.dart';
import '../../domain/entities/telemetry_context.dart';

/// 服务器时间同步器
///
/// 对应 mstplayer `checkDiffTime`:
///   _diffTime = data.ts - getMillisecond()
///   report_time = floor(performance.now()) + _diffTime
///
/// 每次收到 collect/batch 响应的 `data.ts` 后调用 [sync] 校准。
/// 上报时间 [now] 始终使用校准后的服务器同步时间，避免 699101/699102。
class ServerClock {
  int _diffMs = 0; // server_ts - local_ts
  int _lastServerTs = 0;
  int _syncCount = 0;

  int get diffMs => _diffMs;
  int get lastServerTs => _lastServerTs;
  int get syncCount => _syncCount;

  /// 用响应 `data.ts` 校准时差
  void sync(int? serverTsMs) {
    if (serverTsMs == null || serverTsMs <= 0) return;
    final localTs = DateTime.now().millisecondsSinceEpoch;
    _diffMs = serverTsMs - localTs;
    _lastServerTs = serverTsMs;
    _syncCount++;
  }

  /// 当前服务器同步时间戳 (毫秒)
  int now() => DateTime.now().millisecondsSinceEpoch + _diffMs;

  /// 偏差超过 10s 时给出告警 (对齐 mstplayer checkDiffTime 阈值)
  bool get needsResync => _diffMs.abs() > 10000 && _syncCount > 0;
}

/// 一次 collect/batch 上报的执行结果
///
/// 用于上层 (引擎/UI) 输出详细日志，对应 `mstplayer_behavior_doc.md` §5 描述的请求/响应字段。
class CollectResult {
  /// 命中的上报通道 ('bfe' / 'clog' / 'dlog')
  final String host;

  /// fallback 字段值 (0=主通道, 1=降级)
  final int fallback;

  /// HTTP 状态码
  final int httpStatus;

  /// 业务 code (200=成功)
  final int code;

  /// 服务器返回的 msg
  final String msg;

  /// 服务器返回的 data.ts (用于时间同步)
  final int? serverTs;

  /// 业务 success 字段
  final bool success;

  /// 签名串 (HMAC-SHA1 hex)
  final String signature;

  /// report_time (本次上报时间戳)
  final int reportTime;

  /// 错误描述 (失败时填)
  final String? error;

  const CollectResult({
    required this.host,
    required this.fallback,
    required this.httpStatus,
    required this.code,
    required this.msg,
    required this.serverTs,
    required this.success,
    required this.signature,
    required this.reportTime,
    this.error,
  });

  bool get isOk => success || code == 200;

  @override
  String toString() {
    final ts = serverTs != null ? '$serverTs' : 'null';
    return 'CollectResult(host=$host, fallback=$fallback, http=$httpStatus, '
        'code=$code, msg=$msg, ts=$ts, ok=$isOk, sig=${signature.substring(0, signature.length > 12 ? 12 : signature.length)}..., rt=$reportTime)';
  }
}

/// 遥测数据源 (BFE → CLOG → DLOG → IPLOG 四级降级)
///
/// 对应 Python: core/player.py 中的 `send_collect_batch` /
/// `_send_bfe_collect` / `_send_clog_collect` / `_send_dlog_collect`，
/// 以及 `mstplayer_behavior_doc.md` §4.9/§5 描述的 BizPoint 插件上报行为。
///
/// 关键改进 (vs 旧实现):
/// 1. 引入 [ServerClock] 同步服务器时间，避免 699101 签名错误。
/// 2. 返回 [CollectResult] 暴露 host/code/data.ts/signature，供 UI 详细日志。
/// 3. 提供 [checkDomainConnectivity] 域名连通性预检 (对齐 mstplayer §4.10)。
/// 4. 完整实现 §4.9 四级回退链 bfe→clog→dlog→iplog (含 iplog 直连降级)。
class TelemetryRemoteDataSource {
  final DioClient _client;
  final ServerClock clock = ServerClock();

  TelemetryRemoteDataSource(this._client);

  /// IPLOG 直连 IP:port (来自 getPlayerGlobalConf.globalInfo.fallbackIP)
  ///
  /// 例: "101.37.78.197:8081"。为空时回退到 [ApiConstants.fallbackIpLogDomain]。
  /// 由上层 (ProgressReportService._ensureBfeSession) 在获取 BFE 会话时注入。
  String _fallbackIP = '';

  set fallbackIP(String value) {
    _fallbackIP = value.trim();
  }

  /// 当前 fallbackIP (供自定义脚本注入 account.fallbackIP 使用)
  String get fallbackIP => _fallbackIP;

  /// IPLOG 上报目标 URL (优先 fallbackIP 直连, 回退固定域名)
  String get _iplogTargetUrl {
    if (_fallbackIP.isNotEmpty) {
      return 'http://$_fallbackIP/';
    }
    return '${ApiConstants.fallbackIpLogDomain}/';
  }

  /// 播放进度上报专用 Dio（不挂载网关 Sign/Auth 拦截器）
  ///
  /// /video/playbackProgress 是 teacher.ewt360.com 域下的表单/Cookie 鉴权接口，
  /// 不需要网关签名。若复用 DioClient._dio，AuthInterceptor 会注入 `token` 头并
  /// 把 Origin/Referer 改写成网关域名，SignInterceptor 会注入 sign/secretId/platform，
  /// 这些网关头会导致服务端返回 code=699102「客户端请求参数异常」。
  /// 此处用独立干净 Dio，与原版 curl/HAR 完全一致。
  final Dio _progressDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    responseType: ResponseType.plain,
  ));

  /// 域名连通性预检 (对齐 mstplayer §4.10 `checkDomains`)
  ///
  /// 返回每个 host 的可达性。可选调用，不阻断主流程。
  Future<Map<String, bool>> checkDomainConnectivity({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final hosts = {
      'bfe': ApiConstants.monitorDomain,
      'clog': ApiConstants.clogDomain,
      'dlog': ApiConstants.dlogDomain,
      'iplog': ApiConstants.fallbackIpLogDomain,
    };
    final result = <String, bool>{};
    for (final entry in hosts.entries) {
      try {
        final resp = await _client
            .rawRequest('GET', '${entry.value}/checkstatus')
            .timeout(timeout);
        result[entry.key] = resp.statusCode == 200;
      } catch (_) {
        result[entry.key] = false;
      }
    }
    return result;
  }

  /// 发送一次 collect/batch 遥测上报 (单事件，BFE → CLOG → DLOG → IPLOG 四级降级)
  ///
  /// 返回 [CollectResult] 携带 host/code/data.ts/signature 等信息，
  /// 上层可用其驱动详细日志输出与服务器时间同步。
  ///
  /// [ctx]        遥测上下文 (CommonPackage 级常量)
  /// [sessionId]  BFE 会话 ID (getPlayerGlobalConf.globalInfo.sessionId)
  /// [secret]     HMAC-SHA1 签名密钥 (globalInfo.secret)
  /// [lessonId]   课时 ID (contentId)
  /// [courseId]   课程包 ID (getLessonDetailV2.data.courseId)
  /// [action]     行为类型 (1=START / 2=PLAYING / 3=PAUSED / 4=END)
  /// [stayTime]   本周期停留墙钟毫秒数 (duration 字段)
  /// [beginTs]    播放会话开始时间戳 (整个会话恒定)
  /// [pointTimeId] 检测点序号 (point_time_id)
  /// [pointNum]   总检测点数 (point_num)
  /// [uuid]       上报唯一标识
  /// [mediaTime]  本周期媒体播放毫秒数 (默认等于 stayTime)
  /// [speed]      播放速度
  /// [videoType]  视频类型 (1=普通, 6=校本视频 contentType=11)
  ///
  /// [useBackup]    是否启用备用上报通道 (跳过 bfe 主通道)
  /// [reportBackend] 备用通道选择: 'clog'/'dlog'/'iplog'
  ///                  'iplog' 时使用 getPlayerGlobalConf.fallbackIP 直连
  Future<CollectResult> sendCollectBatch({
    required TelemetryContext ctx,
    required String sessionId,
    required String secret,
    required String lessonId,
    required String courseId,
    required int action,
    required int stayTime,
    required int beginTs,
    required int pointTimeId,
    required int pointNum,
    required String uuid,
    int? mediaTime,
    double speed = 1.0,
    int videoType = 1,
    bool useBackup = false,
    String reportBackend = 'clog',
    int multiEvents = 1,
  }) async {
    // ⚠️ 关键: report_time 必须使用服务器同步时间
    // 对齐 mstplayer: report_time = getMillisecond() + _diffTime
    final reportTs = clock.now();

    final media = mediaTime ?? stayTime;
    final status = (action == 3 || action == 4) ? 3 : 1;

    // 多事件打包 (对齐 Python EVENTS_PER_REQUEST / maxBatchSize):
    // 单次请求携带 [multiEvents] 个 EventPackage 事件, 每个事件
    //   - point_time_id 递增 (min(pointNum, pointTimeId + j))
    //   - media_time 递增 (media + j*stayTime)
    //   - uuid 唯一 (首事件用传入 uuid, 其余追加 _j 后缀)
    // 签名 duration 使用整包总停留 = stayTime * multiEvents (对齐 Python total_stay)。
    final multi = multiEvents.clamp(1, 200);
    List<Map<String, dynamic>> buildEvents(int fallback) => [
          for (var j = 0; j < multi; j++)
            _buildCollectEvent(
              lessonId: lessonId,
              courseId: courseId,
              stayTime: stayTime,
              mediaTime: media + j * stayTime,
              status: status,
              beginTs: beginTs,
              reportTs: reportTs,
              pointTimeId: math.min(pointNum, pointTimeId + j),
              pointNum: pointNum,
              videoType: videoType,
              speed: speed,
              action: action,
              fallback: fallback,
              uuid: j == 0 ? uuid : '${uuid}_$j',
            )
        ];
    // BFE 主通道 fallback=0, 其余降级通道 fallback=1
    final events = buildEvents(0);
    final eventsFb = buildEvents(1);

    final common = _buildCommon(ctx);
    final signature = BfeSigner.signCollect(
      secret: secret,
      token: ctx.token,
      action: action,
      duration: stayTime * multi,
      timestamp: reportTs,
    );

    // 降级链总超时兜底: 四级串行 (bfe→clog→dlog→iplog) 最坏可达 40s+,
    // 限制整链预算, 超时立即放弃本轮上报, 避免拖慢心跳循环 (影响发包节奏)。
    // 保持原有串行时序不变, 仅在各通道入口检查预算。
    final chainDeadline = DateTime.now().add(const Duration(seconds: 25));
    CollectResult chainTimeout(String host) => CollectResult(
          host: host,
          fallback: 1,
          httpStatus: 0,
          code: 0,
          msg: 'chain-timeout',
          serverTs: null,
          success: false,
          signature: signature,
          reportTime: reportTs,
          error: '降级链总超时 (25s)',
        );

    // ⛳ 备用通道直选: 用户在配置弹窗中指定通道时, 跳过 bfe 主通道直接走指定通道
    // - 'clog'/'dlog': 直接走对应通道 (与自动降级链中的 ②/③ 调用一致)
    // - 'iplog': 直接走 IPLOG (使用 fallbackIP 直连), 适合 bfe/clog/dlog 均不可用的场景
    if (useBackup && reportBackend == 'iplog') {
      try {
        return await _sendIplog(
          ctx: ctx,
          sessionId: sessionId,
          lessonId: lessonId,
          uuid: uuid,
          reportTs: reportTs,
          common: common,
          events: buildEvents(1),
          signature: signature,
        );
      } catch (e) {
        return CollectResult(
          host: 'iplog',
          fallback: 1,
          httpStatus: 0,
          code: 0,
          msg: 'iplog-direct-failed',
          serverTs: null,
          success: false,
          signature: signature,
          reportTime: reportTs,
          error: '$e',
        );
      }
    }

    // ① BFE (主通道, fallback=0)
    // useBackup=true && reportBackend='clog'/'dlog' 时跳过 bfe, 直接走 ②/③
    CollectResult? result;
    final skipBfe = useBackup &&
        (reportBackend == 'clog' || reportBackend == 'dlog');
    if (!skipBfe) {
      if (DateTime.now().isAfter(chainDeadline)) return chainTimeout('bfe');
      try {
        result = await _sendBfeOrClog(
          host: 'bfe',
          hostUrl: ApiConstants.monitorDomain,
          fallback: 0,
          ctx: ctx,
          sessionId: sessionId,
          lessonId: lessonId,
          uuid: uuid,
          reportTs: reportTs,
          common: common,
          events: events,
          signature: signature,
        );
        if (result.isOk) return result;
      } catch (e) {
        result = CollectResult(
          host: 'bfe',
          fallback: 0,
          httpStatus: 0,
          code: 0,
          msg: 'exception',
          serverTs: null,
          success: false,
          signature: signature,
          reportTime: reportTs,
          error: '$e',
        );
      }
    }

    // ② CLOG (降级, fallback=1)
    // useBackup=true && reportBackend='dlog' 时跳过 clog, 直接走 ③
    final skipClog = useBackup && reportBackend == 'dlog';
    if (!skipClog) {
      if (DateTime.now().isAfter(chainDeadline)) return chainTimeout('clog');
      try {
        final clogResult = await _sendBfeOrClog(
          host: 'clog',
          hostUrl: ApiConstants.clogDomain,
          fallback: 1,
          ctx: ctx,
          sessionId: sessionId,
          lessonId: lessonId,
          uuid: uuid,
          reportTs: reportTs,
          common: common,
          events: eventsFb,
          signature: signature,
        );
        if (clogResult.isOk) return clogResult;
      } catch (_) {}
    }

    // ③ DLOG (备用, form-urlencoded, MD5 签名, fallback=1)
    if (DateTime.now().isAfter(chainDeadline)) return chainTimeout('dlog');
    try {
      final dlogResult = await _sendDlog(
        ctx: ctx,
        reportTs: reportTs,
        common: common,
        events: eventsFb,
      );
      if (dlogResult.isOk) return dlogResult;
    } catch (_) {}

    // ④ IPLOG (最终降级, fallbackIP 直连, fallback=1)
    // 对齐文档 §4.9 四级回退链 bfe→clog→dlog→iplog, 实际触发概率极低。
    try {
      final iplogResult = await _sendIplog(
        ctx: ctx,
        sessionId: sessionId,
        lessonId: lessonId,
        uuid: uuid,
        reportTs: reportTs,
        common: common,
        events: eventsFb,
        signature: signature,
      );
      return iplogResult;
    } catch (e) {
      return CollectResult(
        host: 'iplog',
        fallback: 1,
        httpStatus: 0,
        code: 0,
        msg: 'all-hosts-failed',
        serverTs: null,
        success: false,
        signature: signature,
        reportTime: reportTs,
        error: '$e',
      );
    }
  }

  /// 指定通道 + 指定会话 collect 上报 (快刷模式2 多 session 预算乘法专用)
  ///
  /// 对齐 probe11_multisession.py (V8): 限速预算以客户端可控的
  /// `x-bfe-session-id` 为键, 每个 session 独立核算信用 (~45s 初始预算)。
  /// 每 session 由独立 getPlayerGlobalConf 调用签发, 请求轮流分发到
  /// bfe/clog/dlog 三端点 (功能等价的入库通道)。
  ///
  /// 载荷与主通道完全一致 (fallback=0, bfe 格式 JSON, dlog 也接受);
  /// 单事件打包 (multi=1) 对齐实测最优入账率 (多事件批量会被钳制)。
  Future<CollectResult> sendCollectBatchToHost({
    required String host,
    required TelemetryContext ctx,
    required String sessionId,
    required String secret,
    required String lessonId,
    required String courseId,
    required int action,
    required int stayTime,
    required int beginTs,
    required int pointTimeId,
    required int pointNum,
    required String uuid,
    int? mediaTime,
    double speed = 1.0,
    int videoType = 1,
    int multiEvents = 1,
  }) async {
    final reportTs = clock.now();
    final media = mediaTime ?? stayTime;
    final status = (action == 3 || action == 4) ? 3 : 1;

    final multi = multiEvents.clamp(1, 200);
    final events = [
      for (var j = 0; j < multi; j++)
        _buildCollectEvent(
          lessonId: lessonId,
          courseId: courseId,
          stayTime: stayTime,
          mediaTime: media + j * stayTime,
          status: status,
          beginTs: beginTs,
          reportTs: reportTs,
          pointTimeId: math.min(pointNum, pointTimeId + j),
          pointNum: pointNum,
          videoType: videoType,
          speed: speed,
          action: action,
          fallback: 0,
          uuid: j == 0 ? uuid : '${uuid}_$j',
        ),
    ];

    final common = _buildCommon(ctx);
    final signature = BfeSigner.signCollect(
      secret: secret,
      token: ctx.token,
      action: action,
      duration: stayTime * multi,
      timestamp: reportTs,
    );

    final hostUrl = switch (host) {
      'clog' => ApiConstants.clogDomain,
      'dlog' => ApiConstants.dlogDomain,
      _ => ApiConstants.monitorDomain,
    };

    try {
      return await _sendBfeOrClog(
        host: host,
        hostUrl: hostUrl,
        fallback: 0,
        ctx: ctx,
        sessionId: sessionId,
        lessonId: lessonId,
        uuid: uuid,
        reportTs: reportTs,
        common: common,
        events: events,
        signature: signature,
      );
    } catch (e) {
      return CollectResult(
        host: host,
        fallback: 0,
        httpStatus: 0,
        code: 0,
        msg: 'exception',
        serverTs: null,
        success: false,
        signature: signature,
        reportTime: reportTs,
        error: '$e',
      );
    }
  }

  /// 发送播放进度持久化
  ///
  /// POST https://bfe.ewt360.com/video/playbackProgress
  /// Content-Type: multipart/form-data
  /// 字段: userId / lessonId / playedProgress(浮点秒) / videoBizCode=1013
  /// 认证: teacher 域 Cookie（无网关 token 头 / 无 sign 头）
  /// 对应 Python: core/player.py playback_progress
  /// 对应 mstplayer `progressPoint.sendInfo()` (§4.4 失焦/周期触发)
  ///
  /// 返回 true=成功, 失败时不阻断主流程。
  Future<bool> sendPlaybackProgress({
    required String userId,
    required String token,
    required String lessonId,
    required int playTime,
  }) async {
    // 浮点秒格式化: 与 Python 一致 ("278.164614" 风格)
    final progressStr = playTime.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');

    try {
      final formData = FormData.fromMap({
        'userId': userId,
        'lessonId': lessonId,
        'playedProgress': progressStr,
        'videoBizCode': '1013',
      });

      final resp = await _progressDio.post(
        '${ApiConstants.monitorDomain}${ApiConstants.playbackProgressUrl}',
        data: formData,
        options: Options(
          headers: {
            'User-Agent': _client.endpointConfig.userAgent,
            ...ApiHeaders.teacher,
            'Cookie': 'token=$token',
          },
        ),
      );
      return resp.statusCode == 200;
    } catch (_) {
      // 进度持久化失败不中断流程
      return false;
    }
  }

  // ─── 内部方法 ───

  /// 构建 CommonPackage (WEB 端，对应 Python `_build_collect_common`)
  ///
  /// 对齐 `mstplayer_behavior_doc.md` §5.4 CommonPackage 结构:
  ///   userid(整型) / ip / os / resolution / mstid / browser / browser_ver /
  ///   playerType / sdkVersion / videoBizCode / memberProvinceCode /
  ///   schoolId / schoolProvinceCode
  Map<String, dynamic> _buildCommon(TelemetryContext ctx) {
    return {
      'userid': int.tryParse(ctx.userId) ?? 0,
      'ip': ctx.clientIp.isNotEmpty ? ctx.clientIp : '114.114.114.114',
      'os': 'Windows',
      'resolution': '1920*1080',
      'mstid': ctx.token,
      'browser': 'Chrome',
      'browser_ver': ctx.userAgent,
      'playerType': 1,
      'sdkVersion': ctx.sdkVersion,
      'videoBizCode': ctx.videoBizCode,
      'memberProvinceCode': ctx.memberProvinceCode,
      'schoolId': ctx.schoolId,
      'schoolProvinceCode': ctx.schoolProvinceCode,
    };
  }

  /// 构建一个 BFE collect 事件 (EventPackage 单元素)
  ///
  /// 对齐 Python `_build_event`: 单个事件携带 stay_time / media_time / point_time_id
  /// 等字段, 多事件打包时由调用方按 j 递增 point_time_id 与 media_time。
  Map<String, dynamic> _buildCollectEvent({
    required String lessonId,
    required String courseId,
    required int stayTime,
    required int mediaTime,
    required int status,
    required int beginTs,
    required int reportTs,
    required int pointTimeId,
    required int pointNum,
    required int videoType,
    required double speed,
    required int action,
    required int fallback,
    required String uuid,
  }) =>
      {
        'lesson_id': lessonId,
        'course_id': courseId,
        'stay_time': stayTime,
        'media_time': mediaTime,
        'status': status,
        'begin_time': beginTs,
        'report_time': reportTs,
        'point_time_id': pointTimeId,
        'point_time': 1000 * 60, // 60000ms (对齐 intervalTime=60s)
        'point_num': pointNum,
        'video_type': videoType,
        'speed': speed,
        'quality': '高清',
        'action': action,
        'fallback': fallback,
        'uuid': uuid,
      };

  /// BFE / CLOG 上报 (两者结构一致，仅域名与 fallback 不同)
  ///
  /// 对齐 §5.4 请求体: {CommonPackage, EventPackage:[event], signature, sn, _}
  Future<CollectResult> _sendBfeOrClog({
    required String host,
    required String hostUrl,
    required int fallback,
    required TelemetryContext ctx,
    required String sessionId,
    required String lessonId,
    required String uuid,
    required int reportTs,
    required Map<String, dynamic> common,
    required List<Map<String, dynamic>> events,
    required String signature,
  }) async {
    final payload = jsonEncode({
      'CommonPackage': common,
      'EventPackage': events,
      'signature': signature,
      'sn': ctx.playerSn,
      '_': reportTs,
    });

    final url = '$hostUrl${ApiConstants.monitorCollectUrl}'
        '?TrVideoBizCode=${ctx.videoBizCode}&TrFallback=$fallback'
        '&TrUserId=${ctx.userId}&TrLessonId=$lessonId'
        '&TrUuId=$uuid&sdkVersion=${ctx.sdkVersion}&_=$reportTs';

    final resp = await _client.rawRequest(
      'POST',
      url,
      data: payload,
      headers: _collectHeaders(ctx, sessionId),
    );

    // 解析响应 (对齐 §5.6: {code, data:{ts}, msg, success})
    dynamic data = resp.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        data = <String, dynamic>{};
      }
    }
    final dataMap = data is Map<String, dynamic> ? data : <String, dynamic>{};
    final code = (dataMap['code'] is int)
        ? dataMap['code'] as int
        : int.tryParse(dataMap['code']?.toString() ?? '') ?? 0;
    final msg = dataMap['msg']?.toString() ?? '';
    final success = dataMap['success'] == true || code == 200;
    final innerData = dataMap['data'];
    int? serverTs;
    if (innerData is Map) {
      final ts = innerData['ts'];
      if (ts != null) {
        serverTs = (ts is int) ? ts : int.tryParse(ts.toString());
      }
    }
    // ⚠️ 关键: 用响应 ts 校准服务器时间 (对应 mstplayer checkDiffTime)
    if (serverTs != null) clock.sync(serverTs);

    return CollectResult(
      host: host,
      fallback: fallback,
      httpStatus: resp.statusCode ?? 0,
      code: code,
      msg: msg,
      serverTs: serverTs,
      success: success,
      signature: signature,
      reportTime: reportTs,
      error: success ? null : 'code=$code msg=$msg',
    );
  }

  /// DLOG 上报 (form-urlencoded，MD5 签名，不含 Token / X-Bfe-Session-Id)
  ///
  /// 对齐 §4.9 多通道回退链 bfe→clog→dlog→iplog 的 dlog 分支。
  Future<CollectResult> _sendDlog({
    required TelemetryContext ctx,
    required int reportTs,
    required Map<String, dynamic> common,
    required List<Map<String, dynamic>> events,
  }) async {
    final logJson = jsonEncode({
      'CommonPackage': common,
      'EventPackage': events,
    });
    final sign = DlogSigner.sign(logJson);
    final formBody = 'sn=${Uri.encodeQueryComponent(ctx.playerSn)}'
        '&log=${Uri.encodeQueryComponent(logJson)}'
        '&ts=$reportTs'
        '&sign=$sign';

    final resp = await _client.rawRequest(
      'POST',
      '${ApiConstants.dlogDomain}/',
      data: formBody,
      headers: {
        ..._collectHeaders(ctx, '', isDlog: true),
        'content-type': 'application/x-www-form-urlencoded',
      },
    );
    final ok = resp.statusCode == 200;
    return CollectResult(
      host: 'dlog',
      fallback: 1,
      httpStatus: resp.statusCode ?? 0,
      code: ok ? 200 : 0,
      msg: ok ? 'ok' : 'http-${resp.statusCode}',
      serverTs: null,
      success: ok,
      signature: sign,
      reportTime: reportTs,
      error: ok ? null : 'DLOG HTTP ${resp.statusCode}',
    );
  }

  /// IPLOG 上报 (fallbackIP 直连, 最终降级通道)
  ///
  /// 对齐文档 §4.9 四级回退链 bfe→clog→dlog→iplog 的最终分支。
  /// 使用 BFE 格式 JSON (与 bfe/clog/dlog 一致), 仅域名不同。
  ///
  /// 目标 URL 优先使用 `getPlayerGlobalConf.globalInfo.fallbackIP` (如 101.37.78.197:8081),
  /// 为空时回退到 [ApiConstants.fallbackIpLogDomain] 固定域名。
  Future<CollectResult> _sendIplog({
    required TelemetryContext ctx,
    required String sessionId,
    required String lessonId,
    required String uuid,
    required int reportTs,
    required Map<String, dynamic> common,
    required List<Map<String, dynamic>> events,
    required String signature,
  }) async {
    final payload = jsonEncode({
      'CommonPackage': common,
      'EventPackage': events,
      'signature': signature,
      'sn': ctx.playerSn,
      '_': reportTs,
    });

    final url = '$_iplogTargetUrl${ApiConstants.monitorCollectUrl}'
        '?TrVideoBizCode=${ctx.videoBizCode}&TrFallback=1'
        '&TrUserId=${ctx.userId}&TrLessonId=$lessonId'
        '&TrUuId=$uuid&sdkVersion=${ctx.sdkVersion}&_=$reportTs';

    final resp = await _client.rawRequest(
      'POST',
      url,
      data: payload,
      headers: _collectHeaders(ctx, sessionId),
    );

    dynamic data = resp.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        data = <String, dynamic>{};
      }
    }
    final dataMap = data is Map<String, dynamic> ? data : <String, dynamic>{};
    final code = (dataMap['code'] is int)
        ? dataMap['code'] as int
        : int.tryParse(dataMap['code']?.toString() ?? '') ?? 0;
    final msg = dataMap['msg']?.toString() ?? '';
    final success = dataMap['success'] == true || code == 200;
    final innerData = dataMap['data'];
    int? serverTs;
    if (innerData is Map) {
      final ts = innerData['ts'];
      if (ts != null) {
        serverTs = (ts is int) ? ts : int.tryParse(ts.toString());
      }
    }
    if (serverTs != null) clock.sync(serverTs);

    return CollectResult(
      host: 'iplog',
      fallback: 1,
      httpStatus: resp.statusCode ?? 0,
      code: code,
      msg: msg,
      serverTs: serverTs,
      success: success,
      signature: signature,
      reportTime: reportTs,
      error: success ? null : 'code=$code msg=$msg',
    );
  }

  /// 构建 BFE/CLOG/DLOG/IPLOG 请求头 (对应 Python `_build_collect_headers`, WEB 端)
  ///
  /// 对齐文档抓包: 实际播放页部署在 teacher.ewt360.com 子域 (非 web 子域),
  /// Origin/Referer 必须使用 teacher.ewt360.com, 否则可能被服务端风控判定异常。
  Map<String, String> _collectHeaders(
    TelemetryContext ctx,
    String sessionId, {
    bool isDlog = false,
  }) {
    final headers = <String, String>{
      'access-control-allow-origin': '*',
      'content-type': 'application/json',
      'origin': 'https://teacher.ewt360.com',
      'referer': 'https://teacher.ewt360.com/',
      'sec-ch-ua-mobile': '?0',
      'sec-ch-ua-platform': '"Windows"',
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'cors',
      'sec-fetch-site': 'same-site',
      'user-agent': ctx.userAgent,
    };
    if (!isDlog) {
      headers['Token'] = ctx.token;
      headers['X-Bfe-Session-Id'] = sessionId;
    }
    return headers;
  }
}
