/// CustomReportRuntime 的 Native 平台实现：基于 quickjs_engine (dart:ffi)
/// 执行用户自定义上报脚本，注入账号/任务上下文并桥接宿主回调。
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

/// Native 平台实现: 使用 quickjs_engine (dart:ffi)
class CustomReportRuntimeImpl {
  CustomReportRuntimeImpl._();

  static CustomReportRuntimeImpl create({
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
    return CustomReportRuntimeImpl._()
      .._client = client
      .._playerRemote = playerRemote
      .._telemetryRemote = telemetryRemote
      .._endpointConfig = endpointConfig
      .._account = account
      .._task = task
      .._sessionId = sessionId
      .._secret = secret
      .._clientIp = clientIp
      .._maxBatchSize = maxBatchSize
      .._useBackup = useBackup
      .._reportBackend = reportBackend
      .._onLog = onLog
      .._onProgress = onProgress
      .._onDetail = onDetail
      .._js = getJavascriptRuntime(xhr: false)
      .._beginTs = telemetryRemote.clock.now()
      .._uuidPrefix = _genUuidPrefixStatic()
      .._install();
  }

  late DioClient _client;
  late PlayerRemoteDataSource _playerRemote;
  late TelemetryRemoteDataSource _telemetryRemote;
  late EndpointConfig _endpointConfig;
  late Map<String, dynamic> _account;
  late Map<String, dynamic> _task;
  late String _sessionId;
  late String _secret;
  late String _clientIp;
  late int _maxBatchSize;
  late bool _useBackup;
  late String _reportBackend;
  late void Function(String msg, LogLevel level) _onLog;
  late void Function(double ratio, String? message) _onProgress;
  late void Function(Map<String, dynamic> detail) _onDetail;
  late JavascriptRuntime _js;
  late int _beginTs;
  late String _uuidPrefix;
  String _playerToken = '';
  Map<String, dynamic> _videoInfo = const {};
  int _resolvedDuration = 0;
  List<int> _checkPoints = const [];
  List<Map<String, dynamic>> _interactiveConfigs = const [];
  SeriousCheckConfig _seriousCheckConfig = const SeriousCheckConfig();
  bool _isBlacklisted = false;
  bool _isInteractiveVideo = false;
  String _courseId = '';
  bool _videoInitialized = false;
  int _lastPti = 0;
  bool _disposed = false;
  static const _kCallTimeout = Duration(seconds: 60);
  int _uuidSeq = 0;

  static String _genUuidPrefixStatic() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  void _install() {
    _installShim();
    _installGlobals();
    _registerBridge();
  }

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

  void _installGlobals() {
    final acc = jsonEncode(_account);
    final tsk = jsonEncode(_task);
    final r = _js.evaluate('''
(function () {
  globalThis.account = $acc;
  globalThis.task = $tsk;

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
        _onLog('JS 桥消息解析失败: $e', LogLevel.error);
      }
    });

    _js.onMessage('__host.note', (args) {
      try {
        final payload = args as Map<String, dynamic>;
        final type = payload['type']?.toString();
        if (type == 'log') {
          final level = _parseLogLevel(payload['level']?.toString());
          _onLog(payload['msg']?.toString() ?? '', level);
        } else if (type == 'progress') {
          final ratio = (payload['ratio'] as num?)?.toDouble().clamp(0.0, 1.0) ??
              0.0;
          final message = payload['message']?.toString();
          _onProgress(ratio, (message == null || message.isEmpty) ? null : message);
        }
      } catch (_) {}
    });
  }

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
    } catch (_) {}
  }

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
    final lessonId = (a['lessonId']?.toString() ?? _task['lessonId'] ?? '')
        .toString();
    final schoolId = (a['schoolId']?.toString() ?? _task['schoolId'] ?? '')
        .toString();
    try {
      final token = await _playerRemote
          .getPlayerToken(
            schoolId: schoolId,
            lessonId: lessonId,
            contentType: (_task['contentType'] as num?)?.toInt() ?? 1,
          )
          .timeout(_kCallTimeout);
      return {'ok': true, 'token': token};
    } catch (e) {
      return {'ok': false, 'token': '', 'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> _handleGetVideoInfo(Map<String, dynamic> a) async {
    final lessonId = (a['lessonId']?.toString() ?? _task['lessonId'] ?? '')
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

  Future<Map<String, dynamic>> _handleSendHeartbeat(Map<String, dynamic> a) async {
    final lessonId = _task['lessonId']?.toString() ?? '';
    final explicitCourseId = a['courseId']?.toString() ?? '';
    final courseId = explicitCourseId.isNotEmpty
        ? explicitCourseId
        : (_courseId.isNotEmpty
            ? _courseId
            : ((_task['videoId']?.toString() ?? '').isNotEmpty
                ? _task['videoId'].toString()
                : lessonId));
    final contentType = (_task['contentType'] as num?)?.toInt() ?? 1;
    try {
      final result = await _telemetryRemote.sendCollectBatch(
        ctx: TelemetryContext(
          userId: _account['userId']?.toString() ?? '',
          token: _account['token']?.toString() ?? '',
          clientIp: _clientIp,
          schoolId: _task['schoolId']?.toString() ?? '',
          memberProvinceCode: _account['provinceCode']?.toString() ?? '',
          schoolProvinceCode: _account['provinceCode']?.toString() ?? '',
          sdkVersion: _endpointConfig.sdkVersion,
          userAgent: _endpointConfig.userAgent,
          videoBizCode: AppConstants.defaultVideoBizCode,
          playerSn: AppConstants.playerSn,
        ),
        sessionId: _sessionId,
        secret: _secret,
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

  Future<dynamic> _handleQueryProgress(Map<String, dynamic> a) async {
    final taskId = (a['taskId']?.toString() ?? _task['taskId'] ?? '').toString();
    if (taskId.isEmpty) return null;
    try {
      final result = await _playerRemote
          .refreshTaskProgress(
            homeworkId: _task['homeworkId']?.toString() ?? '',
            taskId: taskId,
          )
          .timeout(_kCallTimeout);
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

  Future<Map<String, dynamic>> _handleCompleteMission(Map<String, dynamic> a) async {
    final contentId = (a['contentId']?.toString() ?? _task['lessonId'] ?? '')
        .toString();
    final contentType = (a['contentType'] as num?)?.toInt() ??
        (_task['contentType'] as num?)?.toInt() ??
        3;
    final percent = (a['percent'] as num?)?.toInt() ?? 1;
    try {
      await _playerRemote
          .completeMissionByContent(
            schoolId: _task['schoolId']?.toString() ?? '',
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

  Future<Map<String, dynamic>> _handleStartPlayback(Map<String, dynamic> a) async {
    final lessonId = _task['lessonId']?.toString() ?? '';
    final courseId = _courseId.isNotEmpty
        ? _courseId
        : ((_task['videoId']?.toString() ?? '').isNotEmpty
            ? _task['videoId'].toString()
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

  Future<Map<String, dynamic>> _handleInitVideo(Map<String, dynamic> a) async {
    if (_videoInitialized) return _videoSnapshot();
    _videoInitialized = true;

    final lessonId = _task['lessonId']?.toString() ?? '';
    final schoolId = _task['schoolId']?.toString() ?? '';
    final homeworkId = _task['homeworkId']?.toString() ?? '';
    final contentType = (_task['contentType'] as num?)?.toInt() ?? 1;

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
        _onLog('  getPlayerToken 失败(非致命): $e', LogLevel.warning);
      }
    }

    Map<String, dynamic>? evData;
    if (_playerToken.isNotEmpty) {
      try {
        _videoInfo = await _playerRemote
            .getExternalVideoInfo(lessonId: lessonId, videoToken: _playerToken)
            .timeout(_kCallTimeout);
        evData = _videoInfo;
      } catch (e) {
        _onLog('  getExternalVideoInfo 失败(非致命): $e', LogLevel.warning);
      }
    }

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
    if (duration <= 0) duration = (_task['duration'] as num?)?.toInt() ?? 0;
    if (duration <= 0) duration = 600;
    _resolvedDuration = duration;

    _checkPoints = _generateVideoCheckPoints(duration, _interactiveConfigs);
    if (_checkPoints.isEmpty) {
      _checkPoints = _legacyCheckPoints(duration);
    }

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
        final cid = detail['courseId'];
        if (cid != null && cid.toString().isNotEmpty) {
          _courseId = cid.toString();
        }
      } catch (e) {
        _onLog('  getLessonDetailV2 失败(非致命): $e', LogLevel.warning);
      }
    }

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

    try {
      _isBlacklisted = await _playerRemote.getVideodp().timeout(_kCallTimeout);
    } catch (e) {
      _onLog('  getVideodp 失败(非致命, 默认普通用户): $e', LogLevel.warning);
    }

    _onLog(
        '  initVideo: 时长=${duration}s, 检测点=${_checkPoints.length}个, '
        '黑名单=$_isBlacklisted, 互动点=${_interactiveConfigs.length}个, '
        '认真度${_seriousCheckConfig.isDowngrade ? "已降级" : "正常"}',
        LogLevel.info);
    return _videoSnapshot();
  }

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
    return (_task['duration'] as num?)?.toInt() ?? 600;
  }

  Future<Map<String, dynamic>> _handleGetVideodp(Map<String, dynamic> a) async {
    try {
      final bl = await _playerRemote.getVideodp().timeout(_kCallTimeout);
      _isBlacklisted = bl;
      return {'ok': true, 'blacklisted': bl};
    } catch (e) {
      return {'ok': false, 'blacklisted': false, 'error': '$e'};
    }
  }

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

  Future<Map<String, dynamic>> _handleSendVideoCheck(
      Map<String, dynamic> a) async {
    final seriousCheckResult = (a['seriousCheckResult'] as num?)?.toInt() ?? 0;
    final type = (a['type'] as num?)?.toInt() ?? _defaultAddVideoType;
    final interactivePointId = a['interactivePointId']?.toString();
    final captchaToken = a['captchaToken']?.toString();
    final schoolId = _task['schoolId']?.toString() ?? '';
    final homeworkId = _task['homeworkId']?.toString() ?? '';
    final lessonId = _task['lessonId']?.toString() ?? '';
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

  Future<Map<String, dynamic>> _handlePerformFocusCheck(
      Map<String, dynamic> a) async {
    final pti = (a['pti'] as num?)?.toInt() ?? _lastPti + 1;
    final checkPointTime = a['checkPointTime']?.toString();
    final cpIdx = (a['cpIdx'] as num?)?.toInt() ?? 1;
    final cpTotal = (a['cpTotal'] as num?)?.toInt() ?? 1;
    final clickDelayMs = (a['clickDelayMs'] as num?)?.toInt() ?? 2000;

    _onLog(
        '  认真度检测 $cpIdx/$cpTotal (检测点=${checkPointTime ?? "?"}s, '
        '黑名单=$_isBlacklisted ? "是→滑块" : "否→确认")',
        LogLevel.info);

    if (_seriousCheckConfig.isDowngrade) {
      _onLog('  认真度检测已降级 (仅日志): ${_seriousCheckConfig.tips}',
          LogLevel.warning);
      return {'ok': true, 'downgraded': true};
    }

    final interactivePointId = await _resolveFocusInteractivePointId();
    final addVideoType = _defaultAddVideoType;

    final r3 = await _sendCollectInternal(action: 3, stayMs: 0, pti: pti);
    _onLog('  [act=3 检测点暂停] code=${r3['code']} ok=${r3['ok']}',
        r3['ok'] == true ? LogLevel.info : LogLevel.warning);

    String? captchaToken;
    try {
      await _sendVideoCheckInternal(
          seriousCheckResult: 0,
          type: addVideoType,
          interactivePointId: interactivePointId);
      _onLog('  ${_isBlacklisted ? "addVideocss" : "addVideoss"}(0) 首报 ok '
          '(type=$addVideoType, ipId=$interactivePointId)',
          LogLevel.info);
    } catch (e) {
      _onLog('  首报失败: $e', LogLevel.warning);
    }

    if (_isBlacklisted) {
      final cap = await _handleSolveCaptcha(const {});
      captchaToken = (cap['captchaToken']?.toString() ?? '').isNotEmpty
          ? cap['captchaToken'].toString()
          : null;
      _onLog(
          captchaToken != null
              ? '  主动解算滑块成功: ${captchaToken.substring(0, captchaToken.length > 16 ? 16 : captchaToken.length)}...'
              : '  主动解算未拿到 token, 二次上报不带 captchaToken',
          LogLevel.info);
    } else {
      _onLog('  普通用户 (ev 组件), 跳过滑块解算, 直接二次上报', LogLevel.info);
    }

    await Future.delayed(Duration(milliseconds: clickDelayMs.clamp(0, 60000)));

    final reportToken = _isBlacklisted ? captchaToken : null;
    try {
      await _sendVideoCheckInternal(
          seriousCheckResult: 2,
          type: addVideoType,
          interactivePointId: interactivePointId,
          captchaToken: reportToken);
      _onLog(
          reportToken != null && reportToken.isNotEmpty
              ? '  ${_isBlacklisted ? "addVideocss" : "addVideoss"}(2) 二次上报 ok (黑名单, 携带 captchaToken)'
              : '  ${_isBlacklisted ? "addVideocss" : "addVideoss"}(2) 二次上报 ok (无 captchaToken)',
          LogLevel.success);
    } catch (e) {
      _onLog('  二次上报异常: $e', LogLevel.warning);
    }

    final r2 = await _sendCollectInternal(action: 2, stayMs: 0, pti: pti);
    _onLog('  [act=2 检测点恢复] code=${r2['code']} ok=${r2['ok']}',
        r2['ok'] == true ? LogLevel.info : LogLevel.warning);
    await _handlePersistProgress(
        {'playTime': _videoDuration() ~/ _defaultPointNum * pti});

    return {
      'ok': true,
      'captchaToken': captchaToken,
      'addVideoType': addVideoType,
    };
  }

  Future<Map<String, dynamic>> _handleDoInteractivePoint(
      Map<String, dynamic> a) async {
    final configId = a['configId']?.toString() ?? '';
    final timePoint = (a['timePoint'] as num?)?.toInt() ?? 0;
    _onLog('  互动点 (configId=$configId, timePoint=${timePoint}ms)',
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
      _onLog('  getInteractiveConfigDetail 失败: $e', LogLevel.warning);
    }
    if (sceneId == null || sceneId.isEmpty || questionId == null) {
      _onLog('  跳过: 缺少 sceneId/questionId', LogLevel.warning);
      return {'ok': false, 'error': '缺少 sceneId/questionId'};
    }

    String? correct;
    try {
      final r0 = await _playerRemote
          .submitInteractiveAnswer(
            interactiveSceneId: sceneId,
            questionId: questionId,
            myAnswers: const [''],
            lessonId: _task['lessonId']?.toString() ?? '',
          )
          .timeout(_kCallTimeout);
      final answers = (r0['answers'] as List<dynamic>?) ?? [];
      if (answers.isNotEmpty) correct = answers.first?.toString();
    } catch (e) {
      _onLog('  submitAnswer(空答) 失败: $e', LogLevel.warning);
    }

    if (correct != null && correct.isNotEmpty) {
      try {
        await _playerRemote
            .submitInteractiveAnswer(
              interactiveSceneId: sceneId,
              questionId: questionId,
              myAnswers: [correct],
              lessonId: _task['lessonId']?.toString() ?? '',
            )
            .timeout(_kCallTimeout);
        _onLog('  submitAnswer(正确答案) ok', LogLevel.info);
      } catch (e) {
        _onLog('  submitAnswer(正确答案) 失败: $e', LogLevel.warning);
      }
    }

    try {
      await _sendVideoCheckInternal(
          seriousCheckResult: 0, type: 3, interactivePointId: configId);
      await _sendVideoCheckInternal(
          seriousCheckResult: 2, type: 3, interactivePointId: configId);
      _onLog('  ${_isBlacklisted ? "addVideocss" : "addVideoss"}(0→2) 记录通过 ok',
          LogLevel.success);
    } catch (e) {
      _onLog('  互动点上报失败: $e', LogLevel.warning);
    }

    return {'ok': true, 'sceneId': sceneId, 'questionId': questionId, 'correct': correct};
  }

  Future<Map<String, dynamic>> _handlePersistProgress(Map<String, dynamic> a) async {
    final playTime = (a['playTime'] as num?)?.toInt() ?? 0;
    try {
      final ok = await _telemetryRemote
          .sendPlaybackProgress(
            userId: _account['userId']?.toString() ?? '',
            token: _account['token']?.toString() ?? '',
            lessonId: _task['lessonId']?.toString() ?? '',
            playTime: playTime,
          )
          .timeout(_kCallTimeout);
      return {'ok': ok};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> _handleUpdateDetail(Map<String, dynamic> a) async {
    try {
      _onDetail(a);
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

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
            lessonId: _task['lessonId']?.toString() ?? '',
          )
          .timeout(_kCallTimeout);
      return {'ok': true, 'data': data};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  int get _defaultAddVideoType {
    final contentType = (_task['contentType'] as num?)?.toInt() ?? 1;
    if (_isInteractiveVideo) return 3;
    return contentType == 1 ? 1 : 2;
  }

  int get _defaultPointNum {
    final duration = _videoDuration();
    if (duration <= 0) return 10;
    return (duration + 60 - 1) ~/ 60;
  }

  String _nextUuid() {
    _uuidSeq += 1;
    return '${_uuidPrefix}_$_uuidSeq';
  }

  Future<Map<String, dynamic>> _sendCollectInternal({
    required int action,
    required int stayMs,
    required int pti,
    int? mediaMs,
  }) async {
    final lessonId = _task['lessonId']?.toString() ?? '';
    final courseId = _courseId.isNotEmpty
        ? _courseId
        : ((_task['videoId']?.toString() ?? '').isNotEmpty
            ? _task['videoId'].toString()
            : lessonId);
    final contentType = (_task['contentType'] as num?)?.toInt() ?? 1;
    try {
      final result = await _telemetryRemote.sendCollectBatch(
        ctx: TelemetryContext(
          userId: _account['userId']?.toString() ?? '',
          token: _account['token']?.toString() ?? '',
          clientIp: _clientIp,
          schoolId: _task['schoolId']?.toString() ?? '',
          memberProvinceCode: _account['provinceCode']?.toString() ?? '',
          schoolProvinceCode: _account['provinceCode']?.toString() ?? '',
          sdkVersion: _endpointConfig.sdkVersion,
          userAgent: _endpointConfig.userAgent,
          videoBizCode: AppConstants.defaultVideoBizCode,
          playerSn: AppConstants.playerSn,
        ),
        sessionId: _sessionId,
        secret: _secret,
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

  Future<void> _sendVideoCheckInternal({
    required int seriousCheckResult,
    required int type,
    String? interactivePointId,
    String? captchaToken,
  }) async {
    final schoolId = _task['schoolId']?.toString() ?? '';
    final homeworkId = _task['homeworkId']?.toString() ?? '';
    final lessonId = _task['lessonId']?.toString() ?? '';
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

  List<int> _generateVideoCheckPoints(
    int durationSeconds,
    List<Map<String, dynamic>> interactiveConfigs,
  ) {
    final z = durationSeconds.toDouble();
    if (z <= 0) return const [];

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
    final result = <int>[];
    final random = Random();
    for (var i = 0; i < count; i++) {
      final base = start + (range ~/ (count + 1)) * (i + 1);
      final jitter =
          random.nextInt(min(60, (range ~/ (count + 1)) ~/ 4 + 1)) - ((range ~/ (count + 1)) ~/ 8);
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
        if ((_account['token']?.toString() ?? '').isNotEmpty)
          'Authorization': _account['token'].toString(),
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

  Future<void> execute(String script, {Duration? totalTimeout}) async {
    final deadline = totalTimeout;
    try {
      final eval = _js.evaluate(script);
      if (eval.isError) {
        throw ScriptRuntimeException('脚本语法/执行错误: ${eval.stringResult}');
      }
      if (eval.rawResult is Future) {
        await _js.handlePromise(eval, timeout: deadline);
        return;
      }
      if (eval.rawResult != null) {
        return;
      }
      final call = _js.evaluate('main()');
      if (call.isError) {
        throw ScriptRuntimeException('调用 main() 失败: ${call.stringResult}');
      }
      if (call.rawResult is Future) {
        await _js.handlePromise(call, timeout: deadline);
      }
    } on TimeoutException {
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
