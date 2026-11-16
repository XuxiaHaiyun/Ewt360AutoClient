/// 进度上报服务：负责获取 BFE 会话（per-user 缓存多课程复用）、课程过滤与批量任务编排，
/// 按所选模式分发到 PlaybackEngine / FastBrush3Runner / 自定义 QuickJS 脚本运行时。
/// 对外暴露日志、会话上下文与引擎状态快照三条 Stream 供 UI 订阅。
library;

import 'dart:async';
import 'dart:math';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/constants/subject_constants.dart';
import '../../../../core/network/dio_client.dart';
import '../../../auth/domain/entities/user_session.dart';
import '../../domain/entities/report_config.dart';
import '../../domain/entities/serious_check_config.dart';
import '../../domain/entities/video_session.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../data/datasources/telemetry_remote_datasource.dart';
import '../../domain/services/playback_engine.dart';
import '../dialogs/task_progress_dialog.dart';
import 'fast_brush3_runner.dart';
// 条件分发: native 用 quickjs_engine (dart:ffi), web 为 stub (不支持脚本模式)
import 'custom_report_runtime_native.dart'
    if (dart.library.js_interop) 'custom_report_runtime_web.dart';
import 'custom_report_runtime_types.dart';

/// 进度上报服务 - 批量执行、课程过滤、任务编排
///
/// 对应 Python: tasks/player_behavior.py + gui/interfaces/my_tasks.py 中的上报逻辑
///
/// 重构后职责划分:
/// - Service: 获取 BFE session (per-user) + 课程过滤 + 任务编排 + UI 回调
/// - PlaybackEngine: 单课程完整行为链 (含 token/videoInfo/courseId 获取)
class ProgressReportService {
  final DioClient _client;
  final EndpointConfig _endpointConfig;
  final PlayerRemoteDataSource _playerRemote;
  final TelemetryRemoteDataSource _telemetryRemote;
  final UserSession? _userSession;

  final _logController = StreamController<ProgressLogEvent>.broadcast();
  final _sessionController = StreamController<SessionContext>.broadcast();
  final _engineStateController =
      StreamController<EngineStateSnapshot>.broadcast();
  final List<PlaybackEngine> _engines = [];
  bool _cancelled = false;
  bool _disposed = false;

  // BFE session 缓存 (per-user, 多课程复用)
  String _sessionId = '';
  String _secret = '';
  String _clientIp = '';

  // 服务端 maxBatchSize (getPlayerGlobalConf.globalInfo.maxBatchSize):
  // 快刷模式每请求事件数 = 0(自动) 时使用, 对齐 Python `_resolve_multi`。
  // 取不到时保持默认 10。
  int _maxBatchSize = 10;

  // 用户基础信息缓存 (baseinfo API, 补全 UserSession 可能缺失的字段)
  Map<String, dynamic> _baseInfo = const {};
  bool _baseInfoFetched = false;

  // 当前引擎引用 (供 engineStateStream 快照轮询)
  PlaybackEngine? _currentEngine;

  /// 进度上报服务
  ///
  /// [playerRemote]/[telemetryRemote] 默认由 [client] 构建; 测试可注入
  /// 替身数据源以脱离真实网络。
  ProgressReportService({
    required DioClient client,
    required EndpointConfig endpointConfig,
    UserSession? userSession,
    PlayerRemoteDataSource? playerRemote,
    TelemetryRemoteDataSource? telemetryRemote,
  })  : _client = client,
        _endpointConfig = endpointConfig,
        _userSession = userSession,
        _playerRemote = playerRemote ?? PlayerRemoteDataSource(client),
        _telemetryRemote = telemetryRemote ?? TelemetryRemoteDataSource(client);

  /// 文本日志流 (过滤明细 / 引擎事件 / 服务器响应)
  Stream<ProgressLogEvent> get logStream => _logController.stream;

  /// BFE 会话上下文流 (sessionId/secret/clientIp + 用户身份)
  Stream<SessionContext> get sessionStream => _sessionController.stream;

  /// 当前引擎实时状态快照流 (时间偏移/检测点/黑名单/认真度配置)
  Stream<EngineStateSnapshot> get engineStateStream =>
      _engineStateController.stream;

  /// 当前引擎引用 (供 UI 主动轮询)
  PlaybackEngine? get currentEngine => _currentEngine;

  // ─── 用户信息字段访问器 (UserSession 优先, 缺失时回退到 baseInfo) ───
  String get _effectiveUserId => _userSession?.userId.isNotEmpty == true
      ? _userSession!.userId
      : _baseInfo['userId']?.toString() ?? '';
  String get _effectiveSchoolId => _userSession?.schoolId.isNotEmpty == true
      ? _userSession!.schoolId
      : _baseInfo['schoolId']?.toString() ?? '';
  String get _effectiveAccount =>
      _userSession?.account?.isNotEmpty == true
          ? _userSession!.account!
          : (_baseInfo['account']?.toString() ??
              _baseInfo['userName']?.toString() ??
              '');
  String get _effectiveDisplayName =>
      _userSession?.displayName?.isNotEmpty == true
          ? _userSession!.displayName!
          : (_baseInfo['realName']?.toString() ??
              _baseInfo['nickName']?.toString() ??
              '');
  String get _effectiveSchoolName =>
      _userSession?.schoolName?.isNotEmpty == true
          ? _userSession!.schoolName!
          : (_baseInfo['schoolName']?.toString() ?? '');
  String get _effectiveProvinceCode =>
      _userSession?.provinceCode?.isNotEmpty == true
          ? _userSession!.provinceCode!
          : (_baseInfo['memberProvinceCode']?.toString() ??
              _baseInfo['provinceCode']?.toString() ??
              '');
  String get _effectiveProvinceName =>
      _baseInfo['memberProvinceName']?.toString() ??
      _baseInfo['provinceName']?.toString() ??
      '';
  String get _effectiveMobile => _userSession?.mobile?.isNotEmpty == true
      ? _userSession!.mobile!
      : (_baseInfo['mobile']?.toString() ?? '');

  void _log(String msg, {LogLevel level = LogLevel.info}) {
    if (_disposed || _logController.isClosed) return;
    _logController.add(ProgressLogEvent(msg, level: level));
  }

  /// 推送 BFE 会话上下文快照
  void _emitSession(SessionContext ctx) {
    if (_disposed || _sessionController.isClosed) return;
    _sessionController.add(ctx);
  }

  /// 推送引擎实时状态快照
  ///
  /// 节流: 快刷并发下引擎进度事件高频到达, 若每条都广播 ~25 字段快照,
  /// UI 会频繁重建。这里按 [_engineThrottleInterval] 合并, 只发最新一帧。
  void _emitEngineState(
    PlaybackEngine engine, {
    required int index,
    required String title,
    PlaybackState state = PlaybackState.initializing,
    double progress = 0.0,
    String? message,
  }) {
    if (_disposed || _engineStateController.isClosed) return;
    _pendingEngineSnapshot = EngineStateSnapshot(
      taskIndex: index,
      taskTitle: title,
      state: state,
      progress: progress,
      playedSeconds: engine.playedSeconds,
      totalSeconds: engine.pointNum * engine.heartbeatInterval,
      serverTimeDiffMs: engine.serverTimeDiffMs,
      serverTimeSyncCount: engine.serverTimeSyncCount,
      serverLastTs: engine.serverLastTs,
      videoCheckPoints: engine.videoCheckPoints,
      completedCheckPointCount: engine.completedCheckPointCount,
      interactiveTotalCount: engine.interactiveTotalCount,
      interactiveDoneCount: engine.interactiveDoneCount,
      isBlacklisted: engine.isBlacklisted,
      isInteractiveVideo: engine.isInteractiveVideo,
      seriousCheckConfig: engine.seriousCheckConfig,
      brushRounds: engine.brushRounds,
      brushFinalRatio: engine.brushFinalRatio,
      heartbeatOkCount: engine.heartbeatOkCount,
      collectFailCount: engine.collectFailCount,
      lessonFocusDone: engine.lessonFocusDone,
      lessonInteractiveDone: engine.lessonInteractiveDone,
      lastPointTimeId: engine.lastPointTimeId,
      pointNum: engine.pointNum,
      message: message,
    );
    _engineThrottleTimer ??= Timer(_engineThrottleInterval, () {
      _engineThrottleTimer = null;
      final snap = _pendingEngineSnapshot;
      _pendingEngineSnapshot = null;
      if (snap != null && !_engineStateController.isClosed) {
        _engineStateController.add(snap);
      }
    });
  }

  /// 自定义模式详情快照推送 (脚本 updateDetail → 详情栏)
  ///
  /// 脚本不经过 PlaybackEngine, 由 [CustomReportRuntimeImpl.onDetail] 透传字段,
  /// 组装 [EngineStateSnapshot] 推送详情面板。同样走 [_engineThrottleInterval]
  /// 节流, 避免脚本高频 updateDetail 时 UI 过频重建。
  void _emitCustomEngineState({
    required int index,
    required String title,
    required Map<String, dynamic> detail,
  }) {
    if (_disposed || _engineStateController.isClosed) return;
    int toInt(dynamic v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
    double toDouble(dynamic v) => v is num
        ? v.toDouble()
        : (double.tryParse('$v') ?? 0);
    final points = detail['videoCheckPoints'];
    final snap = EngineStateSnapshot(
      taskIndex: index,
      taskTitle: title,
      state: PlaybackState.playing,
      progress: toDouble(detail['progress']),
      playedSeconds: toInt(detail['playedSeconds']),
      totalSeconds: toInt(detail['totalSeconds']),
      serverTimeDiffMs: toInt(detail['serverTimeDiffMs']),
      serverTimeSyncCount: toInt(detail['serverTimeSyncCount']),
      serverLastTs: toInt(detail['serverLastTs']),
      videoCheckPoints: points is List
          ? points.map((e) => toInt(e)).toList()
          : const [],
      completedCheckPointCount: toInt(detail['completedCheckPointCount']),
      interactiveTotalCount: toInt(detail['interactiveTotalCount']),
      interactiveDoneCount: toInt(detail['interactiveDoneCount']),
      isBlacklisted: detail['isBlacklisted'] == true,
      isInteractiveVideo: detail['isInteractiveVideo'] == true,
      seriousCheckConfig: SeriousCheckConfig.fromJson(
          detail['seriousCheckConfig'] is Map
              ? Map<String, dynamic>.from(detail['seriousCheckConfig'] as Map)
              : const {}),
      brushRounds: toInt(detail['brushRounds']),
      brushFinalRatio: toDouble(detail['brushFinalRatio']),
      heartbeatOkCount: toInt(detail['heartbeatOkCount']),
      collectFailCount: toInt(detail['collectFailCount']),
      lessonFocusDone: detail['lessonFocusDone'] == true,
      lessonInteractiveDone: detail['lessonInteractiveDone'] == true,
      lastPointTimeId: toInt(detail['lastPointTimeId']),
      pointNum: toInt(detail['pointNum']),
      message: detail['message']?.toString(),
    );
    // 直接推送, 不走 [_engineThrottleInterval] 节流:
    // 该节流是为快刷模式高频引擎事件合并设计的; 自定义模式下脚本
    // updateDetail 频率由脚本自控 (示例脚本 60s/次), 节流合并不到任何
    // 事件, 只会凭空引入 500ms 可感知延迟, 使详情栏(含内部进度)始终
    // 落后于进度条刷新。直接推送保持与进度刷新同步。
    _engineStateController.add(snap);
  }

  /// 引擎状态快照节流间隔 (合并高频进度事件, 防 UI 过频重建)
  static const _engineThrottleInterval = Duration(milliseconds: 500);

  /// 节流定时器
  Timer? _engineThrottleTimer;

  /// 待广播的最新引擎快照 (节流窗口内的最新一帧)
  EngineStateSnapshot? _pendingEngineSnapshot;

  /// 取消所有执行中的任务
  void cancel() {
    _cancelled = true;
    for (final engine in _engines) {
      engine.cancel();
    }
    _log('用户停止上报', level: LogLevel.warning);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fast3Runner = null;
    _engineThrottleTimer?.cancel();
    _engineThrottleTimer = null;
    cancel();
    _logController.close();
    _sessionController.close();
    _engineStateController.close();
  }

  /// 从课程列表中提取可上报的视频课程
  ///
  /// [courses] 课程列表 (来自 pageHomeworkTasks 的 courses)
  /// [config] 上报配置
  /// [homeworkId] 当前作业 ID
  /// [schoolId] 学校 ID (getPlayerToken 必传)
  /// 返回需要上报的课程信息列表
  List<ReportTask> filterCourses(
    List<dynamic> courses,
    ReportConfig config,
    String homeworkId, {
    String schoolId = '',
  }) {
    final tasks = <ReportTask>[];

    for (final course in courses) {
      if (course is! Map<String, dynamic>) continue;

      // 类型/学科字段始终解析 (自定义模式下仍注入 task 供脚本过滤使用)
      final contentType = _parseInt(course['contentType']);
      final subject = _resolveSubject(course);

      // 自定义模式: 全部过滤 (已完成/认真度/类型/学科) 均放行, 由脚本自行判断
      if (!config.customEnabled) {
        // 过滤已完成 (观看完成: taskStatus==30)
        if (config.filterCompleted) {
          final status = course['taskStatus'];
          if (status == 30 || status == '30') continue;
        }

        // 过滤已完成认真度检测 (seriousCheckResult==2, 已通过)
        if (config.filterSeriousCheckChecked) {
          final scr = course['seriousCheckResult'];
          if (scr == 2 || scr == '2') continue;
        }

        // 过滤课程类型
        if (!config.shouldReportType(contentType)) continue;

        // 过滤学科（主判断: subjectName → subject → subjectId 反查）
        if (!config.shouldReportSubject(subject)) continue;
      }

      final lessonId = course['lessonId']?.toString() ??
          course['contentId']?.toString() ??
          '';
      final videoId = course['videoId']?.toString() ?? '';
      final title = course['title']?.toString() ??
          course['lessonName']?.toString() ??
          course['homeworkName']?.toString() ??
          '未知课程';
      final taskId = course['taskId']?.toString() ??
          course['task_id']?.toString() ??
          '';

      if (lessonId.isEmpty) continue;

      tasks.add(ReportTask(
        title: title,
        homeworkId: homeworkId,
        lessonId: lessonId,
        videoId: videoId,
        schoolId: schoolId,
        taskId: taskId,
        contentType: contentType,
        subjectName: subject ?? '',
        duration: _parseInt(course['duration']),
      ));
    }

    return tasks;
  }

  /// 执行批量进度上报
  ///
  /// [tasks] 需要上报的任务列表
  /// [config] 上报配置
  /// [onItemUpdate] 每个任务状态变化时的回调
  Future<void> executeBatch(
    List<ReportTask> tasks,
    ReportConfig config, {
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    _cancelled = false;
    _log('开始批量上报，共 ${tasks.length} 个任务');
    if (config.customEnabled) {
      _log('自定义模式: 执行 QuickJS 脚本 (${config.customScript.trim().length} 字符)',
          level: LogLevel.warning);
    } else if (config.fastBrush3) {
      _log('快刷模式3(多账户批量注入, round15): 操作者 ${config.operatorUserIds.length} 个, '
          '受害者=当前账号 userid=${_effectiveUserId.isNotEmpty ? _effectiveUserId : "(未知)"} (不可编辑), '
          '每轮每操作者 1 包 (端点轮换), 轮间等待 ${config.fast3RoundGap}s, '
          '单包 ${config.fastBrushStayTime}ms, 倍速 ${config.speed}x, '
          '密码账号 token 失效自动重登 (短信/扫码账号仅有效 token 可用)',
          level: LogLevel.warning);
    } else if (config.fastBrush) {
      _log('快刷模式${config.fastBrush2 ? "2(多session×${config.fastBrushSessions}, 预算乘法)" : ""}: '
          '${config.fastBrushThreads} 线程并发爆发 (burst), '
          '每请求 ${config.fastBrushEventsPerRequest == 0 ? "自动" : config.fastBrushEventsPerRequest} 事件, '
          '单事件 ${config.fastBrushStayTime}ms, 轮询间隔 ${config.fastBrushPollInterval}s, '
          '倍速 ${config.speed}x',
          level: LogLevel.warning);
    } else {
      _log('正常模式: 心跳 ${config.heartbeatInterval}s, '
          '倍速 ${config.speed}x');
    }
    if (config.realProgressQuery) {
      _log('真实进度查询: 开启, 轮询间隔 ${config.progressPollInterval}s, 达阈值(${(config.completionThreshold * 100).toInt()}%)自动跳转下一任务');
    } else {
      _log('真实进度查询: 关闭, 使用本地模拟进度');
    }

    // 输出用户身份摘要
    _emitUserSummary();

    // 预取 BFE session (per-user, 多课程复用)
    await _ensureBfeSession();

    if (config.parallelExecution && config.parallelTaskCount > 1) {
      await _executeParallel(tasks, config, onItemUpdate: onItemUpdate);
    } else {
      await _executeSequential(tasks, config, onItemUpdate: onItemUpdate);
    }

    if (!_cancelled) {
      _log('全部完成', level: LogLevel.success);
    }
  }

  /// 顺序执行批量任务
  Future<void> _executeSequential(
    List<ReportTask> tasks,
    ReportConfig config, {
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    for (var i = 0; i < tasks.length; i++) {
      if (_cancelled) {
        _log('已停止，完成 $i/${tasks.length}', level: LogLevel.warning);
        break;
      }

      await _runTask(tasks, config, i, onItemUpdate: onItemUpdate);

      // 任务间短暂间隔
      if (!_cancelled && i < tasks.length - 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// 并行执行批量任务 (并发数受 parallelTaskCount 限制, 1~100, 超出钳制)
  Future<void> _executeParallel(
    List<ReportTask> tasks,
    ReportConfig config, {
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    final concurrency = config.parallelTaskCount.clamp(1, 100);
    _log('并行执行模式: $concurrency 个任务并发', level: LogLevel.warning);

    var nextIndex = 0;

    Future<void> worker() async {
      while (!_cancelled) {
        final i = nextIndex++;
        if (i >= tasks.length) break;
        await _runTask(tasks, config, i, onItemUpdate: onItemUpdate);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }

  /// 执行单个任务 (含日志和状态回调, 供顺序/并行模式复用)
  Future<void> _runTask(
    List<ReportTask> tasks,
    ReportConfig config,
    int i, {
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    final task = tasks[i];
    _log('[${i + 1}/${tasks.length}] 开始: ${task.title}');

    try {
      await _executeSingle(task, config, index: i, onItemUpdate: onItemUpdate);
      // 显式标记完成（流事件可能因订阅取消未及时投递）
      onItemUpdate?.call(i, TaskProgressItem(
        title: task.title,
        state: PlaybackState.completed,
        progress: 1.0,
      ));
      _log('[${i + 1}/${tasks.length}] 完成: ${task.title}',
          level: LogLevel.success);
    } catch (e) {
      _log('[${i + 1}/${tasks.length}] 失败: ${task.title} - $e',
          level: LogLevel.error);
      onItemUpdate?.call(i, TaskProgressItem(
        title: task.title,
        state: PlaybackState.failed,
        error: '$e',
      ));
    }
  }

  /// 批量查询任务的真实上报进度 (0~1)
  ///
  /// 用于弹窗 60s 轮询: 优先 refreshTaskProgressBatch (taskId 维度),
  /// 失败或缺失的 taskId 回退 queryTaskProgress。返回 {item index: ratio} 映射,
  /// 查询失败的 taskId 不出现在结果中 (由调用方优雅降级到本地模拟进度)。
  Future<Map<int, double>> queryRealProgress(List<ReportTask> tasks) async {
    final result = <int, double>{};
    if (tasks.isEmpty || _disposed) return result;

    // 1. refreshTaskProgressBatch (主通道, 仅查询有 taskId 的任务)
    final taskIdsWithIndex = <MapEntry<int, String>>[];
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i].taskId.isNotEmpty) {
        taskIdsWithIndex.add(MapEntry(i, tasks[i].taskId));
      }
    }
    if (taskIdsWithIndex.isEmpty) return result;

    final schoolId =
        tasks.firstWhere((t) => t.taskId.isNotEmpty).schoolId;
    final tidToIndex = {for (final e in taskIdsWithIndex) e.value: e.key};

    // 1. refreshTaskProgressBatch (主通道)
    try {
      final list = await _playerRemote.refreshTaskProgressBatch(
        taskIds: taskIdsWithIndex.map((e) => e.value).toList(),
        schoolId: schoolId,
      );
      for (final item in list) {
        final tid = item['taskId']?.toString();
        if (tid == null || tid.isEmpty) continue;
        final ratio = _extractRatio(item);
        if (ratio != null && tidToIndex.containsKey(tid)) {
          result[tidToIndex[tid]!] = ratio;
        }
      }
    } catch (_) {}

    // 2. queryTaskProgress 兜底 (refresh 未覆盖的 taskId)
    final missing = taskIdsWithIndex
        .where((e) => !result.containsKey(e.key))
        .map((e) => e.value)
        .toList();
    if (missing.isNotEmpty) {
      try {
        final list = await _playerRemote.queryTaskProgress(
          taskIds: missing,
          schoolId: schoolId,
        );
        for (final item in list) {
          final tid = item['taskId']?.toString();
          if (tid == null || tid.isEmpty) continue;
          final ratio = _extractRatio(item);
          if (ratio != null && tidToIndex.containsKey(tid)) {
            result[tidToIndex[tid]!] = ratio;
          }
        }
      } catch (_) {}
    }

    return result;
  }

  /// 从响应条目提取进度比例 (优先 ratio, 回退 finishPercent/percent)
  double? _extractRatio(Map<String, dynamic> item) {
    final rv = item['ratio'];
    if (rv != null) {
      final v = double.tryParse(rv.toString());
      if (v != null) return v.clamp(0.0, 1.0);
    }
    final fp = item['finishPercent'] ?? item['percent'];
    if (fp != null) {
      final v = double.tryParse(fp.toString());
      if (v != null) return v.clamp(0.0, 1.0);
    }
    return null;
  }

  /// 预取 BFE session (getPlayerGlobalConf) + 并行拉取 baseinfo 补全用户信息
  ///
  /// sessionId / secret / clientIp 是 BFE CommonPackage 必传字段, per-user 维度,
  /// 多课程复用同一份。失败时使用默认值, 不阻断流程。
  ///
  /// 同时并行调用 [PlayerRemoteDataSource.getBaseInfo] 补全 UserSession 可能缺失的
  /// account/provinceCode/schoolName/mobile 等字段 (token 直登场景或登录流程未填充时)。
  Future<void> _ensureBfeSession() async {
    if (_sessionId.isNotEmpty) return; // 已缓存

    _log('─── 获取 BFE 会话配置 ───');
    // 先推送 fetching 状态 (此时 baseInfo 尚未拉取, 字段可能为空)
    _emitSession(SessionContext(
      userId: _effectiveUserId,
      token: _userSession?.token ?? '',
      schoolId: _effectiveSchoolId,
      displayName: _effectiveDisplayName,
      schoolName: _effectiveSchoolName,
      provinceCode: _effectiveProvinceCode,
      account: _effectiveAccount,
      mobile: _effectiveMobile,
      sessionId: '',
      secret: '',
      clientIp: '',
      sdkVersion: _endpointConfig.sdkVersion,
      userAgent: _endpointConfig.userAgent,
      videoBizCode: '1013',
      status: SessionStatus.fetching,
    ));

    // 并行: BFE 会话配置 + 用户基础信息 (补全 account/provinceCode/schoolName/mobile)
    final results = await Future.wait([
      _fetchGlobalConf(),
      _fetchBaseInfo(),
    ]);
    final globalConf = results[0] as Map<String, dynamic>;
    final baseInfoFetchError = results[1] as String?;

    final globalInfo = (globalConf['globalInfo'] as Map<String, dynamic>?) ?? {};
    _sessionId = globalInfo['sessionId']?.toString() ??
        globalConf['sessionId']?.toString() ??
        _generateSessionId();
    _secret = globalInfo['secret']?.toString() ??
        globalConf['secret']?.toString() ??
        '';
    _clientIp = globalInfo['clientIp']?.toString() ??
        globalConf['clientIp']?.toString() ??
        '';
    _maxBatchSize = _parseInt(globalInfo['maxBatchSize'] ?? globalConf['maxBatchSize']);
    if (_maxBatchSize <= 0) _maxBatchSize = 10;

    // 提取 fallbackIP (IPLOG 直连 IP:port, 如 "101.37.78.197:8081")
    // 由 getPlayerGlobalConf.globalInfo.fallbackIP 返回
    final fallbackIP = globalInfo['fallbackIP']?.toString() ??
        globalConf['fallbackIP']?.toString() ??
        '';
    if (fallbackIP.isNotEmpty) {
      _telemetryRemote.fallbackIP = fallbackIP;
      _log('  fallbackIP=$fallbackIP (IPLOG 直连)');
    }

    final sessionOk = _sessionId.isNotEmpty && _secret.isNotEmpty;
    _log('  sessionId=${_mask(_sessionId, 16)}');
    _log('  secret=${_secret.isNotEmpty ? "${_mask(_secret, 8)}..." : "(空)"}');
    _log('  clientIp=${_clientIp.isNotEmpty ? _clientIp : "(空)"}');
    _log('  maxBatchSize=$_maxBatchSize (快刷每请求事件数自动值时使用)');
    _log('  sdkVersion=${_endpointConfig.sdkVersion}, videoBizCode=1013');
    _log('  userAgent=${_endpointConfig.userAgent}');

    // 输出补全后的用户身份 (UserSession 字段缺失时由 baseInfo 填充)
    if (_baseInfo.isNotEmpty) {
      _log('  用户基础信息(baseinfo): '
          'realName=${(_baseInfo['realName']?.toString() ?? '').isNotEmpty ? "${_mask(_baseInfo['realName'].toString(), 2)}***" : "(空)"}, '
          'account=${_effectiveAccount.isNotEmpty ? "${_mask(_effectiveAccount, 2)}***" : "(空)"}, '
          'schoolName=${_effectiveSchoolName.isNotEmpty ? _effectiveSchoolName : "(空)"}, '
          'provinceCode=${_effectiveProvinceCode.isNotEmpty ? _effectiveProvinceCode : "(空)"}'
          '${_effectiveProvinceName.isNotEmpty ? " ($_effectiveProvinceName)" : ""}, '
          'mobile=${_effectiveMobile.isNotEmpty ? "${_mask(_effectiveMobile, 3)}***" : "(空)"}',
          level: LogLevel.success);
    } else if (baseInfoFetchError != null) {
      _log('  baseinfo 获取失败(非致命): $baseInfoFetchError',
          level: LogLevel.warning);
    }

    if (sessionOk) {
      _log('  ✓ BFE 会话就绪', level: LogLevel.success);
    } else {
      _log('  ⚠ BFE 会话部分缺失, 将使用降级值继续', level: LogLevel.warning);
    }

    // 推送 ready/failed 状态 (使用补全后的字段)
    _emitSession(SessionContext(
      userId: _effectiveUserId,
      token: _userSession?.token ?? '',
      schoolId: _effectiveSchoolId,
      displayName: _effectiveDisplayName,
      schoolName: _effectiveSchoolName,
      provinceCode: _effectiveProvinceCode,
      account: _effectiveAccount,
      mobile: _effectiveMobile,
      sessionId: _sessionId,
      secret: _secret,
      clientIp: _clientIp,
      sdkVersion: _endpointConfig.sdkVersion,
      userAgent: _endpointConfig.userAgent,
      videoBizCode: '1013',
      status: sessionOk ? SessionStatus.ready : SessionStatus.degraded,
      error: baseInfoFetchError,
    ));
  }

  /// 拉取 getPlayerGlobalConf (失败返回空 Map, 不抛异常)
  Future<Map<String, dynamic>> _fetchGlobalConf() async {
    try {
      return await _playerRemote.getPlayerGlobalConf().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          _log('  getPlayerGlobalConf 超时, 使用默认值', level: LogLevel.warning);
          return <String, dynamic>{};
        },
      );
    } catch (e) {
      _log('  getPlayerGlobalConf 失败(非致命): $e', level: LogLevel.warning);
      return <String, dynamic>{};
    }
  }

  /// 拉取 baseinfo (补全 UserSession 缺失字段)
  Future<String?> _fetchBaseInfo() async {
    if (_baseInfoFetched) return null;
    _baseInfoFetched = true;
    _log('  → 开始拉取 baseinfo...');
    try {
      _baseInfo = await _playerRemote.getBaseInfo().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _log('  baseinfo 超时', level: LogLevel.warning);
          return <String, dynamic>{};
        },
      );
      _log('  ← baseinfo 完成: ${_baseInfo.length} 个字段');
    } catch (e) {
      _log('  baseinfo 异常: $e', level: LogLevel.warning);
      return '$e';
    }
    return null;
  }

  /// 执行单个课程的进度上报
  ///
  /// 按 contentType 分流:
  /// - contentType=3 (FM) / 5 (板报): 不走播放心跳, 统一走 updateMission
  ///   直写 {schoolId, contentId, contentType, percent:1} 一次完成 (对齐
  ///   ewt360-brush-main 的 _mission_direct_complete)
  /// - 其余: 走 PlaybackEngine 完整视频行为链 (token/BFE 心跳/认真度检测)
  ///
  /// 自定义模式 ([ReportConfig.customEnabled]) 优先: 直接执行用户 QuickJS
  /// 脚本, 绕过内置引擎。
  Future<void> _executeSingle(
    ReportTask task,
    ReportConfig config, {
    required int index,
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    if (config.customEnabled) {
      await _executeCustom(task, config,
          index: index, onItemUpdate: onItemUpdate);
      return;
    }

    // 快刷模式3 (round15 多账户批量注入): 操作者集群仅承担 collect 包注入;
    // FM(3)/板报(5) 不走注入链, 回退下方直写 —— 始终用当前登录(受害者)账号的
    // _playerRemote (victim token) 执行, 与操作者账号无关。
    if (config.fastBrush3 && task.contentType != 3 && task.contentType != 5) {
      await _executeFast3(task, config,
          index: index, onItemUpdate: onItemUpdate);
      return;
    }

    // FM / 板报 与视频课程上报逻辑完全不同, 不构建播放会话
    if (task.contentType == 3) {
      await _executeFm(task, index: index, onItemUpdate: onItemUpdate);
      return;
    }
    if (task.contentType == 5) {
      await _executeBoard(task, index: index, onItemUpdate: onItemUpdate);
      return;
    }

    onItemUpdate?.call(index, TaskProgressItem(
      title: task.title,
      state: PlaybackState.initializing,
      message: '构建播放会话...',
    ));

    // 构建 VideoSession (携带 BFE CommonPackage 所需用户/环境上下文)
    // playerToken / courseId / duration / interactiveConfigs 留空, 由引擎初始化
    // V7: injectUserId 开启时 CommonPackage.userid 覆盖为注入目标 (token 仅认证)
    final session = VideoSession(
      homeworkId: task.homeworkId,
      lessonId: task.lessonId,
      videoId: task.videoId.isNotEmpty ? task.videoId : task.lessonId,
      taskId: task.taskId,
      contentType: task.contentType ?? 1,
      courseId: null,
      schoolId: task.schoolId,
      sessionId: _sessionId,
      secret: _secret,
      duration: task.duration, // 0 时引擎会自动解析
      playerToken: null,
      userId: config.effectiveInjectUserId ?? _userSession?.userId ?? '',
      token: _userSession?.token ?? '',
      clientIp: _clientIp,
      memberProvinceCode: _effectiveProvinceCode,
      schoolProvinceCode: _effectiveProvinceCode,
    );

    final injectTarget = config.effectiveInjectUserId;
    if (injectTarget != null) {
      _log('  V7 任意用户进度注入: 写入目标 userid=$injectTarget '
          '(当前账号 $_effectiveUserId 的 token 仅做认证)',
          level: LogLevel.warning);
    }

    _log('  创建播放引擎, 模式=${config.fastBrush2 ? "快刷2(多session×${config.fastBrushSessions})" : config.fastBrush ? "快刷" : "正常"}, '
        'taskId=${task.taskId.isNotEmpty ? task.taskId : "(空)"}, '
        'contentType=${task.contentType}');
    final engine = PlaybackEngine(
      playerRemote: _playerRemote,
      telemetryRemote: _telemetryRemote,
      endpointConfig: _endpointConfig,
    );
    _engines.add(engine);
    _currentEngine = engine;

    // 监听进度 → 同时更新进度条、日志、引擎状态快照
    PlaybackState? lastLogState;
    final sub = engine.progressStream.listen((progress) {
      onItemUpdate?.call(index, TaskProgressItem(
        title: task.title,
        state: progress.state,
        progress: progress.fraction,
        message: progress.message,
        error: progress.error,
      ));

      // 引擎状态快照 (供 UI 详情面板)
      _emitEngineState(
        engine,
        index: index,
        title: task.title,
        state: progress.state,
        progress: progress.fraction,
        message: progress.message,
      );

      // 状态变化或播放中每次心跳都写日志
      if (progress.state != lastLogState) {
        lastLogState = progress.state;
        final msg = progress.message ?? progress.state.name;
        _log('  [${progress.state.name}] $msg');
      } else if (progress.message != null) {
        _log('  ${progress.message}',
            level: _levelForState(progress.state));
      }
      if (progress.error != null) {
        _log('  [引擎错误] ${progress.error}', level: LogLevel.error);
      }
    });

    try {
      await engine.simulatePlayback(
        session,
        fastMode: config.fastBrush,
        heartbeatInterval: config.heartbeatInterval,
        speed: config.speed,
        fastBrushMaxRounds: config.fastBrushMaxRounds,
        completeRatio: config.completionThreshold,
        realProgressQuery: config.realProgressQuery,
        progressPollInterval: config.progressPollInterval,
        resumeFromServer: config.resumeFromServer,
        useBackup: config.useBackup,
        reportBackend: config.reportBackend,
        fastBrushThreads: config.fastBrushThreads,
        fastBrushStayTime: config.fastBrushStayTime,
        fastBrushPollInterval: config.fastBrushPollInterval,
        fastBrushEventsPerRequest: config.fastBrushEventsPerRequest,
        fastBrushWafBackoff: config.fastBrushWafBackoff,
        maxBatchSize: _maxBatchSize,
        rebrush: config.rebrush,
        rebrushRounds: config.rebrushRounds,
        rebrushExtraMinutes: config.rebrushExtraMinutes,
        compensate: config.compensate,
        fastBrush2: config.fastBrush2,
        fastBrushSessions: config.fastBrushSessions,
      );
    } finally {
      await sub.cancel();
      engine.dispose();
      _engines.remove(engine);
      if (_currentEngine == engine) {
        _currentEngine = null;
      }
    }
  }

  /// 快刷模式3 runner (批量任务期间复用, 操作者集群只就位一次)
  FastBrush3Runner? _fast3Runner;

  /// 执行快刷模式3 任务 (round15 多账户批量注入)
  ///
  /// 受害者 = 当前登录账号 (userid 不可编辑, 忽略 injectUserId 配置);
  /// 操作者集群来自 config.operatorUserIds, 由 runner 幂等就位 (token 检测
  /// + 自动重登 + 独立 BFE 会话), 多课程间复用。
  Future<void> _executeFast3(
    ReportTask task,
    ReportConfig config, {
    required int index,
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    final runner = _fast3Runner ??= FastBrush3Runner(
      endpointConfig: _endpointConfig,
      config: config,
      victimPlayerRemote: _playerRemote,
      victimUserId: _effectiveUserId,
      log: (msg, {level = LogLevel.info}) => _log(msg, level: level),
      isCancelled: () => _cancelled,
      pollRatio: _pollFast3Ratio,
    );

    onItemUpdate?.call(index, TaskProgressItem(
      title: task.title,
      state: PlaybackState.initializing,
      message: '就位操作者集群...',
    ));
    await runner.ensurePrepared();

    // 受害者侧操作边界 (全部使用当前登录账号的 victim 客户端, 与操作者无关):
    // - 课时详情解析 (getLessonDetailV2 / getLessonTaskInfo) → runner._victimPlayer
    // - 真实进度轮询 (taskProgressV1) → _pollFast3Ratio → _playerRemote (victim token)
    // - FM/板报直写 (updateMission) → _executeFm/_executeBoard → _playerRemote
    // 操作者集群仅用于 collect 包注入 (包体 userid 指向受害者)。
    _log('  受害者侧操作 (课时详情/真实进度查询/FM板报直写) 均使用当前登录账号 '
        'userId=$_effectiveUserId, 操作者集群仅承担 collect 注入',
        level: LogLevel.info);

    onItemUpdate?.call(index, TaskProgressItem(
      title: task.title,
      state: PlaybackState.playing,
      progress: 0,
      message: '开始多账户批量注入...',
    ));

    await runner.runTask(
      Fast3Task(
        title: task.title,
        homeworkId: task.homeworkId,
        lessonId: task.lessonId,
        taskId: task.taskId,
        schoolId: task.schoolId,
        contentType: task.contentType,
        duration: task.duration,
      ),
      onProgress: (ratio, message) {
        onItemUpdate?.call(index, TaskProgressItem(
          title: task.title,
          state: PlaybackState.playing,
          progress: ratio,
          message: message,
        ));
      },
    );
  }

  /// 快刷3 victim 真实进度轮询 (taskId → 0~1, victim token 查询)
  Future<double?> _pollFast3Ratio(String taskId) async {
    if (taskId.isEmpty) return null;
    try {
      final list = await _playerRemote.queryTaskProgress(
        taskIds: [taskId],
        schoolId: _effectiveSchoolId,
      );
      for (final item in list) {
        if (item['taskId']?.toString() == taskId) {
          return _extractRatio(item);
        }
      }
    } catch (_) {}
    return null;
  }

  /// 执行自定义模式任务 (QuickJS 脚本)
  ///
  /// 构建账号/任务字段注入脚本运行时, 执行 [ReportConfig.customScript]。
  /// 脚本内 log → 任务日志流; updateProgress → 任务进度条。
  /// 异常 (含脚本语法错误/超时/宿主调用失败) 上抛由 [_runTask] 标记失败。
  Future<void> _executeCustom(
    ReportTask task,
    ReportConfig config, {
    required int index,
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    final script = config.customScript.trim();
    if (script.isEmpty) {
      throw ScriptRuntimeException('自定义模式脚本为空, 请在配置弹窗填写');
    }
    _log('  自定义模式: 执行 QuickJS 脚本 (${script.length} 字符)',
        level: LogLevel.warning);
    onItemUpdate?.call(index, TaskProgressItem(
      title: task.title,
      state: PlaybackState.initializing,
      message: '启动 QuickJS 脚本...',
    ));

    // V7: injectUserId 开启时把 account.userId 覆盖为注入目标,
    // 脚本 sendHeartbeat 等宿主函数构建的 CommonPackage.userid 随之指向目标用户。
    final accountMap = <String, dynamic>{
      'userId': config.effectiveInjectUserId ?? _effectiveUserId,
      'schoolId': _effectiveSchoolId,
      'account': _effectiveAccount,
      'displayName': _effectiveDisplayName,
      'schoolName': _effectiveSchoolName,
      'provinceCode': _effectiveProvinceCode,
      'provinceName': _effectiveProvinceName,
      'mobile': _effectiveMobile,
      'token': _userSession?.token ?? '',
      'sessionId': _sessionId,
      'secret': _secret,
      'clientIp': _clientIp,
      'sdkVersion': _endpointConfig.sdkVersion,
      'userAgent': _endpointConfig.userAgent,
      'videoBizCode': '1013',
      'maxBatchSize': _maxBatchSize,
      // IPLOG 直连 IP:port (getPlayerGlobalConf.globalInfo.fallbackIP, 会话建立时已取)
      // 供脚本 iplog 通道直连使用, 避免脚本再自取或回退固定域名 (可能 DNS 失败)。
      'fallbackIP': _telemetryRemote.fallbackIP,
    };
    final taskMap = <String, dynamic>{
      'title': task.title,
      'homeworkId': task.homeworkId,
      'lessonId': task.lessonId,
      'videoId': task.videoId,
      'taskId': task.taskId,
      'contentType': task.contentType,
      'schoolId': task.schoolId,
      'subjectName': task.subjectName,
      'duration': task.duration,
    };

    final runtime = CustomReportRuntimeImpl.create(
      client: _client,
      playerRemote: _playerRemote,
      telemetryRemote: _telemetryRemote,
      endpointConfig: _endpointConfig,
      account: accountMap,
      task: taskMap,
      sessionId: _sessionId,
      secret: _secret,
      clientIp: _clientIp,
      maxBatchSize: _maxBatchSize,
      // 透传备用上报通道配置 (对齐引擎 _sendCollect):
      // 用户配置 IPLOG 直连时, 脚本心跳走与普通模式相同的通道, 否则可能 400。
      useBackup: config.useBackup,
      reportBackend: config.reportBackend,
      onLog: (msg, level) {
        _log('  [脚本] $msg', level: level);
      },
      onProgress: (ratio, message) {
        onItemUpdate?.call(index, TaskProgressItem(
          title: task.title,
          state: PlaybackState.playing,
          progress: ratio,
          message: message,
        ));
      },
      onDetail: (detail) {
        _emitCustomEngineState(
          index: index,
          title: task.title,
          detail: detail,
        );
      },
    );
    try {
      // 无总超时: 脚本按真实心跳节奏 (60s/轮) 运行, 长课时可达 60+ 分钟,
      // 固定超时会误杀; 异常由脚本内 try/catch 或用户自行控制。
      await runtime.execute(script, totalTimeout: null);
      _log('  ✓ 自定义脚本执行完成', level: LogLevel.success);
      onItemUpdate?.call(index, TaskProgressItem(
        title: task.title,
        state: PlaybackState.completed,
        progress: 1.0,
        message: '脚本执行完成',
      ));
    } finally {
      runtime.dispose();
    }
  }

  /// 执行 FM 任务上报 (contentType=3)
  ///
  /// 对齐 ewt360-brush-main 的 _mission_direct_complete:
  /// FM 不走播放心跳, 直接 updateMission {schoolId, contentId, contentType:3,
  /// percent:1} 一次直写 100% 即完成, 无需 BFE session / 播放 token。
  Future<void> _executeFm(
    ReportTask task, {
    required int index,
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    onItemUpdate?.call(index, TaskProgressItem(
      title: task.title,
      state: PlaybackState.starting,
      message: '直写 FM 完成...',
    ));

    _log('  直写 FM 完成 updateMission: contentId=${task.lessonId}, '
        'schoolId=${task.schoolId}, contentType=3');
    try {
      await _playerRemote.completeMissionByContent(
        schoolId: task.schoolId,
        contentId: task.lessonId,
        contentType: 3,
      );
      _log('  ✓ FM updateMission ok', level: LogLevel.success);
      onItemUpdate?.call(index, TaskProgressItem(
        title: task.title,
        state: PlaybackState.completed,
        progress: 1.0,
        message: 'FM 完成已直写',
      ));
    } catch (e) {
      _log('  FM updateMission 失败: $e', level: LogLevel.error);
      rethrow;
    }
  }

  /// 执行板报任务上报 (contentType=5)
  ///
  /// 对齐 ewt360-brush-main 的 _mission_direct_complete:
  /// 板报不走播放心跳, 直接 updateMission {schoolId, contentId, contentType:5,
  /// percent:1} 一次直写 100% 即完成。
  Future<void> _executeBoard(
    ReportTask task, {
    required int index,
    void Function(int index, TaskProgressItem item)? onItemUpdate,
  }) async {
    onItemUpdate?.call(index, TaskProgressItem(
      title: task.title,
      state: PlaybackState.starting,
      message: '直写板报完成...',
    ));

    _log('  直写板报完成 updateMission: contentId=${task.lessonId}, '
        'schoolId=${task.schoolId}, contentType=5');
    try {
      await _playerRemote.completeMissionByContent(
        schoolId: task.schoolId,
        contentId: task.lessonId,
        contentType: 5,
      );
      _log('  ✓ 板报 updateMission ok', level: LogLevel.success);
      onItemUpdate?.call(index, TaskProgressItem(
        title: task.title,
        state: PlaybackState.completed,
        progress: 1.0,
        message: '板报完成已直写',
      ));
    } catch (e) {
      _log('  板报 updateMission 失败: $e', level: LogLevel.error);
      rethrow;
    }
  }

  /// 根据 PlaybackState 推断日志级别
  LogLevel _levelForState(PlaybackState state) {
    switch (state) {
      case PlaybackState.initializing:
      case PlaybackState.starting:
      case PlaybackState.playing:
        return LogLevel.info;
      case PlaybackState.focusChecking:
      case PlaybackState.interactive:
        return LogLevel.warning;
      case PlaybackState.finishing:
        return LogLevel.info;
      case PlaybackState.completed:
        return LogLevel.success;
      case PlaybackState.failed:
        return LogLevel.error;
      case PlaybackState.cancelled:
        return LogLevel.warning;
    }
  }

  /// 输出当前用户身份摘要 (使用 _effective* 访问器, baseInfo 补全)
  void _emitUserSummary() {
    if (_userSession == null && _baseInfo.isEmpty) {
      _log('  用户身份: (未登录)', level: LogLevel.warning);
      return;
    }
    _log('  用户身份: userId=$_effectiveUserId, schoolId=$_effectiveSchoolId, '
        'account=${_effectiveAccount.isNotEmpty ? _effectiveAccount : "(空)"}, '
        'displayName=${_effectiveDisplayName.isNotEmpty ? _effectiveDisplayName : "(空)"}, '
        'schoolName=${_effectiveSchoolName.isNotEmpty ? _effectiveSchoolName : "(空)"}, '
        'province=${_effectiveProvinceCode.isNotEmpty ? _effectiveProvinceCode : "(空)"}'
        '${_effectiveProvinceName.isNotEmpty ? " ($_effectiveProvinceName)" : ""}, '
        'mobile=${_effectiveMobile.isNotEmpty ? "${_mask(_effectiveMobile, 3)}***" : "(空)"}, '
        'token=${_maskToken(_userSession?.token ?? "")}');
  }

  /// 脱敏 token
  String _maskToken(String token) {
    if (token.length <= 12) return token;
    return '${token.substring(0, 8)}...${token.substring(token.length - 4)}';
  }

  /// 脱敏字符串
  String _mask(String s, int keepLen) {
    if (s.length <= keepLen) return s;
    return '${s.substring(0, keepLen)}...';
  }

  String _generateSessionId() {
    final r = Random();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  int _parseInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  /// 解析课程学科名称
  ///
  /// 主判断标准: pageHomeworkTasks 的 subjectName 字段 (API 原始值, 最准确)
  /// 备用判断: subject 字段 → subjectId 反查 (对齐 EWT Web)
  /// 无法解析返回 null
  String? _resolveSubject(Map<String, dynamic> course) {
    // 1. subjectName 优先 (主判断标准, 来自 pageHomeworkTasks)
    final name = course['subjectName']?.toString();
    if (name != null && name.isNotEmpty) return name;

    // 2. subject 字段备用 (可能是名称或数字 ID)
    final subj = course['subject'];
    if (subj != null) {
      final asStr = subj.toString();
      if (asStr.isNotEmpty) {
        final asId = int.tryParse(asStr);
        if (asId != null) {
          return subjectNameMap[asId];
        }
        return asStr;
      }
    }

    // 3. subjectId 反查备用
    final subjectId = _parseInt(course['subjectId']);
    if (subjectId > 0) {
      return subjectNameMap[subjectId];
    }

    return null;
  }
}

/// 待上报的课程任务
class ReportTask {
  final String title;
  final String homeworkId;
  final String lessonId;
  final String videoId;
  final String schoolId;

  /// 任务 ID (refreshTaskProgress / taskProgressV1 必传)
  ///
  /// 对应 Python: course.task_id (来自 pageHomeworkTasks.taskId)
  final String taskId;

  /// contentType (1=视频 / 2=试卷 / 3=FM / 4=资讯 / 5=板报 / 6=测评 / 7=课后习题 /
  /// 11=校本视频 / 12=校本试卷 / 13=模拟选科 / 14=B端测评 / 15=专题 / 16=课程包 /
  /// 17=直播 / 18=选科测评 / 19=专题 / 20=学科专项 / 21=模拟选科决策分析)
  final int? contentType;

  /// 学科名 (如 "数学"/"语文", 供自定义脚本按学科过滤; 空字符串 = 未知)
  final String subjectName;

  final int duration;

  const ReportTask({
    required this.title,
    required this.homeworkId,
    required this.lessonId,
    required this.videoId,
    this.schoolId = '',
    this.taskId = '',
    this.contentType,
    this.subjectName = '',
    this.duration = 0,
  });
}
