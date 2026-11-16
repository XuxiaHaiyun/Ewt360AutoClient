/// 自定义进度上报脚本运行时（QuickJS）：在"自定义模式"下执行用户编写的 JS 脚本
/// 代替内置引擎，提供 log/updateProgress/sendRequest/sendHeartbeat/queryProgress 等宿主函数。
/// 脚本约定定义 `async function main()`，异常与死循环由超时保护兜底。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/constants/crypto_constants.dart';
import '../../../../core/captcha/captcha_service.dart';
import '../../../../core/network/dio_client.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../data/datasources/telemetry_remote_datasource.dart';
import '../../domain/entities/serious_check_config.dart';
import '../../domain/entities/telemetry_context.dart';
import '../dialogs/task_progress_dialog.dart';
import 'custom_report_runtime_types.dart';

/// 自定义进度上报脚本运行时 (QuickJS)
///
/// 在进度上报"自定义模式"下执行用户编写的 QuickJS 脚本, 代替内置引擎
/// (心跳/快刷) 完成上报逻辑。脚本可用的能力:
///
/// 全局字段:
/// - `account`: 账号信息对象 (userId/schoolId/account/displayName/schoolName/
///   provinceCode/provinceName/mobile/token/sessionId/secret/clientIp/sdkVersion/
///   userAgent/videoBizCode)
/// - `task`: 当前任务对象 (title/homeworkId/lessonId/videoId/taskId/contentType/
///   schoolId/duration)
///
/// 宿主函数:
/// - `log(msg, level?)` — 打印日志 (debug/info/warning/error/success)
/// - `updateProgress(ratio, message?)` — 更新任务进度 (0~1)
/// - `updateDetail({playedSeconds, totalSeconds, ...})` — 推送详情栏快照字段
///   (供任务弹窗详情面板展示, 字段与 EngineStateSnapshot 对齐)
/// - `sendRequest({url, method, headers, body, query, timeout})` — 通用请求
///   (相对路径走 EWT 网关带签名/token; 绝对 URL 直连)
/// - `parseJson(str)` — JSON 解析 (失败返回 null)
/// - `sleep(ms)` — 等待指定毫秒
/// - `getPlayerToken(lessonId?, schoolId?)` — 获取播放 token
/// - `getVideoInfo(lessonId?, videoToken?)` — 获取视频信息 (时长/互动点等)
/// - `sendHeartbeat({action, stayMs, pti, mediaMs, pointNum, multiEvents})` —
///   发送 BFE 心跳/事件上报 (默认参数取自当前任务与会话)
/// - `queryProgress(taskId?)` — 查询服务端真实进度 (返回 0~1 或 null)
/// - `completeMission({contentId, contentType, percent})` — FM/板报等直写完成
/// - `startPlayback({processTimeMs})` — record/submit 开始观看 (对齐引擎 _startPlayback)
/// - `getSession()` — 返回 BFE 会话字段 (sessionId/secret/clientIp)
///
/// 脚本约定: 定义 `async function main()` 并在脚本末尾调用 `main()`。
/// 脚本异常/死循环由 [timeout] 与超时保护兜底。
class CustomReportRuntime {
  final DioClient _client;
  final PlayerRemoteDataSource _playerRemote;
  final TelemetryRemoteDataSource _telemetryRemote;
  final EndpointConfig _endpointConfig;

  /// 账号信息字段 (注入 JS 的 account 对象)
  final Map<String, dynamic> account;

  /// 当前任务字段 (注入 JS 的 task 对象)
  final Map<String, dynamic> task;

  /// BFE 会话 (注入 account.sessionId/secret/clientIp)
  final String sessionId;
  final String secret;
  final String clientIp;

  /// 服务端 maxBatchSize (快刷自动事件数时使用)
  final int maxBatchSize;

  /// 日志回调 (JS log → 界面日志流)
  final void Function(String msg, LogLevel level) onLog;

  /// 进度回调 (JS updateProgress → 界面进度)
  final void Function(double ratio, String? message) onProgress;

  /// 详情快照回调 (JS updateDetail → 详情栏 EngineStateSnapshot 字段)
  ///
  /// 脚本通过 updateDetail({...}) 推送 playedSeconds/totalSeconds/检测点进度等,
  /// 由宿主 (ProgressReportService._executeCustom) 组装成 EngineStateSnapshot。
  final void Function(Map<String, dynamic> detail) onDetail;

  final JavascriptRuntime _js;

  /// 会话级 beginTs (服务器同步时钟, 一次脚本执行内固定, 对齐 PlaybackEngine)
  late final int _beginTs;

  /// 8 位随机字符的会话 UUID 前缀 (对齐 PlaybackEngine._genUuidPrefix)
  late final String _uuidPrefix;

  /// 播放 token (initVideo 时获取, 供 videoInfo/检测流程复用)
  String _playerToken = '';

  /// 外部视频信息 (getExternalVideoInfo, initVideo 时填充)
  Map<String, dynamic> _videoInfo = const {};

  /// initVideo 解析出的最终时长 (秒, 对齐 PlaybackEngine session.duration)
  ///
  /// 解析优先级: evData.duration → videoList[0].duration → task.duration → 600。
  /// 存下来供 _videoDuration / _defaultPointNum 使用, 避免重复解析。
  int _resolvedDuration = 0;

  /// 客户端生成的认真度检测点 (秒, 对齐 PlaybackEngine._legacyCheckPoints)
  List<int> _checkPoints = const [];

  /// 互动点配置列表 (对齐 PlaybackEngine session.interactiveConfigs)
  List<Map<String, dynamic>> _interactiveConfigs = const [];

  /// 认真度检测降级配置
  SeriousCheckConfig _seriousCheckConfig = const SeriousCheckConfig();

  /// 黑名单状态 (getVideodp, true → 滑块型 ek 组件)
  bool _isBlacklisted = false;

  /// 互动视频标记 (用于 addVideoss.type 映射)
  bool _isInteractiveVideo = false;

  /// 真实课程 ID (getLessonDetailV2.data.courseId, 对齐引擎 session.courseId)
  ///
  /// 引擎 _sendCollect 用 courseId 作为 collect 事件的 course_id;
  /// 必须用课程包真实 ID, 不能拿 videoId/lessonId 顶替 (服务端会校验 400)。
  String _courseId = '';

  /// 备用上报通道 (对齐引擎 _useBackup/_reportBackend, 由宿主注入)
  bool _useBackup = false;
  String _reportBackend = 'clog';

  /// initVideo 是否已执行 (幂等)
  bool _videoInitialized = false;

  /// 等待 JS 异步宿主调用的总超时
  static const _kCallTimeout = Duration(seconds: 60);


  CustomReportRuntime._({
    required this._client,
    required this._playerRemote,
    required this._telemetryRemote,
    required this._endpointConfig,
    required this.account,
    required this.task,
    required this.sessionId,
    required this.secret,
    required this.clientIp,
    required this.maxBatchSize,
    bool useBackup = false,
    String reportBackend = 'clog',
    required this.onLog,
    required this.onProgress,
    required this.onDetail,
    required this._js,
  })  : _useBackup = useBackup,
        _reportBackend = reportBackend;

  /// 创建并初始化运行时
  ///
  /// 注意: quickjs_engine 的 QuickJS-NG 无墙钟中断 (死循环脚本会占用
  /// 调用线程直到完成), 请勿在脚本中写无界循环; 等待类操作用 [sleep]。
  factory CustomReportRuntime.create({
    required DioClient client,
    required PlayerRemoteDataSource playerRemote,
    required TelemetryRemoteDataSource telemetryRemote,
    required EndpointConfig endpointConfig,
    required Map<String, dynamic> account,
    required Map<String, dynamic> task,
    required String sessionId,
    required String secret,
    required String clientIp,
    required int maxBatchSize,
    bool useBackup = false,
    String reportBackend = 'clog',
    required void Function(String msg, LogLevel level) onLog,
    required void Function(double ratio, String? message) onProgress,
    required void Function(Map<String, dynamic> detail) onDetail,
  }) {
    final js = getJavascriptRuntime(xhr: false);
    final rt = CustomReportRuntime._(
      client: client,
      playerRemote: playerRemote,
      telemetryRemote: telemetryRemote,
      endpointConfig: endpointConfig,
      account: account,
      task: task,
      sessionId: sessionId,
      secret: secret,
      clientIp: clientIp,
      maxBatchSize: maxBatchSize,
      useBackup: useBackup,
      reportBackend: reportBackend,
      onLog: onLog,
      onProgress: onProgress,
      onDetail: onDetail,
      js: js,
    ).._beginTs = telemetryRemote.clock.now();
    rt._uuidPrefix = _genUuidPrefixStatic();
    rt._install();
    return rt;
  }

  static String _genUuidPrefixStatic() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// 安装 JS shim + 全局字段/函数 + Dart 桥
  void _install() {
    _installShim();
    _installGlobals();
    _registerBridge();
  }

  /// Promise 请求表 + 宿主调用入口 (JS 侧)
  void _installShim() {
    final r = _js.evaluate('''
(function () {
  var pending = {};
  var nextId = 0;
  globalThis.__hostCall = function (method, argsJson) {
    return new Promise(function (resolve, reject) {
      var id = ++nextId;
      pending[id] = { resolve: resolve, reject: reject };
      sendMessage('__host.call', JSON.stringify({ id: id, method: method, args: argsJson }));
    });
  };
  globalThis.__hostResolve = function (id, resultJson) {
    var p = pending[id];
    if (!p) return;
    delete pending[id];
    p.resolve(JSON.parse(resultJson));
  };
  globalThis.__hostReject = function (id, errJson) {
    var p = pending[id];
    if (!p) return;
    delete pending[id];
    p.reject(new Error(errJson));
  };
})();
''');
    if (r.isError) {
      throw ScriptRuntimeException('初始化 JS 桥失败: ${r.stringResult}');
    }
  }

  /// 注入 account/task 全局对象与宿主函数 (JS 侧)
  void _installGlobals() {
    final acc = jsonEncode(account);
    final tsk = jsonEncode(task);
    final r = _js.evaluate('''
(function () {
  globalThis.account = $acc;
  globalThis.task = $tsk;

  // 同步单向通道: log / updateProgress (fire-and-forget)
  globalThis.log = function (msg, level) {
    sendMessage('__host.note', JSON.stringify({
      type: 'log',
      msg: String(msg),
      level: level || 'info'
    }));
  };
  globalThis.updateProgress = function (ratio, message) {
    sendMessage('__host.note', JSON.stringify({
      type: 'progress',
      ratio: Number(ratio),
      message: message == null ? '' : String(message)
    }));
  };

  // 异步宿主调用包装 (Promise)
  globalThis.sendRequest = function (opts) {
    return __hostCall('sendRequest', opts || {});
  };
  globalThis.parseJson = function (str) {
    try {
      return JSON.parse(str);
    } catch (e) {
      return null;
    }
  };
  globalThis.sleep = function (ms) {
    return __hostCall('sleep', { ms: ms });
  };
  globalThis.getPlayerToken = function (lessonId, schoolId) {
    return __hostCall('getPlayerToken', { lessonId: lessonId, schoolId: schoolId });
  };
  globalThis.getVideoInfo = function (lessonId, videoToken) {
    return __hostCall('getVideoInfo', { lessonId: lessonId, videoToken: videoToken });
  };
  globalThis.sendHeartbeat = function (opts) {
    return __hostCall('sendHeartbeat', opts || {});
  };
  globalThis.queryProgress = function (taskId) {
    return __hostCall('queryProgress', { taskId: taskId });
  };
  globalThis.completeMission = function (opts) {
    return __hostCall('completeMission', opts || {});
  };
  globalThis.startPlayback = function (opts) {
    return __hostCall('startPlayback', opts || {});
  };
  globalThis.getSession = function () {
    return {
      sessionId: account.sessionId,
      secret: account.secret,
      clientIp: account.clientIp,
      maxBatchSize: account.maxBatchSize
    };
  };

  // ── 普通模式行为链 API (对齐 PlaybackEngine) ──
  // initVideo: 一次性拉取 token/时长/检测点/黑名单/认真度配置/互动点
  globalThis.initVideo = function () {
    return __hostCall('initVideo', {});
  };
  globalThis.getVideodp = function () {
    return __hostCall('getVideodp', {});
  };
  globalThis.getSeriousCheckConfig = function () {
    return __hostCall('getSeriousCheckConfig', {});
  };
  globalThis.solveCaptcha = function () {
    return __hostCall('solveCaptcha', {});
  };
  globalThis.sendVideoCheck = function (opts) {
    return __hostCall('sendVideoCheck', opts || {});
  };
  globalThis.performFocusCheck = function (opts) {
    return __hostCall('performFocusCheck', opts || {});
  };
  globalThis.doInteractivePoint = function (opts) {
    return __hostCall('doInteractivePoint', opts || {});
  };
  globalThis.persistProgress = function (opts) {
    return __hostCall('persistProgress', opts || {});
  };
  globalThis.updateDetail = function (opts) {
    return __hostCall('updateDetail', opts || {});
  };
  globalThis.getInteractiveConfigDetail = function (configId) {
    return __hostCall('getInteractiveConfigDetail', { configId: configId });
  };
  globalThis.submitInteractiveAnswer = function (opts) {
    return __hostCall('submitInteractiveAnswer', opts || {});
  };
})();
''');
    if (r.isError) {
      throw ScriptRuntimeException('初始化全局函数失败: ${r.stringResult}');
    }
  }

  /// Dart 侧桥: __host.call (异步 Promise 通道) + __host.note (同步单向通道)
  ///
  /// 注意: quickjs_engine 的 sendMessage(channel, message) 中 message 必须为
  /// JSON 字符串, Dart handler 收到的是 jsonDecode(message) 的值本身
  /// (Object/Map/List/基本类型), 不是参数数组。
  void _registerBridge() {
    _js.onMessage('__host.call', (args) {
      try {
        final payload = args as Map<String, dynamic>;
        final id = payload['id'];
        final method = payload['method']?.toString() ?? '';
        final callArgs = payload['args'];
        _dispatch(method, callArgs)
            .then((result) {
              _resolveJs(id, result);
            })
            .catchError((Object e, StackTrace st) {
              _rejectJs(id, '$e');
            });
      } catch (e) {
        // 解析失败: 无法取 id, 记日志
        onLog('JS 桥消息解析失败: $e', LogLevel.error);
      }
    });

    _js.onMessage('__host.note', (args) {
      try {
        final payload = args as Map<String, dynamic>;
        final type = payload['type']?.toString();
        if (type == 'log') {
          final level = _parseLogLevel(payload['level']?.toString());
          onLog(payload['msg']?.toString() ?? '', level);
        } else if (type == 'progress') {
          final ratio = (payload['ratio'] as num?)?.toDouble().clamp(0.0, 1.0) ??
              0.0;
          final message = payload['message']?.toString();
          onProgress(ratio, (message == null || message.isEmpty) ? null : message);
        }
      } catch (_) {
        // 忽略解析失败的单条 note
      }
    });
  }

  /// 异步宿主调用结果回填 JS (evaluate 注入 resolve)
  void _resolveJs(dynamic id, dynamic result) {
    final resultJson = jsonEncode(result);
    _safeEvaluate('__hostResolve($id, ${jsonEncode(resultJson)})');
  }

  void _rejectJs(dynamic id, String error) {
    final errJson = jsonEncode(error);
    _safeEvaluate('__hostReject($id, ${jsonEncode(errJson)})');
  }

  void _safeEvaluate(String code) {
    if (_disposed) return;
    try {
      _js.evaluate(code);
    } catch (_) {
      // 注入失败不致命 (脚本可能已结束)
    }
  }

  /// 按 method 分发到 Dart 宿主实现
  Future<dynamic> _dispatch(String method, dynamic args) async {
    final a = args is Map ? Map<String, dynamic>.from(args) : <String, dynamic>{};
    switch (method) {
      case 'sendRequest':
        return _handleSendRequest(a);
      case 'getPlayerToken':
        return _handleGetPlayerToken(a);
      case 'getVideoInfo':
        return _handleGetVideoInfo(a);
      case 'sendHeartbeat':
        return _handleSendHeartbeat(a);
      case 'queryProgress':
        return _handleQueryProgress(a);
      case 'sleep':
        await Future.delayed(
            Duration(milliseconds: (a['ms'] as num?)?.toInt().clamp(0, 600000) ?? 0));
        return true;
      case 'completeMission':
        return _handleCompleteMission(a);
      case 'startPlayback':
        return _handleStartPlayback(a);
      case 'initVideo':
        return _handleInitVideo(a);
      case 'getVideodp':
        return _handleGetVideodp(a);
      case 'getSeriousCheckConfig':
        return _handleGetSeriousCheckConfig(a);
      case 'solveCaptcha':
        return _handleSolveCaptcha(a);
      case 'sendVideoCheck':
        return _handleSendVideoCheck(a);
      case 'performFocusCheck':
        return _handlePerformFocusCheck(a);
      case 'doInteractivePoint':
        return _handleDoInteractivePoint(a);
      case 'persistProgress':
        return _handlePersistProgress(a);
      case 'updateDetail':
        return _handleUpdateDetail(a);
      case 'getInteractiveConfigDetail':
        return _handleGetInteractiveConfigDetail(a);
      case 'submitInteractiveAnswer':
        return _handleSubmitInteractiveAnswer(a);
      default:
        throw ScriptRuntimeException('未知宿主函数: $method');
    }
  }

  // ─── 宿主实现 ───

  /// sendRequest: 相对路径走 EWT 网关 (带签名/token), 绝对 URL 直连
  Future<Map<String, dynamic>> _handleSendRequest(Map<String, dynamic> a) async {
    final url = a['url']?.toString() ?? '';
    if (url.isEmpty) {
      return {'ok': false, 'error': 'url 不能为空'};
    }
    final method = (a['method']?.toString() ?? 'GET').toUpperCase();
    final headers = a['headers'] is Map
        ? Map<String, dynamic>.from(a['headers'] as Map)
        : null;
    final query = a['query'] is Map
        ? Map<String, dynamic>.from(a['query'] as Map)
        : null;
    final body = a['body'];
    final timeoutMs = (a['timeout'] as num?)?.toInt() ?? 30000;
    final timeout = Duration(milliseconds: timeoutMs.clamp(100, 300000));

    final isAbsolute = url.startsWith('http://') || url.startsWith('https://');
    try {
      if (isAbsolute) {
        // 绝对 URL: 裸 Dio 直连 (不带 EWT 拦截器)
        final resp = await _rawDio(timeout).request(
          url,
          data: body is String ? body : jsonEncode(body ?? {}),
          queryParameters: query,
          options: Options(
            method: method,
            headers: headers,
            responseType: ResponseType.json,
            contentType: headers?['Content-Type']?.toString(),
          ),
        );
        return _dioResponseToMap(resp);
      }
      // 相对路径: 走 EWT 网关 (自动签名/token)
      if (method == 'GET') {
        final resp = await _client.get<dynamic>(url,
            queryParameters: query, headers: headers, timeout: timeout);
        return _apiResponseToMap(resp);
      }
      final resp = await _client.post<dynamic>(url,
          data: body, headers: headers, timeout: timeout);
      return _apiResponseToMap(resp);
    } on DioException catch (e) {
      return {
        'ok': false,
        'status': e.response?.statusCode ?? 0,
        'error': e.message ?? e.toString(),
      };
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> _handleGetPlayerToken(Map<String, dynamic> a) async {
    final lessonId = (a['lessonId']?.toString() ?? task['lessonId'] ?? '')
        .toString();
    final schoolId = (a['schoolId']?.toString() ?? task['schoolId'] ?? '')
        .toString();
    try {
      final token = await _playerRemote
          .getPlayerToken(
            schoolId: schoolId,
            lessonId: lessonId,
            contentType: (task['contentType'] as num?)?.toInt() ?? 1,
          )
          .timeout(_kCallTimeout);
      return {'ok': true, 'token': token};
    } catch (e) {
      return {'ok': false, 'token': '', 'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> _handleGetVideoInfo(Map<String, dynamic> a) async {
    final lessonId = (a['lessonId']?.toString() ?? task['lessonId'] ?? '')
        .toString();
    final videoToken = a['videoToken']?.toString() ?? '';
    try {
      final info = await _playerRemote
          .getExternalVideoInfo(lessonId: lessonId, videoToken: videoToken)
          .timeout(_kCallTimeout);
      return {'ok': true, 'info': info};
    } catch (e) {
      return {'ok': false, 'info': <String, dynamic>{}, 'error': '$e'};
    }
  }

  /// sendHeartbeat: 发送 BFE 事件 (act=2 心跳等), 默认参数取自当前任务/会话
  ///
  /// 支持脚本显式传 `courseId` (脚本用 sendRequest 独立解析的真实课程 ID);
  /// 未传时优先用 initVideo 解析的 [_courseId], 再回退 videoId → lessonId。
  Future<Map<String, dynamic>> _handleSendHeartbeat(Map<String, dynamic> a) async {
    final lessonId = task['lessonId']?.toString() ?? '';
    final explicitCourseId = a['courseId']?.toString() ?? '';
    final courseId = explicitCourseId.isNotEmpty
        ? explicitCourseId
        : (_courseId.isNotEmpty
            ? _courseId
            : ((task['videoId']?.toString() ?? '').isNotEmpty
                ? task['videoId'].toString()
                : lessonId));
    final contentType = (task['contentType'] as num?)?.toInt() ?? 1;
    try {
      final result = await _telemetryRemote.sendCollectBatch(
        ctx: TelemetryContext(
          userId: account['userId']?.toString() ?? '',
          token: account['token']?.toString() ?? '',
          clientIp: clientIp,
          schoolId: task['schoolId']?.toString() ?? '',
          memberProvinceCode: account['provinceCode']?.toString() ?? '',
          schoolProvinceCode: account['provinceCode']?.toString() ?? '',
          sdkVersion: _endpointConfig.sdkVersion,
          userAgent: _endpointConfig.userAgent,
          videoBizCode: AppConstants.defaultVideoBizCode,
          playerSn: AppConstants.playerSn,
        ),
        sessionId: sessionId,
        secret: secret,
        lessonId: lessonId,
        courseId: courseId,
        action: (a['action'] as num?)?.toInt() ?? 2,
        stayTime: (a['stayMs'] as num?)?.toInt() ?? 60000,
        beginTs: _beginTs,
        pointTimeId: (a['pti'] as num?)?.toInt() ?? 1,
        pointNum: (a['pointNum'] as num?)?.toInt() ?? _defaultPointNum,
        uuid: _nextUuid(),
        mediaTime: (a['mediaMs'] as num?)?.toInt(),
        speed: (a['speed'] as num?)?.toDouble() ?? 1.0,
        videoType: contentType == 11 ? 6 : 1,
        useBackup: _useBackup,
        reportBackend: _reportBackend,
        multiEvents: (a['multiEvents'] as num?)?.toInt() ?? 1,
      ).timeout(_kCallTimeout);
      return {
        'ok': result.isOk,
        'host': result.host,
        'fallback': result.fallback,
        'httpStatus': result.httpStatus,
        'code': result.code,
        'msg': result.msg,
        'serverTs': result.serverTs,
        'success': result.success,
        'error': result.error,
      };
    } catch (e) {
      return {'ok': false, 'code': 0, 'msg': 'exception', 'error': '$e'};
    }
  }

  /// queryProgress: 查询服务端真实进度 (0~1), 失败返回 null
  Future<dynamic> _handleQueryProgress(Map<String, dynamic> a) async {
    final taskId = (a['taskId']?.toString() ?? task['taskId'] ?? '').toString();
    if (taskId.isEmpty) return null;
    try {
      final result = await _playerRemote
          .refreshTaskProgress(
            homeworkId: task['homeworkId']?.toString() ?? '',
            taskId: taskId,
          )
          .timeout(_kCallTimeout);
      // 提取进度: ratio / finishPercent / percent
      final rv = result['ratio'];
      if (rv != null) {
        final v = double.tryParse(rv.toString());
        if (v != null) return v.clamp(0.0, 1.0);
      }
      final fp = result['finishPercent'] ?? result['percent'];
      if (fp != null) {
        final v = double.tryParse(fp.toString());
        if (v != null) return v.clamp(0.0, 1.0);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// completeMission: FM/板报等直写完成
  Future<Map<String, dynamic>> _handleCompleteMission(Map<String, dynamic> a) async {
    final contentId = (a['contentId']?.toString() ?? task['lessonId'] ?? '')
        .toString();
    final contentType = (a['contentType'] as num?)?.toInt() ??
        (task['contentType'] as num?)?.toInt() ??
        3;
    final percent = (a['percent'] as num?)?.toInt() ?? 1;
    try {
      await _playerRemote
          .completeMissionByContent(
            schoolId: task['schoolId']?.toString() ?? '',
            contentId: contentId,
            contentType: contentType,
            percent: percent,
          )
          .timeout(_kCallTimeout);
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// startPlayback: record/submit 开始观看 (对齐 PlaybackEngine._startPlayback)
  ///
  /// 请求体: submitRecord(courseId, lessonId, processTime, finished: 0)。
  /// [processTimeMs] 续刷时携带已完成进度 (毫秒), 首刷/正常为 0。
  Future<Map<String, dynamic>> _handleStartPlayback(Map<String, dynamic> a) async {
    final lessonId = task['lessonId']?.toString() ?? '';
    // courseId 优先用 initVideo 解析的真实课程 ID (对齐引擎 session.courseId)
    final courseId = _courseId.isNotEmpty
        ? _courseId
        : ((task['videoId']?.toString() ?? '').isNotEmpty
            ? task['videoId'].toString()
            : lessonId);
    final processTimeMs = (a['processTimeMs'] as num?)?.toInt() ?? 0;
    try {
      await _playerRemote
          .submitRecord(
            courseId: courseId,
            lessonId: lessonId,
            processTime: max(0, processTimeMs),
            finished: 0,
          )
          .timeout(_kCallTimeout);
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  // ─── 普通模式行为链 API (对齐 PlaybackEngine) ───

  /// initVideo: 一次性初始化视频会话 (幂等)
  ///
  /// 对齐 PlaybackEngine._initialize: token → 外部视频信息(时长/互动点) →
  /// 检测点生成 → courseId → 认真度降级配置 → 黑名单状态。
  /// 返回 `video` 快照供脚本使用。
  Future<Map<String, dynamic>> _handleInitVideo(Map<String, dynamic> a) async {
    if (_videoInitialized) return _videoSnapshot();
    _videoInitialized = true;

    final lessonId = task['lessonId']?.toString() ?? '';
    final schoolId = task['schoolId']?.toString() ?? '';
    final homeworkId = task['homeworkId']?.toString() ?? '';
    final contentType = (task['contentType'] as num?)?.toInt() ?? 1;

    // 1. 播放 token
    if (_playerToken.isEmpty) {
      try {
        _playerToken = await _playerRemote
            .getPlayerToken(
              schoolId: schoolId,
              lessonId: lessonId,
              contentType: contentType,
            )
            .timeout(_kCallTimeout);
      } catch (e) {
        onLog('  getPlayerToken 失败(非致命): $e', LogLevel.warning);
      }
    }

    // 2. 外部视频信息 (时长/互动点/检测点来源)
    Map<String, dynamic>? evData;
    if (_playerToken.isNotEmpty) {
      try {
        _videoInfo = await _playerRemote
            .getExternalVideoInfo(lessonId: lessonId, videoToken: _playerToken)
            .timeout(_kCallTimeout);
        evData = _videoInfo;
      } catch (e) {
        onLog('  getExternalVideoInfo 失败(非致命): $e', LogLevel.warning);
      }
    }

    // 3. 互动点配置 (interactiveInfo.interactiveConfigList)
    if (evData != null) {
      final info = evData['interactiveInfo'] as Map<String, dynamic>?;
      final list = (info?['interactiveConfigList'] as List<dynamic>?) ?? [];
      final configs = <Map<String, dynamic>>[];
      for (final c in list) {
        if (c is Map<String, dynamic> && c['id'] != null) {
          configs.add({
            'id': c['id'].toString(),
            'timePoint': _parseInt(c['timePoint']),
          });
        }
      }
      _interactiveConfigs = configs;
      _isInteractiveVideo = configs.isNotEmpty;
    }

    // 4. 时长解析 (对齐 _resolveDuration: evData.duration → videoList[0] → task.duration → 600)
    var duration = _parseInt(evData?['duration']);
    if (duration <= 0 && evData != null) {
      final videoList = evData['videoList'] as List<dynamic>?;
      if (videoList != null && videoList.isNotEmpty) {
        final first = videoList.first;
        if (first is Map<String, dynamic>) {
          duration = _parseInt(first['duration']);
        }
      }
    }
    if (duration <= 0) duration = (task['duration'] as num?)?.toInt() ?? 0;
    if (duration <= 0) duration = 600;
    _resolvedDuration = duration;

    // 5. 客户端生成检测点 (对齐 _generateVideoCheckPoints, 空则 legacy 兜底)
    _checkPoints = _generateVideoCheckPoints(duration, _interactiveConfigs);
    if (_checkPoints.isEmpty) {
      _checkPoints = _legacyCheckPoints(duration);
    }

    // 6. courseId + interactiveVideo (getLessonDetail)
    if (homeworkId.isNotEmpty && schoolId.isNotEmpty) {
      try {
        final detail = await _playerRemote
            .getLessonDetail(
              schoolId: schoolId,
              homeworkId: homeworkId,
              lessonId: lessonId,
            )
            .timeout(_kCallTimeout);
        final iv = detail['interactiveVideo'];
        if (iv is bool) _isInteractiveVideo = iv;
        // 真实课程 ID (对齐引擎 session.courseId, collect 事件 course_id 必用)
        final cid = detail['courseId'];
        if (cid != null && cid.toString().isNotEmpty) {
          _courseId = cid.toString();
        }
      } catch (e) {
        onLog('  getLessonDetailV2 失败(非致命): $e', LogLevel.warning);
      }
    }

    // 7. 认真度降级配置
    if (schoolId.isNotEmpty) {
      try {
        final cfg = await _playerRemote
            .getSeriousCheckDownGradeConfig(
              schoolId: schoolId,
              videoType: contentType == 11 ? 6 : 1,
            )
            .timeout(_kCallTimeout);
        _seriousCheckConfig = SeriousCheckConfig.fromJson(cfg);
      } catch (_) {
        _seriousCheckConfig = const SeriousCheckConfig();
      }
    }

    // 8. 黑名单状态
    try {
      _isBlacklisted = await _playerRemote.getVideodp().timeout(_kCallTimeout);
    } catch (e) {
      onLog('  getVideodp 失败(非致命, 默认普通用户): $e', LogLevel.warning);
    }

    onLog(
        '  initVideo: 时长=${duration}s, 检测点=${_checkPoints.length}个, '
        '黑名单=$_isBlacklisted, 互动点=${_interactiveConfigs.length}个, '
        '认真度${_seriousCheckConfig.isDowngrade ? "已降级" : "正常"}',
        LogLevel.info);
    return _videoSnapshot();
  }

  /// video 快照 (脚本可见的初始化结果)
  Map<String, dynamic> _videoSnapshot() {
    return {
      'ok': true,
      'duration': _videoDuration(),
      'checkPoints': _checkPoints,
      'interactiveConfigs': _interactiveConfigs,
      'isBlacklisted': _isBlacklisted,
      'isInteractiveVideo': _isInteractiveVideo,
      'pointNum': _defaultPointNum,
      'seriousCheckConfig': {
        'level': _seriousCheckConfig.level,
        'tips': _seriousCheckConfig.tips,
        'needLog': _seriousCheckConfig.needLog,
        'isDowngrade': _seriousCheckConfig.isDowngrade,
      },
      'playerToken': _playerToken,
    };
  }

  int _videoDuration() {
    if (_resolvedDuration > 0) return _resolvedDuration;
    final d = _parseInt(_videoInfo['duration']);
    if (d > 0) return d;
    return (task['duration'] as num?)?.toInt() ?? 600;
  }

  /// getVideodp: 查询黑名单状态
  Future<Map<String, dynamic>> _handleGetVideodp(Map<String, dynamic> a) async {
    try {
      final bl = await _playerRemote.getVideodp().timeout(_kCallTimeout);
      _isBlacklisted = bl;
      return {'ok': true, 'blacklisted': bl};
    } catch (e) {
      return {'ok': false, 'blacklisted': false, 'error': '$e'};
    }
  }

  /// getSeriousCheckConfig: 认真度检测降级配置
  Future<Map<String, dynamic>> _handleGetSeriousCheckConfig(
      Map<String, dynamic> a) async {
    return {
      'ok': true,
      'level': _seriousCheckConfig.level,
      'tips': _seriousCheckConfig.tips,
      'needLog': _seriousCheckConfig.needLog,
      'isDowngrade': _seriousCheckConfig.isDowngrade,
    };
  }

  /// solveCaptcha: 主动解算认真度检测滑块 (黑名单用户)
  Future<Map<String, dynamic>> _handleSolveCaptcha(Map<String, dynamic> a) async {
    try {
      final service = CaptchaService(
        bizCode: CryptoConstants.passwordCaptchaBizCode,
      );
      final token = await service.solveAutomatically().timeout(_kCallTimeout);
      return {'ok': token.isNotEmpty, 'captchaToken': token};
    } catch (e) {
      return {'ok': false, 'captchaToken': '', 'error': '$e'};
    }
  }

  /// sendVideoCheck: 认真度/互动点上报 (按黑名单自动选 addVideoss/addVideocss)
  Future<Map<String, dynamic>> _handleSendVideoCheck(
      Map<String, dynamic> a) async {
    final seriousCheckResult = (a['seriousCheckResult'] as num?)?.toInt() ?? 0;
    final type = (a['type'] as num?)?.toInt() ?? _defaultAddVideoType;
    final interactivePointId = a['interactivePointId']?.toString();
    final captchaToken = a['captchaToken']?.toString();
    final schoolId = task['schoolId']?.toString() ?? '';
    final homeworkId = task['homeworkId']?.toString() ?? '';
    final lessonId = task['lessonId']?.toString() ?? '';
    try {
      final data = _isBlacklisted
          ? await _playerRemote.addVideocss(
              schoolId: schoolId,
              homeworkId: homeworkId,
              lessonId: lessonId,
              seriousCheckResult: seriousCheckResult,
              type: type,
              interactivePointId: interactivePointId,
              captchaToken: captchaToken,
            )
          : await _playerRemote.addVideoss(
              schoolId: schoolId,
              homeworkId: homeworkId,
              lessonId: lessonId,
              seriousCheckResult: seriousCheckResult,
              type: type,
              interactivePointId: interactivePointId,
              captchaToken: captchaToken,
            );
      return {'ok': true, 'data': data};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// performFocusCheck: 完整认真度检测时序 (对齐 PlaybackEngine._performFocusCheck)
  ///
  /// 流程: act=3 暂停 → 首报(0) → [黑名单]滑块解算 → 点击延迟 →
  /// 二次上报(2, captchaToken) → act=2 恢复 → persistProgress
  /// 降级模式 ([seriousCheckConfig.isDowngrade]) 时仅记录日志不执行。
  Future<Map<String, dynamic>> _handlePerformFocusCheck(
      Map<String, dynamic> a) async {
    final pti = (a['pti'] as num?)?.toInt() ?? _lastPti + 1;
    final checkPointTime = a['checkPointTime']?.toString();
    final cpIdx = (a['cpIdx'] as num?)?.toInt() ?? 1;
    final cpTotal = (a['cpTotal'] as num?)?.toInt() ?? 1;
    final clickDelayMs = (a['clickDelayMs'] as num?)?.toInt() ?? 2000;

    onLog(
        '  认真度检测 $cpIdx/$cpTotal (检测点=${checkPointTime ?? "?"}s, '
        '黑名单=$_isBlacklisted ? "是→滑块" : "否→确认")',
        LogLevel.info);

    // 降级模式: 仅记录
    if (_seriousCheckConfig.isDowngrade) {
      onLog('  认真度检测已降级 (仅日志): ${_seriousCheckConfig.tips}',
          LogLevel.warning);
      return {'ok': true, 'downgraded': true};
    }

    final interactivePointId = await _resolveFocusInteractivePointId();
    final addVideoType = _defaultAddVideoType;

    // act=3 检测点暂停
    final r3 = await _sendCollectInternal(action: 3, stayMs: 0, pti: pti);
    onLog('  [act=3 检测点暂停] code=${r3['code']} ok=${r3['ok']}',
        r3['ok'] == true ? LogLevel.info : LogLevel.warning);

    // 首报 (seriousCheckResult=0)
    String? captchaToken;
    try {
      await _sendVideoCheckInternal(
          seriousCheckResult: 0,
          type: addVideoType,
          interactivePointId: interactivePointId);
      onLog('  ${_isBlacklisted ? "addVideocss" : "addVideoss"}(0) 首报 ok '
          '(type=$addVideoType, ipId=$interactivePointId)',
          LogLevel.info);
    } catch (e) {
      onLog('  首报失败: $e', LogLevel.warning);
    }

    // 主动解算滑块 (仅黑名单)
    if (_isBlacklisted) {
      final cap = await _handleSolveCaptcha(const {});
      captchaToken = (cap['captchaToken']?.toString() ?? '').isNotEmpty
          ? cap['captchaToken'].toString()
          : null;
      onLog(
          captchaToken != null
              ? '  主动解算滑块成功: ${captchaToken.substring(0, captchaToken.length > 16 ? 16 : captchaToken.length)}...'
              : '  主动解算未拿到 token, 二次上报不带 captchaToken',
          LogLevel.info);
    } else {
      onLog('  普通用户 (ev 组件), 跳过滑块解算, 直接二次上报', LogLevel.info);
    }

    // 模拟用户点击通过
    await Future.delayed(Duration(milliseconds: clickDelayMs.clamp(0, 60000)));

    // 二次上报 (seriousCheckResult=2, 黑名单携带 captchaToken)
    final reportToken = _isBlacklisted ? captchaToken : null;
    try {
      await _sendVideoCheckInternal(
          seriousCheckResult: 2,
          type: addVideoType,
          interactivePointId: interactivePointId,
          captchaToken: reportToken);
      onLog(
          reportToken != null && reportToken.isNotEmpty
              ? '  ${_isBlacklisted ? "addVideocss" : "addVideoss"}(2) 二次上报 ok (黑名单, 携带 captchaToken)'
              : '  ${_isBlacklisted ? "addVideocss" : "addVideoss"}(2) 二次上报 ok (无 captchaToken)',
          LogLevel.success);
    } catch (e) {
      onLog('  二次上报异常: $e', LogLevel.warning);
    }

    // act=2 恢复 + 进度持久化
    final r2 = await _sendCollectInternal(action: 2, stayMs: 0, pti: pti);
    onLog('  [act=2 检测点恢复] code=${r2['code']} ok=${r2['ok']}',
        r2['ok'] == true ? LogLevel.info : LogLevel.warning);
    await _handlePersistProgress(
        {'playTime': _videoDuration() ~/ _defaultPointNum * pti});

    return {
      'ok': true,
      'captchaToken': captchaToken,
      'addVideoType': addVideoType,
    };
  }

  /// doInteractivePoint: 完整互动点答题 (对齐 PlaybackEngine._executeInteractivePoint)
  Future<Map<String, dynamic>> _handleDoInteractivePoint(
      Map<String, dynamic> a) async {
    final configId = a['configId']?.toString() ?? '';
    final timePoint = (a['timePoint'] as num?)?.toInt() ?? 0;
    onLog('  互动点 (configId=$configId, timePoint=${timePoint}ms)',
        LogLevel.info);
    if (configId.isEmpty) return {'ok': false, 'error': 'configId 为空'};

    String? sceneId;
    String? questionId;
    try {
      final detail = await _playerRemote
          .getInteractiveConfigDetail(configId: configId)
          .timeout(_kCallTimeout);
      sceneId = detail['interactiveSceneId']?.toString();
      final q = detail['question'] as Map<String, dynamic>?;
      questionId = q?['id']?.toString() ?? detail['questionId']?.toString();
    } catch (e) {
      onLog('  getInteractiveConfigDetail 失败: $e', LogLevel.warning);
    }
    if (sceneId == null || sceneId.isEmpty || questionId == null) {
      onLog('  跳过: 缺少 sceneId/questionId', LogLevel.warning);
      return {'ok': false, 'error': '缺少 sceneId/questionId'};
    }

    // 空答取正确答案
    String? correct;
    try {
      final r0 = await _playerRemote
          .submitInteractiveAnswer(
            interactiveSceneId: sceneId,
            questionId: questionId,
            myAnswers: const [''],
            lessonId: task['lessonId']?.toString() ?? '',
          )
          .timeout(_kCallTimeout);
      final answers = (r0['answers'] as List<dynamic>?) ?? [];
      if (answers.isNotEmpty) correct = answers.first?.toString();
    } catch (e) {
      onLog('  submitAnswer(空答) 失败: $e', LogLevel.warning);
    }

    // 正确答案提交
    if (correct != null && correct.isNotEmpty) {
      try {
        await _playerRemote
            .submitInteractiveAnswer(
              interactiveSceneId: sceneId,
              questionId: questionId,
              myAnswers: [correct],
              lessonId: task['lessonId']?.toString() ?? '',
            )
            .timeout(_kCallTimeout);
        onLog('  submitAnswer(正确答案) ok', LogLevel.info);
      } catch (e) {
        onLog('  submitAnswer(正确答案) 失败: $e', LogLevel.warning);
      }
    }

    // 互动点上报 seriousCheckResult 0→2 (type=3, ipId=configId)
    try {
      await _sendVideoCheckInternal(
          seriousCheckResult: 0, type: 3, interactivePointId: configId);
      await _sendVideoCheckInternal(
          seriousCheckResult: 2, type: 3, interactivePointId: configId);
      onLog('  ${_isBlacklisted ? "addVideocss" : "addVideoss"}(0→2) 记录通过 ok',
          LogLevel.success);
    } catch (e) {
      onLog('  互动点上报失败: $e', LogLevel.warning);
    }

    return {'ok': true, 'sceneId': sceneId, 'questionId': questionId, 'correct': correct};
  }

  /// persistProgress: 进度持久化 (对齐 _persistProgress → sendPlaybackProgress)
  Future<Map<String, dynamic>> _handlePersistProgress(Map<String, dynamic> a) async {
    final playTime = (a['playTime'] as num?)?.toInt() ?? 0;
    try {
      final ok = await _telemetryRemote
          .sendPlaybackProgress(
            userId: account['userId']?.toString() ?? '',
            token: account['token']?.toString() ?? '',
            lessonId: task['lessonId']?.toString() ?? '',
            playTime: playTime,
          )
          .timeout(_kCallTimeout);
      return {'ok': ok};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// updateDetail: 脚本推送详情栏快照字段 (透传, 不加工)
  ///
  /// 支持的字段 (对齐 EngineStateSnapshot):
  ///   playedSeconds / totalSeconds / progress / message / videoCheckPoints /
  ///   completedCheckPointCount / interactiveTotalCount / interactiveDoneCount /
  ///   isBlacklisted / isInteractiveVideo / brushRounds / brushFinalRatio /
  ///   heartbeatOkCount / collectFailCount / lessonFocusDone /
  ///   lessonInteractiveDone / lastPointTimeId / pointNum
  Future<Map<String, dynamic>> _handleUpdateDetail(Map<String, dynamic> a) async {
    try {
      onDetail(a);
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// getInteractiveConfigDetail: 互动配置详情
  Future<Map<String, dynamic>> _handleGetInteractiveConfigDetail(
      Map<String, dynamic> a) async {
    final configId = a['configId']?.toString() ?? '';
    try {
      final detail = await _playerRemote
          .getInteractiveConfigDetail(configId: configId)
          .timeout(_kCallTimeout);
      return {'ok': true, 'detail': detail};
    } catch (e) {
      return {'ok': false, 'detail': <String, dynamic>{}, 'error': '$e'};
    }
  }

  /// submitInteractiveAnswer: 互动答题
  Future<Map<String, dynamic>> _handleSubmitInteractiveAnswer(
      Map<String, dynamic> a) async {
    final interactiveSceneId = a['interactiveSceneId']?.toString() ?? '';
    final questionId = a['questionId']?.toString() ?? '';
    final myAnswers = a['myAnswers'] is List ? a['myAnswers'] as List : <dynamic>[];
    try {
      final data = await _playerRemote
          .submitInteractiveAnswer(
            interactiveSceneId: interactiveSceneId,
            questionId: questionId,
            myAnswers: myAnswers.map((e) => e?.toString() ?? '').toList(),
            lessonId: task['lessonId']?.toString() ?? '',
          )
          .timeout(_kCallTimeout);
      return {'ok': true, 'data': data};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  // ─── 普通模式行为链内部辅助 ───

  int _lastPti = 0;

  /// addVideoss/addVideocss 按黑名单自动选择
  Future<void> _sendVideoCheckInternal({
    required int seriousCheckResult,
    required int type,
    String? interactivePointId,
    String? captchaToken,
  }) async {
    final schoolId = task['schoolId']?.toString() ?? '';
    final homeworkId = task['homeworkId']?.toString() ?? '';
    final lessonId = task['lessonId']?.toString() ?? '';
    if (_isBlacklisted) {
      await _playerRemote.addVideocss(
        schoolId: schoolId,
        homeworkId: homeworkId,
        lessonId: lessonId,
        seriousCheckResult: seriousCheckResult,
        type: type,
        interactivePointId: interactivePointId,
        captchaToken: captchaToken,
      );
    } else {
      await _playerRemote.addVideoss(
        schoolId: schoolId,
        homeworkId: homeworkId,
        lessonId: lessonId,
        seriousCheckResult: seriousCheckResult,
        type: type,
        interactivePointId: interactivePointId,
        captchaToken: captchaToken,
      );
    }
  }

  /// 互动视频检测点的 interactivePointId (对齐 _resolveFocusInteractivePointId)
  Future<String?> _resolveFocusInteractivePointId() async {
    if (!_isInteractiveVideo || _interactiveConfigs.isEmpty) return null;
    final first = _interactiveConfigs.first;
    final cid = first['id']?.toString() ?? '';
    if (cid.isEmpty) return null;
    try {
      final detail = await _playerRemote
          .getInteractiveConfigDetail(configId: cid)
          .timeout(_kCallTimeout);
      return detail['id']?.toString();
    } catch (_) {
      return null;
    }
  }

  /// addVideoss.type 映射 (对齐引擎): interactiveVideo ? 3 : (contentType==1 ? 1 : 2)
  int get _defaultAddVideoType {
    final contentType = (task['contentType'] as num?)?.toInt() ?? 1;
    if (_isInteractiveVideo) return 3;
    return contentType == 1 ? 1 : 2;
  }

  /// BFE collect 上报 (act=2 心跳 / act=3 检测点暂停等)
  Future<Map<String, dynamic>> _sendCollectInternal({
    required int action,
    required int stayMs,
    required int pti,
    int? mediaMs,
  }) async {
    final lessonId = task['lessonId']?.toString() ?? '';
    // courseId 优先用 initVideo 解析的真实课程 ID (对齐引擎 session.courseId)
    final courseId = _courseId.isNotEmpty
        ? _courseId
        : ((task['videoId']?.toString() ?? '').isNotEmpty
            ? task['videoId'].toString()
            : lessonId);
    final contentType = (task['contentType'] as num?)?.toInt() ?? 1;
    try {
      final result = await _telemetryRemote.sendCollectBatch(
        ctx: TelemetryContext(
          userId: account['userId']?.toString() ?? '',
          token: account['token']?.toString() ?? '',
          clientIp: clientIp,
          schoolId: task['schoolId']?.toString() ?? '',
          memberProvinceCode: account['provinceCode']?.toString() ?? '',
          schoolProvinceCode: account['provinceCode']?.toString() ?? '',
          sdkVersion: _endpointConfig.sdkVersion,
          userAgent: _endpointConfig.userAgent,
          videoBizCode: AppConstants.defaultVideoBizCode,
          playerSn: AppConstants.playerSn,
        ),
        sessionId: sessionId,
        secret: secret,
        lessonId: lessonId,
        courseId: courseId,
        action: action,
        stayTime: stayMs,
        beginTs: _beginTs,
        pointTimeId: pti,
        pointNum: _defaultPointNum,
        uuid: _nextUuid(),
        mediaTime: mediaMs,
        speed: 1.0,
        videoType: contentType == 11 ? 6 : 1,
        useBackup: _useBackup,
        reportBackend: _reportBackend,
        multiEvents: 1,
      );
      _lastPti = pti;
      return {
        'ok': result.isOk,
        'host': result.host,
        'fallback': result.fallback,
        'httpStatus': result.httpStatus,
        'code': result.code,
        'msg': result.msg,
        'serverTs': result.serverTs,
        'error': result.error,
      };
    } catch (e) {
      return {'ok': false, 'code': 0, 'msg': 'exception', 'error': '$e'};
    }
  }

  /// 客户端生成认真度检测点 (对齐 PlaybackEngine._legacyCheckPoints)
  List<int> _legacyCheckPoints(int durationSeconds) {
    final z = durationSeconds.toDouble();
    if (z <= 180) return const [];
    final m = z - 120;
    if (m <= 0) return const [];
    final count = m <= 360 ? 1 : (m <= 720 ? 2 : 3);
    final start = 121;
    final end = (0.8 * z).toInt();
    return _mhRange(start, end, count, 60);
  }

  /// 客户端生成 videoCheckPoint 检测点数组 (对齐 PlaybackEngine._generateVideoCheckPoints)
  ///
  /// 算法 (源码: homework-play-video.js):
  /// ```
  /// Z = 视频总时长(秒), t = interactiveConfigList.length (互动题数量)
  /// if (有互动题) {
  ///   if (t >= 3 || Z <= 480) return [];              // 互动题≥3 或 视频≤8分钟 → 不加
  ///   s = ceil(lastInteractiveTimePoint/1000) + 120   // 最后互动题+120s
  ///   o = ceil(0.8 * Z)                                // 视频80%时长
  ///   if (s >= o) return [];
  ///   if (Z <= 900) {                                  // ≤15分钟
  ///     if (t >= 2) return [];
  ///     R = MH(s+1, o, 1, 120);                        // 1个检测点
  ///   } else {                                         // >15分钟
  ///     e = 3 - t;                                     // 检测点数=3-互动题数
  ///     R = MH(s+1, o, e, 120);
  ///   }
  /// } else if (Z > 180) {                              // 无互动题 且 视频>3分钟
  ///   M = (Z-120)*0.8 + 120;                           // 等价 t = (Z-120)*0.8+120
  ///   M > 0 && M <= 360 && (R = MH(121, t, 1));        // 1个检测点
  ///   M > 360 && M <= 720 && (R = MH(121, t, 2));      // 2个检测点
  ///   M > 720 && (R = MH(121, t, 3));                  // 3个检测点
  /// }
  /// ```
  ///
  /// MH(start, end, count, minInterval): 在 [start, end] 区间生成 count 个时间点,
  /// 最小间隔 minInterval 秒 (近似均匀分布)。
  List<int> _generateVideoCheckPoints(
    int durationSeconds,
    List<Map<String, dynamic>> interactiveConfigs,
  ) {
    final z = durationSeconds.toDouble();
    if (z <= 0) return const [];

    // 有互动题
    if (interactiveConfigs.isNotEmpty) {
      final t = interactiveConfigs.length;
      if (t >= 3 || z <= 480) return const [];
      final lastTp = interactiveConfigs.last['timePoint'];
      final lastTpMs = lastTp is num ? lastTp.toInt() : 0;
      final s = (lastTpMs / 1000).ceil() + 120;
      final o = (0.8 * z).ceil();
      if (s >= o) return const [];
      if (z <= 900) {
        if (t >= 2) return const [];
        return _mhRange(s + 1, o, 1, 120);
      } else {
        final e = 3 - t;
        return _mhRange(s + 1, o, e, 120);
      }
    }

    // 无互动题 且 视频 > 180s
    if (z > 180) {
      final m = (z - 120) * 0.8;
      final t = m + 120;
      if (m > 0 && m <= 360) {
        return _mhRange(121, t.toInt(), 1, 60);
      } else if (m > 360 && m <= 720) {
        return _mhRange(121, t.toInt(), 2, 60);
      } else if (m > 720) {
        return _mhRange(121, t.toInt(), 3, 60);
      }
    }
    return const [];
  }

  List<int> _mhRange(int start, int end, int count, int minInterval) {
    if (count <= 0 || end <= start) return const [];
    final range = end - start;
    if (range < count * minInterval) {
      final step = range ~/ (count + 1);
      return List.generate(count, (i) => start + step * (i + 1));
    }
    final step = range ~/ (count + 1);
    final result = <int>[];
    final random = Random();
    for (var i = 0; i < count; i++) {
      final base = start + step * (i + 1);
      final jitter =
          random.nextInt(min(60, step ~/ 4 + 1)) - (step ~/ 8);
      result.add((base + jitter).clamp(start, end));
    }
    result.sort();
    return result;
  }

  int _parseInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  // ─── 工具 ───

  Dio? _rawDioInstance;

  Dio _rawDio(Duration timeout) {
    return _rawDioInstance ??= Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      sendTimeout: timeout,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        if ((account['token']?.toString() ?? '').isNotEmpty)
          'Authorization': account['token'].toString(),
      },
    ));
  }

  Map<String, dynamic> _apiResponseToMap(ApiResponse<dynamic> resp) {
    return {
      'ok': resp.isSuccess,
      'code': resp.code,
      'msg': resp.msg,
      'data': resp.data,
    };
  }

  Map<String, dynamic> _dioResponseToMap(Response<dynamic> resp) {
    return {
      'ok': resp.statusCode != null && resp.statusCode! >= 200 && resp.statusCode! < 300,
      'status': resp.statusCode ?? 0,
      'data': resp.data,
    };
  }

  /// 默认点号总数: 时长(秒)/60s 向上取整 (对齐普通模式 _pointNum)
  ///
  /// 优先使用 initVideo 解析后的时长 (_videoDuration), 与引擎在
  /// _runCourseSession 中基于 session.duration 计算保持一致。
  int get _defaultPointNum {
    final duration = _videoDuration();
    if (duration <= 0) return 10;
    return (duration + 60 - 1) ~/ 60;
  }

  int _uuidSeq = 0;

  String _nextUuid() {
    _uuidSeq += 1;
    return '${_uuidPrefix}_$_uuidSeq';
  }

  LogLevel _parseLogLevel(String? level) {
    switch (level?.toLowerCase()) {
      case 'debug':
        return LogLevel.debug;
      case 'warning':
      case 'warn':
        return LogLevel.warning;
      case 'error':
        return LogLevel.error;
      case 'success':
        return LogLevel.success;
      default:
        return LogLevel.info;
    }
  }

  bool _disposed = false;

  /// 执行用户脚本
  ///
  /// 脚本约定: 定义 `async function main()` 即可, **无需在脚本末尾调用
  /// main()**, 宿主统一调用并驱动其完成 (避免重复执行)。若脚本顶层
  /// 直接执行 (如 async IIFE / 顶层 await), 宿主识别后直接等待。
  /// [totalTimeout] 为 null (默认) 时无总超时, 脚本按真实心跳节奏运行
  /// (普通模式 60s/轮, 长课时可达 60+ 分钟); 显式传入非 null 可限制。
  ///
  /// 注意: quickjs_engine 的 [JsEvalResult.isPromise] 恒为 false (仅
  /// `rawResult is Future` 可识别 async 结果)。
  Future<void> execute(String script, {Duration? totalTimeout}) async {
    // 默认无总超时: 自定义脚本按真实心跳节奏运行 (普通模式 60s/轮,
    // 长课时可达 60+ 分钟), 固定 5 分钟超时会误杀正常执行。
    // 传入非 null 时仍可限制 (如调试用); 由调用方 _executeCustom 显式传 null。
    final deadline = totalTimeout;
    try {
      final eval = _js.evaluate(script);
      if (eval.isError) {
        throw ScriptRuntimeException('脚本语法/执行错误: ${eval.stringResult}');
      }
      if (eval.rawResult is Future) {
        // 脚本顶层已执行 async (IIFE / 末尾 main() 且为 async) → 直接等待
        await _js.handlePromise(eval, timeout: deadline);
        return;
      }
      if (eval.rawResult != null) {
        // 脚本顶层已同步执行 (返回了非 undefined 值) → 不重复调用
        return;
      }
      // 脚本仅定义 main() → 显式调用一次
      final call = _js.evaluate('main()');
      if (call.isError) {
        throw ScriptRuntimeException('调用 main() 失败: ${call.stringResult}');
      }
      if (call.rawResult is Future) {
        await _js.handlePromise(call, timeout: deadline);
      }
    } on TimeoutException {
      // 仅当显式传了 totalTimeout 才可能触发 (默认 null 无超时)
      throw ScriptRuntimeException(
          deadline != null ? '脚本执行超时 (${deadline.inSeconds}s)' : '脚本执行超时');
    } catch (e) {
      if (e is ScriptRuntimeException) rethrow;
      throw ScriptRuntimeException('脚本执行异常: $e');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _js.dispose();
    } catch (_) {}
  }
}
